# quickR

Config-driven data capture. Create **topics**, give each an ordered set of typed
**questions**, and record **entries** (one entry = one set of answers for a
topic) from your phone, the API, or an MCP client. Then browse, edit, aggregate
and export the results. Topics can have a **schedule**; quickR tells you (and,
with Web Push, your phone) when an entry is due.

- **Question types:** `int` (min/max, unit), `double` (min/max, decimals, unit),
  `str` (min/max length, multiline), `enum` (options configured up front,
  archivable; single- or multi-select with `multiple`, `min_selected`,
  `max_selected`).
- **Every entry records** its `source`, `captured_at`, `channel` (ui/api/mcp),
  the topic `version`, `notes` and free-form `meta`.
- **Offline-safe:** clients may send their own entry `id`. Re-sending the same
  entry returns the stored one instead of creating a duplicate.
- **Safe evolution:** topics are versioned. Each entry is pinned to the version
  it was recorded against, so historic answers always stay interpretable.

## Architecture

```
frontend/  React 19 + TS (strict) + Vite + Tailwind + TanStack Query + react-hook-form/zod
           └─ src/client/   ← generated from openapi.json (types, zod schemas, SDK, query hooks)
backend/   FastAPI + Pydantic v2 + SQLAlchemy 2 (async) + Alembic + FastMCP
           ├─ app/schemas/  ← single source of truth for every type
           ├─ app/services/ ← business logic shared by REST and MCP (+ the push scheduler)
           ├─ /api/v1       ← REST API (OpenAPI at /docs, /openapi.json)
           └─ /mcp/         ← MCP server (streamable HTTP)
openapi.json  generated from FastAPI and committed. CI fails if it drifts.
```

Types flow one way: **Pydantic models → FastAPI → `openapi.json` → hey-api
codegen → TS types + zod schemas + SDK**. Nothing is hand-duplicated. After
changing a backend model, run `make client`.

The API and MCP have **no authentication**. Put them behind your own gateway or
auth proxy.

## Quick start

```bash
make up            # full stack in docker → http://localhost:8080 (API :8100, Postgres :5433)
```

Local development:

```bash
make install       # uv sync + pnpm install
make db migrate    # Postgres in docker on :5433, apply migrations
make api           # FastAPI on :8100 (reload)
make web           # Vite on :5180 (proxies /api and /mcp to :8100; QUICKR_API_TARGET overrides)
make seed          # optional demo data (scheduled topics, a multi-select question)
make check         # everything CI runs except the docker smoke test (needs Postgres)
make notebook      # Jupyter tour of the REST API + MCP (backend/notebooks/explore_api.ipynb)
```

Configuration is via `QUICKR_*` environment variables (or `backend/.env`):

| Variable                            | Default                                                    |
| ----------------------------------- | ---------------------------------------------------------- |
| `QUICKR_DATABASE_URL`               | `postgresql+asyncpg://quickr:quickr@localhost:5433/quickr` |
| `QUICKR_CORS_ORIGINS`               | `["http://localhost:5180","http://localhost:8080"]`        |
| `QUICKR_VAPID_PRIVATE_KEY`          | unset → generated once and stored in the database          |
| `QUICKR_VAPID_PUBLIC_KEY`           | derived from the private key when unset                    |
| `QUICKR_VAPID_SUBJECT`              | `https://github.com/Richard-Lynch/quickr`                  |
| `QUICKR_SCHEDULER_ENABLED`          | `true`                                                     |
| `QUICKR_SCHEDULER_INTERVAL_SECONDS` | `60`                                                       |
| `QUICKR_PUSH_ALLOWED_HOSTS`         | `[]`: extra push-service hosts (JSON list), see below      |
| `QUICKR_MIN_CLIENT_LEVEL_IOS`       | unset: an emergency raise of the iOS minimum level (\*)    |
| `QUICKR_MIN_CLIENT_LEVEL_WEB`       | unset: the same for the PWA (\*)                           |
| `QUICKR_IOS_UPDATE_URL`             | `itms-beta://` (opens TestFlight)                          |

(\*) Raises, never lowers, `min_client_level` from `shared/api-level.json`, and
is capped at its `api_level`
([client-versions.md §2](docs/specs/client-versions.md#2-the-source-of-truth)).

Tests use `QUICKR_TEST_DATABASE_URL` (default
`postgresql+asyncpg://quickr:quickr@localhost:5433/quickr_test`, or
`quickr_test_<worktree directory>_<path hash>` in a git worktree, so parallel
worktrees don't share tables). The database is created and migrated automatically.
`make test-db-reset` drops it, e.g. after a migration was edited in place, and `make
test-db-prune` drops this checkout's peer databases (`*_peer_*`) that a killed test
run left behind, once they're an hour old (`make test-db-prune all=1`: every
checkout's).

## Entries

`POST /api/v1/topics/{ref}/entries` takes
`{answers, id?, captured_at?, source?, notes?, meta?, version?}`:

- `answers` maps question key → value: integers for `int`, numbers for `double`,
  strings for `str`, an option value for `enum`, and a **list** of option values
  for multi-select `enum`. `null`, a blank string or an empty list means
  unanswered.
- `id` (optional UUID) makes the request idempotent. If an entry with that id
  already exists for the topic, it is returned (`201`, no duplicate), even if
  the topic has been archived since. The same id under another topic is a `409`.
  Offline clients should always send one. A deleted id can never be used again:
  creating it returns `409 entry_deleted` (see [Change feed](#change-feed)).
- `captured_at` is the client's own clock. It may be arbitrarily late (offline
  queues), but not before 2000-01-01 or more than 24 hours in the future.

Multi-select answers come back as `{"type": "enum_list", "value": [...]}` in
option order. In stats, each option counts the entries that selected it, so for
multi-select questions the shares can add up to more than 1. CSV exports join
multi-select values with `;`.

## Schedules and due status

A topic can have an optional, unversioned `schedule`. Set it on create or with
`PATCH /topics/{ref}` (`"schedule": null` removes it):

```jsonc
{"kind": "daily", "times": ["08:00", "21:00"], "days": [1, 2, 3, 4, 5], "timezone": "Europe/London", "notify": true}
{"kind": "interval", "every_minutes": 2880, "timezone": "Europe/London", "notify": true}
```

Daily `days` are ISO weekdays (1 = Monday, default every day). Times are local
to `timezone` (any IANA zone), so slots follow DST. Every topic summary carries
`due: {is_due, due_since, next_due_at, last_entry_at}` (`null` when
unscheduled):

- **Daily:** a slot is each time on each allowed day. Let _s_ be the latest slot
  at or before now and _p_ the slot before it. _s_ is satisfied by any entry
  captured at or after _s_ − min(2 h, (_s_ − _p_) / 2), so logging a bit early
  counts. Otherwise the topic is due since _s_. `next_due_at` is the next slot
  that isn't already satisfied. For example, if you log at 07:30 for the 08:00
  slot, it is the slot after that.
- **Interval:** due `every_minutes` after the latest entry (`due_since` = that
  instant). A topic with no entries becomes due one interval after its schedule
  was set.
- Only the schedule's own lifetime counts. `schedule_updated_at` records when
  the schedule was last set or changed (re-sending an identical schedule keeps
  it). Daily slots before it are ignored, and intervals never count from an
  entry older than it. A new or changed schedule therefore never makes a topic
  overdue right away.
- Archived topics are never due.

`GET /topics` sorts by `due` by default. Due topics come first (longest overdue
first), then scheduled topics by `next_due_at`, then everything else by latest
activity. `?due_only=true` lists only due topics.

## Push notifications

When a scheduled topic with `notify: true` becomes due, the backend sends one
Web Push notification per due slot to every subscribed browser. The service
worker receives this JSON:

```json
{
  "title": "Sleep log",
  "body": "Time to log",
  "url": "/t/sleep-log/record",
  "tag": "due-<topic id>",
  "topic_slug": "sleep-log",
  "v": 1,
  "kind": "due",
  "server_id": "<server id>",
  "topic_id": "<topic id>",
  "version": 3,
  "due_since": "2026-10-17T08:00:00Z",
  "quick_log": { "type": "enum", "key": "quality", "label": "Quality", "options": […], "total_options": 3 }
}
```

The body is "Time to log" for a fresh slot, or e.g. "Overdue since 08:00" when
the notification goes out late. `quick_log` is null unless the topic can be
logged in one tap (docs/ios/specs/notifications.md §2.3); a test push has only
the first five fields and `kind: "test"`.

**Actions (Chrome, Edge, Android).** A reminder for a one-tap topic shows
buttons: the first options of a single-select question (up to the browser's
`Notification.maxActions`, usually 2), or "Log 7.5 h" to log a number question's
last value again. Clicking one logs the entry from the service worker, even with
the app closed: it goes into the same offline outbox as the app (source
`pwa.notification`) and is sent at once, or later by Background Sync or the
app's next start. Each reminder logs at most once, however often its buttons are
clicked, even when it is also actioned in the iOS app: both derive the entry id
from the reminder (docs/ios/specs/notifications.md §7.4). The first choice wins:
clicking a different button later shows "Already logged as …". The request
carries the reminder's server id (`X-QuickR-Expect-Server-Id`), so a reminder
from a server this address no longer serves logs nothing. When a click can't be
logged (another server, an archived or deleted topic), a follow-up notification
says why; it never just disappears. Safari and iOS web push show no buttons;
tapping the notification opens the record screen as before.

*Manual test (Chrome desktop):* subscribe in Settings, make a topic whose only
required question is a single-select with 2–4 options and give it a schedule
that is due now, then wait for the scheduler's next tick
(`QUICKR_SCHEDULER_INTERVAL_SECONDS`). On the notification, click an option: the
entry appears with source `pwa.notification`. Click the same reminder's other
button (if it is still shown, e.g. from the notification centre): no second
entry, and an "Already logged" notification. Archive the topic and click a fresh
reminder: a "Couldn't log" notification. Repeat with the network offline in
DevTools: the entry is queued and sent when you go back online.

Setup:

1. **VAPID keys.** With no configuration, the backend generates a key pair on
   first use and stores it in the `app_settings` table, so it survives restarts.
   To manage keys yourself, run `make vapid` and set `QUICKR_VAPID_PRIVATE_KEY`
   (and optionally `QUICKR_VAPID_PUBLIC_KEY`). Changing the keys invalidates
   every existing subscription.
2. **Subject.** `QUICKR_VAPID_SUBJECT` identifies the sender to push services.
   It must be a `mailto:` address or an `https://` URL. The default (the project
   URL) works everywhere. Apple rejects `mailto:…@localhost`.
3. **HTTPS.** Browsers only allow push on secure origins: `https://` or
   `http://localhost`.
4. **Scheduler.** It runs inside the API process and checks every
   `QUICKR_SCHEDULER_INTERVAL_SECONDS`. It is safe with several replicas,
   because each tick takes a Postgres advisory lock. Subscriptions the push
   service reports as gone (404/410) are deleted.
5. **Allowed push services.** The API has no auth, so subscription endpoints are
   restricted to known browser push services: `fcm.googleapis.com`
   (Chrome/Edge/Android), `updates.push.services.mozilla.com` (Firefox),
   `*.push.apple.com` (Safari/iOS), and `*.notify.windows.com` /
   `*.wns.windows.com`. Anything else gets a `422`. To allow more hosts, add
   them with `QUICKR_PUSH_ALLOWED_HOSTS='["push.example.org"]'` (this adds to
   the defaults; subdomains match). Before each send, the backend also checks
   that the host resolves only to public IP addresses, and it never follows
   redirects.

**iPhone/iPad:** Web Push only works when the PWA has been added to the Home
Screen (iOS/iPadOS 16.4 or later), and permission must be requested from inside
the installed app. Safari can do this via Share → Add to Home Screen. Chrome on
iOS can too, via its share menu → Add to Home Screen.

Endpoints: `GET /push/config` (VAPID public key for `PushManager.subscribe`,
and `apns_enabled`), `POST /push/subscriptions` (upsert
`subscription.toJSON()`), `POST /push/subscriptions/delete` (`{endpoint}`) and
`POST /push/test` (every browser and every iOS device).

### APNs (the iOS app)

The native iOS app gets the same notifications through Apple Push Notification
service. APNs is **off** unless it is configured, and `GET /push/config` says
`apns_enabled: false`. Devices can still register while it is off; nothing is
sent to them.

1. In the Apple Developer portal, under Certificates, Identifiers & Profiles ▸
   Keys, create a key with **Apple Push Notifications service (APNs)**, enabled
   for Sandbox & Production. Download the `.p8` file (it can only be downloaded
   once) and note its **Key ID** and your **Team ID**. Keep the file out of the
   repo.
2. Set:

   | Variable                                                       | Value                                                                                                                          |
   | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
   | `QUICKR_APNS_TEAM_ID`                                          | Your Team ID                                                                                                                   |
   | `QUICKR_APNS_KEY_ID`                                           | The key's Key ID                                                                                                               |
   | `QUICKR_APNS_PRIVATE_KEY_FILE`                                 | Path to the `.p8` file, **or**                                                                                                 |
   | `QUICKR_APNS_PRIVATE_KEY`                                      | the `.p8` contents (PEM; literal `\n` escapes are fine)                                                                        |
   | `QUICKR_APNS_TOPIC`                                            | The app's bundle id. Default `com.bahumia.quickr`                                                                              |
   | `QUICKR_APNS_SANDBOX_KEY_ID`, `..._SANDBOX_PRIVATE_KEY[_FILE]` | Optional: a separate key for the sandbox host, if your production key is limited to production. Otherwise one key serves both. |

   With Docker, mount the key read-only: copy
   `docker-compose.override.yml.example` to `docker-compose.override.yml` and
   fill it in. The container runs as uid 10001, so the file must be readable
   by it (for example `chmod 644`).

3. Restart the API. A key that is set but can't be loaded is logged as an error
   the first time APNs is used, and APNs stays off (`apns_enabled: false`).

Each app install registers its device token on every launch with
`POST /push/apns/devices` (`{token, environment, bundle_id?, app_version?, device_name?}`;
an upsert by token that resets its failure count). `environment` is `sandbox`
for debug builds and `production` for TestFlight and App Store builds, and
picks `api.sandbox.push.apple.com` or `api.push.apple.com`.
`POST /push/apns/devices/delete` (`{token}`) unregisters, and
`POST /push/apns/devices/test` (`{token}`) sends a test to that one device
("Test this device"; `409 apns_disabled` when APNs is off).

Requests use HTTP/2 with an ES256 provider token that is cached and re-signed
every 50 minutes. Responses `410` and `400 BadDeviceToken` delete the device
(the app registers again on its next launch). `400 DeviceTokenNotForTopic`
means `QUICKR_APNS_TOPIC` doesn't match the app's bundle id; it and any other
`400` are logged as errors.

To debug without the scheduler, send straight to a token:

```sh
cd backend && uv run python scripts/apns_send.py --token <hex token> --env sandbox
```

It prints Apple's `apns-id`, or the status and reason.

To test a topic's real reminder (its category and actions, a log topic's quick
actions or a timed topic's Start) without waiting for the scheduler, send it now
to every registered device and browser:

```sh
make send-reminder t=morning-routine                     # a timed topic: one "Start" action
make send-reminder t=mood a="--channel apns"             # a log topic: its quick actions, APNs only
make send-reminder t=mood a="--due-since 2026-10-26T08:00:00Z --dry-run"  # print the payloads, send nothing
make send-reminder-docker t=mood                         # against the docker stack
# the same, by hand: docker compose exec backend python -m scripts.send_reminder mood --dry-run
```

`t` is a topic slug or id. The notification is built and delivered by the
scheduler's own code, under the same lock as the test push, so it is exactly
what a scheduled reminder would be. It is a test send: the topic's slot is not
marked as notified and its due state doesn't change. `--due-since` (default: now,
to the second) sets the slot; the entry id a log action uses, and the run id a
Start uses, derive from it, so give each test a new one to act on the same
reminder again. `--channel` is `apns`, `webpush` or `all` (the default). The
script prints the category, the actions, the action entry id and how many
targets it reached.

### Delivery semantics

Delivery is **best-effort per device, at least once per slot overall**. Each
scheduler tick sends a due slot to every browser and device (eight at a time),
then marks the slot as notified in the same transaction. A target that fails is
not retried for that slot. If the tick fails before it commits, nothing is
marked and the next tick sends the slot again; the duplicate replaces the first
notification on the device, because both carry the same tag (`due-<topic id>`,
the APNs collapse id). Delivery stops 30 seconds into a tick, even in the middle of a topic. That topic's slot is not marked; the targets it already reached are recorded (`push_slot_deliveries`), and the next tick continues with the others, so every target gets the slot once even when a fan-out takes several ticks. Due topics go oldest slot first, so the topics after it follow. A target is deleted when
its push service says it is gone, or after 20 failures in a row with no success
for 30 days.

Device tokens and subscription endpoints never appear in the logs: request
lines from httpx (APNs) and urllib3 (Web Push) are redacted, and delivery
errors give only the host, the status and the error type.

## Versioning rules

Questions are identified by their `key` across the topic's whole history. When
you publish a new version (`POST /topics/{ref}/versions`):

| Change                                         | Allowed?                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| Labels, help text, units, required flag, order | ✅                                                                 |
| Add / remove a question                        | ✅ removed questions keep their data and still appear in stats/CSV |
| Re-add a removed key with the **same** type    | ✅ (`restored`)                                                    |
| Tighten or loosen min/max/length/selection     | ✅ with a warning (old entries remain valid for their version)     |
| Add an enum option, archive / unarchive one    | ✅                                                                 |
| Single-select enum → multi-select              | ✅ with a warning (old answers count as one-option selections)     |
| Multi-select enum → single-select              | ❌ use a new key                                                   |
| Change a key's type (even a historic key)      | ❌ use a new key                                                   |
| Remove an enum option                          | ❌ archive it instead                                              |

`POST /topics/{ref}/versions/check` is a dry run. It returns the change list and
any errors, warnings or info. Publishing also requires `base_version` to equal
the topic's current version (optimistic concurrency, `409` otherwise), and a
`timer`: the version's steps (`{steps: [{key, label}]}`) for a timed topic, or
`null`. It is required, so a client that leaves it out can't switch timing off;
send the current version's timer to keep it.

## API overview

|                                                                                               |                                                       |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `GET /api/v1/topics?q=&status=&sort=&due_only=&limit=&offset=`                                | list/search topics (default sort: `due`)              |
| `POST /api/v1/topics` · `GET/PATCH/DELETE /api/v1/topics/{ref}`                               | CRUD (`ref` = slug or UUID; delete requires archived) |
| `POST /api/v1/topics/{ref}/archive` · `/unarchive`                                            | archive management                                    |
| `GET /api/v1/topics/{ref}/versions` · `POST .../versions/check` · `POST .../versions`         | version history, dry-run, publish                     |
| `GET/POST /api/v1/topics/{ref}/entries` · `GET .../entries.csv`                               | list/record/export entries                            |
| `GET/PATCH/DELETE /api/v1/entries/{id}`                                                       | view/correct/delete an entry                          |
| `POST /api/v1/runs/{run_id}/events` · `GET /api/v1/runs[/{run_id}]?status=&topic=`            | record a run tap · list open/finishing runs, read one |
| `GET /api/v1/changes?after=&limit=`                                                           | change feed (sync)                                    |
| `GET /api/v1/topics/{ref}/stats` · `GET .../timing` · `GET .../questions/{key}/series`        | aggregation, run timing stats and time series         |
| `GET /api/v1/push/config` · `POST /api/v1/push/subscriptions[/delete]` · `POST .../push/test` | Web Push                                              |
| `POST /api/v1/push/apns/devices[/delete]` · `POST .../push/apns/devices/test`                 | APNs device tokens (the iOS app)                      |
| `POST /api/v1/push/apns/live-activities[/delete]`                                             | Live Activity push tokens (the iOS app)               |
| `GET /api/v1/question-types` · `GET /api/v1/limits`                                           | question JSON schemas · validation limits             |

Send `X-QuickR-Channel: ui|api|mcp|ios` to tag the channel (defaults to `api`).

Every 4xx uses one envelope: `{code, detail, errors: [{loc, message}]}`. Each
error points at the most specific field. For example, `min > max` on the first
question of a create request is reported at `["body", "questions", 0, "max"]`,
and a duplicate option label at
`["body", "questions", 2, "options", 1, "label"]`. `GET /limits` returns the
numeric ceilings (max questions, options, lengths, schedule bounds, …) so
clients can mirror server-side validation.

## Change feed

`GET /api/v1/changes?after=<seq>&limit=<≤500>` lets a client keep a full offline
copy in step. Every change to a topic, version, entry or run, made over REST or
MCP, appends a row to `change_log` in the same transaction. Runs appear as items
only while open or finishing; a run that stops or is discarded leaves as a `run`
deletion, and a stopped run's data arrives as its entry
([timers.md §7.1](docs/specs/timers.md#71-the-feed-server)). Each page returns the
**current** state of every entity changed after the cursor (`items`), the
deletions (`deleted`), and `{next, has_more, head, epoch, server_id, server_time}`.
Start from `after=0` and follow `next` while `has_more`.

- **Ordering.** Every write takes one advisory lock as its first statement, so
  `seq` order is commit order: a page never skips a change that commits later.
  Deadlocks and serialization failures are retried up to 3 times.
- **Tombstones.** Deleted ids are kept forever in `deleted_ids`.
  `DELETE /entries/{id}` is idempotent: it returns `204` even for an id the
  server has never seen, and reserves it, so a create that arrives after its own
  undo gets `409 entry_deleted` and never brings the entry back. A topic
  deletion also deletes all its versions, entries and runs.
- **Derived fields.** Entry changes don't re-send their topic, so clients
  recompute `entry_count`, `last_captured_at` and due status from entries.
- **Revisions.** Topics and entries carry a `revision` that every update bumps.
  `PATCH` (body) and archive/unarchive (query) accept an optional
  `expected_revision`; a mismatch is `409 stale_revision`.
- **Restores.** `epoch` changes when the database is restored or reset; a client
  that sees a new epoch, or a cursor above `head`, rebuilds from `after=0`.
  After restoring a backup, run `make rotate-epoch` (or `make rotate-epoch-docker`).
  The `server_id` never changes, restores included.
- **Identity headers.** Every `/api/v1` response, errors included, carries
  `X-QuickR-Server-Id` and `X-QuickR-Epoch`. Mutations accept
  `X-QuickR-Expect-Server-Id` / `X-QuickR-Expect-Epoch`; a mismatch is rejected
  with `409 server_mismatch` / `409 epoch_mismatch` before anything is written.
- **Server time.** Every `/api/v1` response, errors included, also carries
  `X-QuickR-Server-Time`: the server's clock in integer Unix epoch milliseconds.
  Clients stamp run events with it (device time plus the measured offset;
  [timers.md §5.1](docs/specs/timers.md#51-run-event-time-server-clock-monotonic-per-device)).

## MCP

Point any MCP client at `http://<host>/mcp/` (streamable HTTP). Tools:
`list_topics` (with `sort`/`due_only`), `list_due_topics`, `get_topic`,
`create_topic`, `update_topic`, `set_topic_archived`, `list_topic_versions`,
`check_topic_version`, `publish_topic_version`, `record_entry`, `list_entries`,
`update_entry`, `delete_entry`, `topic_stats`, `question_series`.

```bash
claude mcp add --transport http quickr http://localhost:8100/mcp/
```

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on every PR:

- **backend:** ruff, strict mypy, OpenAPI drift check, Alembic migration check,
  pytest against Postgres.
- **frontend:** codegen drift check, prettier, eslint (strict type-checked),
  tsc, vitest, build.
- **docker:** builds the images, boots the compose stack, and smoke-tests the
  UI, API and MCP through nginx.

`main` is protected. Changes land through PRs with all three checks green. When
CI passes on `main`, `release.yml` publishes multi-arch images to
`ghcr.io/richard-lynch/quickr-{backend,frontend}`, tagged `latest` plus the
commit SHA, and with semver tags for `v*` tags.
