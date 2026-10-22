# Research 03: backend and PWA-compat changes for the iOS client

Date: 2026-10-17. Scope: everything the FastAPI backend needs for the SwiftUI
app. File refs are relative to the repo root (worktree `quickr-worktrees/ios`).

## Recommendations (summary)

| # | Change | Needed by iOS milestone | Can go to main early? |
| --- | --- | --- | --- |
| B1 | **OpenAPI**: `answers` map → `additionalProperties`. Keep everything else; Swift-only post-processing if needed. | API client | Yes (TS diff is small: zod gets typed values) |
| B2 | **Due test vectors**: pytest-generated `shared/fixtures/due-vectors.json` with drift check. | Due logic / home | Yes (no runtime change) |
| B3 | **`ios` channel**: `ADD VALUE` in an autocommit block; downgrade remaps to `api`. | Logging / outbox | Yes |
| B4 | **Sync**: `GET /entries/changes?cursor=` (keyset `(updated_at, id)`) + `deleted_records` tombstones (90 days) + `server_time`; topics re-pulled. | Offline store / sync | Yes (purely additive) |
| B5 | **APNs**: `apns_devices` table, shared `Sender` protocol, `httpx[http2]` + cached ES256 JWT, per-device environment, concurrent sends. | Reminders (needs Apple enrolment) | Yes, dark (off without env vars) |
| B6 | **Actionable payload**: `topic_id`, `version`, `quick_log`; APNs `category`, `thread-id`, collapse id `due-{topic_id}`; Web Push fields additive. | Log from notification | Yes |
| B7 | **Cloudflare Access**: no backend auth; PWA outbox treats Access 401/403 as retryable; MCP needs its own policy. | Hosting (later) | Docs only |

**Risks**: enum migration inside Alembic's single transaction
(`autocommit_block`); commit-order gaps in an `updated_at` cursor (2-minute
overlap, idempotent upserts); Python vs Foundation DST-gap semantics (vectors);
APNs keys restricted to one environment (per-environment config);
unauthenticated device registration leaks topic names until Access is in place.

---

## 1. APNs delivery (B5)

### Storage: separate `apns_devices` table (recommended)

`push_subscriptions` (`backend/app/models.py:164-176`) has non-null `p256dh` and
`auth` columns and a unique `endpoint`. Registration validates the endpoint with
the SSRF guard (`backend/app/schemas/api.py:631-640`,
`backend/app/push_guard.py`). A `kind` discriminator would make those columns
nullable, weaken the CHECK story and push branches into `subscribe()` and the
guard. A separate table keeps the PWA API and its tests byte-for-byte unchanged.

```python
class ApnsDevice(Base):
    __tablename__ = "apns_devices"
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    token: Mapped[str] = mapped_column(Text, unique=True)            # hex, lower-cased
    environment: Mapped[str] = mapped_column(String(16))             # 'sandbox' | 'production'
    app_version: Mapped[str | None] = mapped_column(String(64), default=None)
    device_name: Mapped[str | None] = mapped_column(String(200), default=None)
    created_at / updated_at (server_default now()), last_success_at, failure_count (server_default "0")
    __table_args__ = (CheckConstraint("environment IN ('sandbox','production')", name="ck_apns_env"),)
```

- Use `String` plus a CHECK, not a PG enum. That avoids another enum migration
  (see §3).
- **Migration**: `20261018_<rev>_apns_devices.py` with `create_table` and
  `drop_table`.
- Add the table to `TABLES` in `backend/tests/conftest.py:38`.

### Endpoints

These mirror the existing push routes in `backend/app/api/routes.py:297-330`,
including the POST-delete convention.

- `POST /push/apns/devices` (`registerApnsDevice`, 201): body
  `ApnsDeviceIn{token: ^[0-9a-fA-F]{64,200}$, environment, app_version?, device_name?}`;
  upsert by token, reset `failure_count`. Called on every launch.
- `POST /push/apns/devices/delete` (204, body `{token}`, idempotent).
- `POST /push/test` now fans out to every sender; add
  `POST /push/apns/devices/test` (`{token}`) to test just this phone.
- `GET /push/config` gains `apns_enabled: bool` (additive; TS gains a required
  prop).

**Environment**: the app reports it. Use `#if DEBUG` → `sandbox`, otherwise
`production`. TestFlight and App Store builds use production. The server picks
`api.sandbox.push.apple.com` or `api.push.apple.com` per device
([Apple: Sending notification requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)).

### Sender abstraction

Refactor `send_to_all` (`backend/app/services/push.py:208-238`):

```python
class Sender(Protocol):
    kind: str                                    # "web" | "apns"
    async def targets(self, db) -> Sequence[PushTarget]   # ORM rows with failure_count/last_success_at
    async def send(self, target, n: Notification, ttl: int) -> None   # raises PushGone / PushFailed

async def send_to_all(db, n: Notification, *, ttl=DEFAULT_TTL_SECONDS) -> PushTestResult
```

- `WebPushSender` wraps today's `deliver` (thread) and renders the unchanged
  `PushPayload`; `ApnsSender` is registered only when APNs is configured.
- Shared outcomes: `PushGone` → delete; other failure → `failure_count += 1`;
  success → `last_success_at`, `failure_count = 0`. New pruning for both: delete
  when `failure_count >= 20` and no success for 30 days.
- Split `services/push.py` into `push/web.py`, `push/apns.py`, `push/__init__.py`.

### HTTP/2 client: `httpx[http2]` (recommended)

- **httpx** is already a dev dependency (`backend/pyproject.toml:21`). Stable is
  0.28.1 (1.0 in pre-release); the `http2` extra is supported
  ([PyPI httpx](https://pypi.org/project/httpx/)), and h2 4.4.1 (Aug 2026)
  supports Python 3.14 ([PyPI h2](https://pypi.org/project/h2/)). Async, typed,
  and `MockTransport` makes tests trivial.
- **aioapns** 4.0 (Apr 2025) lists classifiers only up to Python 3.11 and pulls
  in pyOpenSSL ([PyPI aioapns](https://pypi.org/project/aioapns/)); its pooling
  is overkill for one user. PyAPNs2/hyper are dead. Rejected.

**Dependencies**: move `httpx[http2]>=0.28.1` into runtime deps and add
`pyjwt[crypto]` explicitly (today it's only transitive).

### Client and JWT

- Create one
  `httpx.AsyncClient(http2=True, timeout=httpx.Timeout(10, connect=5), follow_redirects=False)`
  per environment.
  - Create it lazily and close it in the app lifespan, combined with
    `scheduler.lifespan` in `backend/app/main.py:28`.
- JWT: header `{alg: ES256, kid: KEY_ID}`, claims `{iss: TEAM_ID, iat}`, signed
  with the .p8 key (`jwt.encode(..., algorithm="ES256", headers={"kid": ...})`).
- Cache the token and regenerate it after **50 min**. APNs rejects tokens older
  than 1 h and returns `TooManyProviderTokenUpdates` if you refresh more often
  than every 20 min
  ([Apple](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)).
- On `403 ExpiredProviderToken`, force a refresh (only if the token is more than
  20 min old) and retry once.

Request: `POST /3/device/{token}` with these headers:

| Header             | Value                                             |
| ------------------ | ------------------------------------------------- |
| `authorization`    | `bearer <jwt>`                                    |
| `apns-topic`       | `QUICKR_APNS_TOPIC`                               |
| `apns-push-type`   | `alert`                                           |
| `apns-priority`    | `10`                                              |
| `apns-expiration`  | `now + ttl` (same 12 h as Web Push, `push.py:41`) |
| `apns-collapse-id` | the tag                                           |

### Error mapping

Reasons are from
[Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).

| Response                                                          | Action                                                                                       |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| 200                                                               | success                                                                                      |
| 410 `Unregistered` / `ExpiredToken`                               | `PushGone`: delete                                                                           |
| 400 `BadDeviceToken`                                              | `PushGone`: delete. The app re-registers on launch, so a wrong-environment token self-heals. |
| 400 `DeviceTokenNotForTopic`                                      | `PushFailed` plus an **error log**. This is a config bug; don't wipe devices.                |
| 400 `PayloadTooLarge` / `BadCollapseId` / other 400               | `PushFailed` plus an error log (our bug)                                                     |
| 403 `ExpiredProviderToken`                                        | refresh and retry once, then `PushFailed`                                                    |
| 403 `InvalidProviderToken`, 429, 5xx, timeouts, `httpx.HTTPError` | `PushFailed`                                                                                 |

### Config (`backend/app/config.py`)

`apns_team_id`, `apns_key_id`, `apns_private_key` (PEM, `\n` escapes) or
`apns_private_key_file`, `apns_topic = "com.bahumia.quickr"`, and optional
`apns_sandbox_key_id` / `apns_sandbox_private_key`, because Apple keys can be
restricted to one environment
([Airship summary](https://docs.airship.com/platform/mobile/setup/configure-channels)).
APNs is on only when team, key id and key are all set.

### Scheduler: concurrency and the transaction

Today each topic sends sequentially, inside the advisory-lock transaction,
before its `UPDATE` (`backend/app/services/scheduler.py:64-89`).

- At this scale sending inside the transaction is acceptable; the xact lock is
  what makes multi-replica dedupe safe. Two cheap improvements:
  1. **Send concurrently.** Use `asyncio.gather` over targets with
     `Semaphore(8)`, and a per-tick budget (`asyncio.timeout(30)`).
  2. **Batch the topic marks.** Collect the notified `(topic_id, due_since)`
     pairs and issue one `UPDATE … FROM (VALUES …)` just before `commit`. Row
     locks on `topics` are then held for milliseconds, not for the length of the
     network calls. Today a `PATCH /topics/x` can block behind a slow push.
- Keep "send, then mark". If the commit fails, the next tick resends. Duplicates
  collapse on device because the tag (`due-{id}`) is the same.
- Also prune `deleted_records` (§4) and dead targets in the tick, at most once
  an hour.

### Tests (no Apple needed)

- `tests/test_apns.py`: `ApnsSender` over `httpx.MockTransport` with a fresh
  `ec.generate_private_key(SECP256R1)` PEM. Assert path, headers, JWT (`kid`,
  `iss`, `iat`, verified with the public key), body ≤ 4096 bytes, the error
  table (parametrised), and token caching with a frozen clock.
- Registration API (upsert, validation locs, idempotent delete, sandbox routing),
  pruning, and a scheduler test (extend the `outbox` fixture at
  `backend/tests/test_push.py:52-72`) where one web subscription and one APNs
  device each get exactly one notification.

### Manual end-to-end (after enrolment)

Create a .p8 key, set the env vars, run the debug build on the phone (registers
as `sandbox`), use Settings → "Test this device", then a 15-minute interval
topic; check logs for 200 and `apns-id`. Add
`scripts/apns_send.py --token … --env sandbox` for direct debugging.

**PWA impact**: none at the API level. `PushTestResult` keeps `{sent, failed}`,
now summed across senders. **MCP impact**: none.

## 2. Actionable notification payload (B6)

Build a channel-neutral model in the scheduler, replacing `PushPayload`
construction at `scheduler.py:71-77`:

```python
class QuickLogEnum(StrictModel):   type: Literal["enum"]; key: str; label: str; options: list[{value,label}]  # active, ≤6
class QuickLogNumber(StrictModel): type: Literal["int","double"]; key; label; unit; min; max; decimals; last_value: float|None
class Notification: kind: "due"|"test"; title; body; url; tag; topic_id; topic_slug; version; due_since; quick_log
```

**Eligibility.** The `quick_log` descriptor is computed by a Python port of
`frontend/src/lib/quickLog.ts:27-39`: exactly one required question, either a
single enum with 1–6 active options or an int/double. Put it in
`services/quicklog.py`. Fixtures from §7 also cover this so TS, Python and Swift
agree. `last_value` needs one extra query per notified topic, against the latest
entry's answer for that key.

**APNs body.** Custom keys go at the root, outside `aps`
([Apple: Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)):

```json
{"aps": {"alert": {"title": "Water", "body": "Time to log"}, "sound": "default",
         "thread-id": "topic-<id>", "category": "quickr.topic.<id>", "mutable-content": 1,
         "relevance-score": 0.8},
 "quickr": {"v": 1, "kind": "due", "topic_id": "...", "topic_slug": "water", "version": 3,
            "due_since": "...", "url": "/t/water/record", "quick_log": {...}}}
```

- **`category` per topic, not per shape.** `UNNotificationCategory` actions are
  static, so option labels can't come from a generic category. The app registers
  `quickr.topic.<id>` categories from its local store on every sync. The
  **Notification Service Extension** (enabled by `mutable-content`) uses
  `quick_log` to rebuild or override `categoryIdentifier` when the local store
  is stale.
- Unknown categories simply show no actions, so the notification degrades
  safely.
- **`apns-collapse-id: due-{topic_id}`** is the existing tag. For remote
  notifications iOS sets `UNNotificationRequest.identifier` to the collapse id
  ([Apple forum thread 50606](https://developer.apple.com/forums/thread/50606)).
  A future **local fallback** that schedules `due-{topic_id}` will therefore be
  replaced by the server push, and vice versa. Freeze this identifier in the
  contract.
- **`thread-id: topic-{id}`** groups notifications per topic.
- The test push uses tag `test`, kind `test` and no category.
- Size: stay under the 4 KB limit (enforced in a test). Truncate labels to 64
  chars.

**Logging from the notification** needs no new endpoint:
`POST /topics/{id}/entries` with a client `id` (idempotent), `version` from the
payload (valid after later publishes, since entries pin versions),
`captured_at` = now, `X-QuickR-Channel: ios` and `meta.via = "notification"`.

**Web Push compatibility.** `PushPayload` (`backend/app/schemas/api.py:672-679`)
gains _optional_ `topic_id`, `version`, `kind` and `quick_log`. The SW parser
ignores unknown keys (`frontend/src/lib/pushPayload.ts:29-46`).

**Web actions for the PWA (optional, follow-up):**

- In `sw.ts:109-127`, when `quick_log` is an enum and
  `options.length <= Notification.maxActions`, pass
  `actions: [{action: "opt:<value>", title: label}]`. `maxActions` is
  browser-specific and not Baseline
  ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Notification/maxActions_static));
  Chromium is 2.
- In `notificationclick` (`sw.ts:152-156`), `event.action` enqueues an outbox
  entry, and the SW already owns the outbox and background sync.
- iOS Safari web push shows no actions, so iPhone PWA users keep the 2-tap flow.
  **Parity note**: the 1-tap notification log is native-only on iPhone, and
  Chromium-only (≤2 options) on the web.

**Tests**: update the exact-payload asserts at `backend/tests/test_push.py:165`
and `:247`. Add descriptor tests for enum, number with `last_value`, and an
ineligible topic (`quick_log: null`), plus an APNs body golden test.

**MCP impact**: none.

## 3. `ios` channel (B3)

- Model: add `ios = "ios"` to `Channel` (`backend/app/models.py:42-47`). OpenAPI
  and TS then gain `'ios'` in the union automatically.
- Migration `20261018_<rev>_entry_channel_ios.py`:
  - Upgrade, using Postgres 18 (`docker-compose.yml`):
    ```python
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE entry_channel ADD VALUE IF NOT EXISTS 'ios'")
    ```
    `alembic/env.py:15` runs every migration in **one** transaction. A new enum
    value can't be used in the transaction that added it, so a later migration
    in the same `upgrade head` that touched `'ios'` would fail. The autocommit
    block avoids that.
  - Downgrade: Postgres can't drop enum values.
    1. `UPDATE entries SET channel='api' WHERE channel='ios'`. This is lossy but
       documented, like the multi-select downgrade
       (`20261016_b2f3c4d5e6a7_multi_select_enums.py`).
    2. `ALTER TYPE entry_channel RENAME TO entry_channel_old`.
    3. `CREATE TYPE entry_channel AS ENUM ('ui','api','mcp')`.
    4. `ALTER TABLE entries ALTER COLUMN channel TYPE entry_channel USING channel::text::entry_channel`.
    5. `DROP TYPE entry_channel_old`.
  - `test_downgrade_and_upgrade_roundtrip`
    (`backend/tests/test_migrations.py:38-45`) exercises this.
  - `alembic check` doesn't compare enum values, so drift would go unnoticed.
    Add a test: insert an `ios` entry, downgrade one step, assert it is `api`.
- Header: no code change. `ChannelHeader` (`backend/app/api/routes.py:52-55`)
  parses the enum. The iOS client sends `X-QuickR-Channel: ios` and `source`
  defaults to `"ios"` (`entries.py:128`).
- Stats, filters and CSV: `?channel=ios` works through `EntryFilters`. CSV
  writes `channel.value`. Stats group by `source`, not channel. No change.
- Frontend: there is no channel filter UI. `EntryEditPage.tsx:84` shows a badge,
  so `ios` just renders. Regenerate the client (`make client`).
- MCP: `list_entries` filter accepts `ios` automatically.

## 4. Sync support (B4)

**Size estimate**: 10 topics × ~5 entries/day × 365 × 5 years ≈ 90k entries. At
~400 B of JSON each that's ~36 MB.

A one-off full pull (180 pages of 500) is fine, but re-pulling a window misses
PWA/MCP edits and deletes to **older** entries, which offline history must
show. Topics are tiny (≤ ~50 rows), so just re-pull them.

**Recommended (minimal, robust):**

1. **Topics**: `GET /topics?status=all&sort=updated&limit=200` on every sync. No
   new parameter.
   - When `current_version` exceeds the local max, call
     `GET /topics/{id}/versions`.
   - `entry_count`, `last_captured_at` and `due` are derived; the client
     recomputes them locally.
   - Deleted topics show up as missing ids _and_ as tombstones.
2. **Entries feed**: `GET /entries/changes?cursor=<opaque>&limit=500`
   (`listEntryChanges`, cross-topic). Response:
   ```
   EntryChanges{ server_time, items: EntryOut[], deleted: DeletedRecord[], next_cursor, has_more, resync_required }
   DeletedRecord{ kind: "entry"|"topic", id, topic_id, deleted_at }
   ```
   - The cursor encodes `(updated_at, id)` for keyset paging:
     `WHERE (updated_at, id) > (:ts, :id) ORDER BY updated_at, id`.
   - Tombstones are merged on `deleted_at > :ts`.
   - Omitting the cursor means a full sync.
   - `resync_required = true` when the cursor is older than the retention
     window. The client then wipes and re-pulls.
3. **Tombstones**: a
   `deleted_records(id uuid PK, kind text CHECK, topic_id uuid, deleted_at timestamptz default now())`
   table with an index on `deleted_at`.
   - Written in the **service** layer, so REST and MCP both get it:
     - `entry_svc.delete_entry` (`entries.py:200-204`).
     - `topic_svc.delete_topic` (`topics.py:333-338`). A topic tombstone implies
       all its entries are gone.
   - `create_entry` deletes any tombstone with the same id. That handles
     undo-delete by replaying the id.
   - The scheduler prunes rows older than 90 days.
   - Soft deletes were rejected: they would touch every query, stats and CSV.
4. **Index**: `ix_entries_updated_id (updated_at, id)`, in the same migration as
   the table.
5. **Clock and commit order**:
   - `now()` is transaction start, so a long transaction can commit "in the
     past"; the client restarts each session from `cursor − 2 min` (idempotent
     upserts make that free).
   - Use `func.now()` in `update_entry` (`entries.py:187` uses Python's clock).
   - `server_time` gives the client its skew, for `captured_at` (≤ now + 24 h)
     and due computation.
6. **Compression**: add `GZipMiddleware(minimum_size=1024)` in `create_app`.
   JSON compresses about 10×, and it helps the PWA too.

**Tests**: paging with equal `updated_at`; edits reappear; delete → tombstone,
replay clears it; topic delete → topic tombstone; MCP delete → tombstone;
retention → `resync_required`; migration roundtrip.

**PWA impact**: none. These are new endpoints only, and the regenerated TS
client gains functions. **MCP**: tombstones come for free. No new tool.

## 5. OpenAPI fixes for Swift codegen (B1)

- **`answers` map.** Pydantic emits `patternProperties` and `propertyNames`
  because `QuestionKey` has a pattern (`openapi.json:2924-2950`), and
  swift-openapi-generator drops it.
  - Fix: annotate `AnswerMap` (`backend/app/schemas/api.py:350-358`) with
    `WithJsonSchema({"type":"object","additionalProperties":{"anyOf":[{"type":"number"},{"type":"string"},{"type":"array","items":{"type":"string"}},{"type":"null"}]},"propertyNames":{"pattern":KEY_PATTERN}, ...description/examples})`.
  - Validation is unchanged because it's schema-only.
  - Dropping the redundant `integer` branch also removes the int/number overlap.
  - **TS diff**: today's type is
    `{[key]: unknown | number | number | string | Array<string> | null}` and zod
    is `z.record(z.string(), z.unknown())`
    (`frontend/src/client/zod.gen.ts:139`). After the change, zod becomes a
    typed union record. That is stricter request validation that matches the
    server. Expect small `typecheck` fallout wherever the UI builds answers as
    `unknown`.
  - A test should assert the spec has `additionalProperties` for
    `EntryCreate.answers` and `EntryUpdate.answers`.
- **Input/Output split** (`backend/app/schemas/base.py:26`, 7 pairs): **keep
  it.** The frontend uses `*Input`/`*Output` types in ~60 places
  (`EnumQuestionOutput` ×15) and the split is real semantics (defaults optional
  on input, required on output). Swift just gets two structs per pair.
- **`const` discriminators and `anyOf[oneOf, null]`**: leave the canonical spec
  alone.
  If the Swift generator mishandles them, add `scripts/openapi_swift.py` to
  derive `ios/openapi.json` (`const` → single-value `enum`; `anyOf[X, null]` →
  X, not required), run by `make client-ios` with a CI drift check. TS output
  never changes.
- **Date-times with fractional seconds**: client-side transcoder (iOS doc). No
  server change.
- Every schema change runs `make client`; CI checks both artefacts
  (`.github/workflows/ci.yml`).

## 6. Cloudflare Access (B7, later)

- **Service tokens**: headers `CF-Access-Client-Id` / `CF-Access-Client-Secret`;
  the policy action must be **Service Auth** or Access redirects to IdP login.
  Under strict service-token auth (default for organisations created after
  2026-10-05) **no `CF_Authorization` cookie is returned**, so the app and its
  extensions send both headers on every request. A single-header variant exists
  ([Cloudflare: service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)).
- **Backend stays open.** Never trust `Cf-Access-Authenticated-User-Email`: with
  no auth model, it adds nothing and is spoofable if the origin is ever
  reachable directly. Optional defence in depth later: verify
  `Cf-Access-Jwt-Assertion` against the team JWKS when `QUICKR_ACCESS_AUD` is
  set.
- **PWA**: same origin (nginx proxies `/api`), so no CORS preflights; Access's
  preflight 403s only hit cross-origin calls (fix: "Bypass OPTIONS to origin",
  [Cloudflare: CORS](https://developers.cloudflare.com/cloudflare-one/identity/authorization-cookie/cors/)).
  **Risk**: an expired Access cookie gives background sync a redirect or
  401/403 HTML; the outbox (`frontend/src/lib/outbox/outbox.ts`) must treat
  that as retryable, not terminal.
- **MCP**: remote MCP clients usually can't add custom headers. They need a
  separate Access application or policy for `/mcp` (service token if the client
  supports headers, otherwise a bypass restricted by IP or WARP).
- **APNs and Web Push are outbound only.** HTTP/2 goes to
  `api(.sandbox).push.apple.com:443` and to browser push services. Nothing
  inbound is needed beyond the tunnel.

## 7. Due-logic test vectors (B2)

- **Generator**: `backend/tests/test_due_vectors.py`.
  - Deterministic (no wall clock, no randomness). Evaluates `compute_due`, `daily_slots` and `due_message`
    (`backend/app/services/schedule.py:58-159`), plus `quick_log` eligibility
    (§2).
  - Serialises to `shared/fixtures/due-vectors.json` with sorted keys and UTC
    ISO-8601 at second precision.
  - If `QUICKR_UPDATE_VECTORS=1`, it writes the file. Otherwise it asserts the
    file equals the regenerated output. That is the same drift pattern as
    `openapi.json`, so CI fails if the logic changes without updating the
    vectors.
  - `make vectors` regenerates.
- **Content** (aim for ~1–2k cases, under 1 MB):
  - `meta`: `generator_version`, `tzdata` version (`zoneinfo.TZPATH` /
    `tzdata.IANA_VERSION`), and the semantics notes:
    - `EARLY_WINDOW_MAX = 2h`.
    - Gap times map forward by the gap; ambiguous times use the first
      occurrence.
    - Slots before `schedule_since` are ignored.
  - `slots[]`: `{schedule, start, end, expected[]}`.
  - `due[]`:
    `{name, schedule, schedule_since, last_entry_at|null, now, expected:{is_due, due_since, next_due_at}}`.
  - `messages[]`: `{schedule_tz, due_since, now, expected}`. The local fallback
    must produce the same "Overdue since Mon 08:00" text; note that `%a`/`%b`
    are C-locale English.
- **Grid**: Europe/London (2026-03-29, 2026-10-25), America/New_York
  (2026-03-08, 2026-11-01), Australia/Lord_Howe (30-min DST), Asia/Kolkata,
  Asia/Kathmandu, UTC. Slot times `00:00`, `01:30`, `02:30` (gap) and `23:59`;
  weekly single-day (lookback) and multi-time (half-gap window) schedules;
  intervals at 15 and 129600. `now` sweeps ±3 h around each transition in
  15-minute steps, with `last_entry_at` around the early window.
- **Key hazard**: Python normalises a nonexistent `01:30` to `02:30` BST (offset
  of the pre-gap fold), as tested at `backend/tests/test_schedule.py:147-156`.
  Foundation's `Calendar` skipped-time policy can return `02:00` instead. The
  vectors pin this down.
- **iOS consumption**: the Swift test target bundles
  `../shared/fixtures/due-vectors.json` as a resource and asserts every case in
  `make check-ios`. Choose 2026–2027 dates, where the tz rules are stable across
  tzdata versions.

## 8. Ordering

1. **Before any iOS code**: B1 (spec fix) and B2 (vectors). They're small,
   remove codegen guesswork and pin the due semantics.
2. **Before the offline store and outbox milestone**: B3 (`ios` channel) and B4
   (changes feed and tombstones). The sync engine is built against them, and the
   outbox needs `ios` from its first entry.
3. **Before the reminders milestone**: B5 (APNs). Code and mock tests can land
   any time with APNs off by default. The manual end-to-end check waits for
   Apple enrolment, Xcode and a .p8 key.
4. **Before the log-from-notification milestone**: B6, built on B5's
   `Notification` model. Web actions in `sw.ts` can follow separately.
5. **Hosting milestone**: B7 (outbox 401/403 classification in the PWA, docs,
   optional JWT check).

B1–B4 and B6's Web Push fields are additive and PWA-safe. They land in
`feat/ios-app` per the process, but are the natural candidates for early
standalone PRs to `main` if the final PR gets too large. Each must keep
`make check` green and include the regenerated `openapi.json` and
`frontend/src/client`.

### Sources

- Apple:
  [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
  [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns),
  [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification),
  [UNNotificationRequest.identifier and collapse id](https://developer.apple.com/forums/thread/50606)
- APNs key scoping (team vs topic, per environment):
  [Airship docs](https://docs.airship.com/platform/mobile/setup/configure-channels)
- PyPI: [httpx](https://pypi.org/project/httpx/),
  [h2](https://pypi.org/project/h2/),
  [aioapns](https://pypi.org/project/aioapns/)
- Cloudflare:
  [Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/),
  [CORS with Access](https://developers.cloudflare.com/cloudflare-one/identity/authorization-cookie/cors/)
- MDN:
  [Notification.maxActions](https://developer.mozilla.org/en-US/docs/Web/API/Notification/maxActions_static)
