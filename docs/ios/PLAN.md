# quickR iOS: delivery plan

**Status: v3**, 2026-10-17. v2 revised draft v1 after two adversarial
reviews, [Codex](reviews/plan-v1-codex.md) and
[Fable](reviews/plan-v1-fable.md). §12 maps each finding to how it was resolved.

Inputs:

- [REQUIREMENTS.md](REQUIREMENTS.md): the decisions. These are binding.
- Research: [00](research/00-scouting.md), [01](research/01-toolchain.md),
  [02](research/02-architecture.md), [03](research/03-backend.md).

Where this plan and the research disagree, **this plan wins**.

## 1. Summary

A native SwiftUI app (iOS 26+, iPhone) lives in `ios/` in this repo. It is a
thin XcodeGen project around a local Swift package, `QuickrKit`.

- **Storage:** a full offline mirror in GRDB/SQLite inside the App Group.
  **Server state** and a **local outbox overlay** are kept separate, so a resync
  can never lose offline work.
- **Reading changes:** a new server **change feed**. It is ordered by a sequence
  number that follows commit order, and it records deletions as permanent
  tombstones. A deleted id can never be recreated, so a late or repeated send
  can't bring back an entry the user deleted.
- **Reminders:** server-sent APNs with actions (up to 4), so you can log from
  the notification.
- **Widgets, Controls and App Intents** (Siri, Shortcuts, the Action button)
  write to the same shared store.
- **Backend changes** are additive and safe for the PWA. The PWA gains the new
  features wherever the web platform allows.

Milestones M0–M7 each go as one PR into `feat/ios-app`, with validation and demo
media. A final PR takes `feat/ios-app` into `main`.

## 2. Key decisions

Rejected alternatives and sources are in the research files. **(v2)** marks a
decision that changed after review.

| Area                          | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project                       | **XcodeGen**, from `ios/project.yml`. The `.xcodeproj` is generated and gitignored. `Package.resolved` is committed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Package **(v2)**              | **Three** SPM targets:<br>• `QuickrCore`: models, validation, quick-log, due logic. No dependencies.<br>• `QuickrData`: API client, GRDB store, sync, outbox.<br>• `QuickrUI`: design system. iOS only.<br>Core and Data also build for macOS, so `swift test` runs fast. The App Intents types live in the package; the `AppShortcutsProvider` and its phrases live in the **app target**.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Targets                       | `QuickR` app, `QuickRWidgets` (widgets and controls), `QuickRNotificationService` (NSE), unit tests and UI tests.<br>Entitlements: App Group `group.com.bahumia.quickr`, keychain group `com.bahumia.quickr.shared`, and `aps-environment` on the app.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Toolchain **(v2)**            | Local: **Xcode 27.x**, after the macOS upgrade. CI: `macos-26` with Xcode 26.6, or the `xcode-27` image if it is generally available by M1.<br>Rules: deployment target iOS 26.0, `swift-tools-version: 6.2`, and no iOS 27-only API (enforced with `@available`), so both toolchains build the same code.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Persistence                   | **GRDB 7** `DatabasePool` (WAL) in the App Group, using GRDB's multi-process recipe with suspension notifications. **(v2)** Every process may run the append-only migrator inside one IMMEDIATE transaction. The app and its extensions always ship together, so there's no version skew. The JSONL fallback is dropped. File protection: `completeUntilFirstUserAuthentication`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Store model **(v2)**          | Two layers:<br>• the **server layer** (`topic`, `topic_version`, `entry`), written only by sync;<br>• the **outbox** of pending operations.<br>The UI reads the server layer with the outbox applied on top. A resync rebuilds the server layer only.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Local data                    | Mirror everything: all topics (archived included), all versions and all entries. Stats and series are server-computed and cached; offline they show as stale with a "Last updated" label.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **Change feed (v2)**          | **`change_log(seq bigserial, kind, op, entity_id, topic_id, at)`**, written by the **service layer** (REST and MCP) in the same transaction as each change. The `seq` is allocated under a **transaction-scoped advisory lock**, so seq order equals commit order.<br>`GET /api/v1/changes?after=<seq>&limit=` returns the latest state of each changed entity, plus deletions, plus `{next, has_more, epoch}`.<br>Bootstrap: a migration backfills one row per existing entity, so a fresh client simply starts from `after=0`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Tombstones **(v2)**           | A deletion writes a `change_log` row plus a **permanent** `deleted_ids` record. These are never pruned; a personal dataset only adds a few KB a year.<br>Recreating a deleted entry id returns **409 `entry_deleted`**. Clients treat this as done for a create, and as success for an undo.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Epoch **(v2)**                | `app_settings.feed_epoch` is a random id, regenerated whenever the database is restored or reset. If the client's epoch doesn't match, it rebuilds the server layer and keeps its outbox.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Outbox **(v2)**               | A **new design** that extends the PWA's `entry.create` outbox, specified in `docs/ios/specs/outbox.md` with a test matrix.<br>• **Kinds:** `entry.create`, `entry.update`, `entry.delete`, `topic.archive`, `topic.unarchive`.<br>• **Classification and backoff:** the same as the PWA.<br>• **One flush at a time across processes,** using a single `flush_lock` row (owner, expiry) taken in `BEGIN IMMEDIATE`.<br>• **Ordering:** items for one entity are processed in `created_at` order.<br>• **Coalescing:** an update is folded into an unsent create; a delete of an unsent create drops both.<br>• **"Delivery uncertain" creates** (attempted, response lost) are never silently discarded. Undoing one enqueues a delete after it.                                                                                                                                                                                                                                                                                                                                                                |
| Server-side safety **(v2)**   | A stale sender (for example a suspended process whose lock expired) can't do harm:<br>• a late create after a delete gets 409 `entry_deleted`;<br>• a late PATCH gets 404, which drops the local row and the item with a notice;<br>• a late DELETE gets 404, which counts as done.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Online-only                   | Topic create, question publish (needs a live 409 check), topic delete and schedule edit. Each shows a clear "needs a connection" message when offline.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| API client                    | A **hand-written Codable** client.<br>• Response contracts: backend-generated fixtures (`shared/fixtures/api`).<br>• **(v2)** Request contracts: Swift-generated **request goldens** that pytest validates against the Pydantic models.<br>Both have drift checks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Due logic                     | A Swift port of `schedule.py` with explicit PEP 495 fold semantics, checked against Python-generated vectors in `shared/fixtures`. The server stays authoritative after each sync.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Reminders **(v2)**            | Server APNs, **best-effort and at-least-once**: send first, then mark as sent.<br>• Dedupe on the device uses a stable `apns-collapse-id` (`due-{topic_id}`) and `thread-id` (`topic-{topic_id}`).<br>• It also **removes delivered notifications whose `userInfo.quickr.topic_id` matches**. It doesn't rely on the collapse id becoming the notification identifier.<br>• The **badge is set on the device only**, by the NSE (from local due counts) and by the app. The payload has no `badge`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Notification actions **(v2)** | **At most 4 actions.** iOS shows 4 when expanded and 2 in the banner. Tapping the notification body opens the record screen, so no "Open" action is needed.<br>• **Choice topics:** 1–4 options become actions. For 5–6 options, the server's descriptor carries the 4 most-used; the full list is a tap away.<br>• **Numbers:** "Log {last}" (words, not a ✓ glyph, for VoiceOver) plus "Other value…", a text-input action.<br>• **Category id** `quickr.t.{topicId}.{descriptorHash}`. Categories are never changed in place, so an old delivered notification keeps the meaning it was sent with. Handlers validate against the descriptor in the notification's `userInfo`.<br>• **Registration:** categories are stored in a `notification_category` table. Each time, the full set is re-registered, keeping every category referenced by a delivered notification. The NSE inserts a row, then re-registers.                                                                                                                                                                                                                                    |
| Widgets **(v2)**              | A per-topic quick-log widget: chips, or "✓ last" for numbers (no stepper in v1). Also a due-list widget, Lock Screen accessories, and one `ControlWidgetButton` per topic. Using the Action button needs an iPhone 15 Pro or later (see H5).<br>• Writes are durably enqueued before `perform()` returns, then flushed best-effort. The widget shows "queued" until synced.<br>• Timelines reload only when due state or last values change, to stay within WidgetKit's reload budget.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| App Intents **(v2)**          | `TopicEntity`; `LogEntryIntent(topic, option or number)` for quick-log topics, with options from a `DynamicOptionsProvider`; `RepeatLastEntryIntent`; `OpenRecordIntent`; `AppShortcutsProvider` phrases.<br>**Deferred** until after v1: Spotlight `IndexedEntity`, `UndoableIntent`, and dependent option entities.<br>**(v3, Q3 research `research/04-siri.md`)** Adds `LogTopicIntent`: multi-question topics by voice, asking one question per Siri turn (`requestValue`/`requestChoice`), then an interactive confirmation snippet (`requestConfirmation(snippetIntent:)`, iOS 26) with chips and ± controls; on Apple Intelligence phones, a one-sentence answer parsed on-device with `DynamicGenerationSchema`, then follow-up turns only for missing fields. Adds `WhatsDueIntent`. Pulls `IndexedEntity`, `UndoableIntent` and dependent option entities into v1. No App Schema domain fits logging. iOS 27-only features (`SyncableEntity`, `.system.searchInApp`, …) sit behind `@available`. Widgets, Controls and the Action button keep the fully specified intents, because they can't prompt. |
| Repeat-last **(v2)**          | Re-logs the latest entry's answers if they still validate against the current version; otherwise it opens the record screen prefilled. With no previous entry, it opens the record screen. If the topic is archived, it shows a dialog.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| UI                            | `@Observable` screen models over GRDB `ValueObservation`, reconciled whenever the app becomes active. `NavigationStack` with a typed `Route`, plus a URL parser for the PWA's paths. A schema-driven form engine using `FocusState`. Swift Charts. System navigation, lists and sheets, with brand tokens and fonts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Headers                       | `X-QuickR-Channel: ios` (a new enum value). `source` is `ios`, `ios.widget`, `ios.notification` or `ios.siri`. `CF-Access-Client-Id` and `-Secret` come from the shared Keychain (`AfterFirstUnlock`) and are sent only when configured.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Server identity **(v2)**      | The local store is **partitioned per server**: one DB file per **server id** (a stable random id the server reports). An epoch change rebuilds that store's server layer in place, keeping its outbox. Changing the server URL switches stores and unregisters the old server's APNs registration. Queued data never goes to a different server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Dependencies                  | GRDB.<br>Tools: xcodegen (downloaded as a release binary in CI), swift-format, ffmpeg, rsvg-convert, fonttools (via uvx).<br>Backend: `httpx[http2]` and an explicit `pyjwt[crypto]`.<br>**(v2) Cut:** snapshot testing, Access JWT verification, chart screenshot comparison.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

## 3. Repository layout

```
ios/
  project.yml                 XcodeGen spec: targets, entitlements, Info.plist (incl. BGTaskSchedulerPermittedIdentifiers,
                              UIBackgroundModes fetch/remote-notification, NSAllowsLocalNetworking, NSLocalNetworkUsageDescription)
  QuickrKit/                  Package.swift (tools 6.2): QuickrCore, QuickrData, QuickrUI (+ Tests, ProcessHelper for multi-process tests)
  App/ Widgets/ NotificationService/ UITests/ TestPlans/ Resources/ scripts/
  Local.xcconfig              gitignored: DEVELOPMENT_TEAM, device id, dev server URL
shared/fixtures/              due-vectors.json, quicklog-vectors.json, api/*.json, requests/*.json (all generated + drift-checked)
docs/ios/                     REQUIREMENTS, PLAN, specs/, research/, reviews/, demo/mN/
.github/workflows/ios.yml     path-filtered macOS job
```

## 4. Workflow and branch management

- **Integration branch:** `feat/ios-app`, checked out in the worktree
  `../quickr-worktrees/ios`.
- **Milestones:** each is a branch `ios/mN-<name>` cut from `feat/ios-app`, and
  one PR back into it.
- **Work packages (WPs):** each runs in a sub-agent with its own worktree, on
  branch `ios/mN-<wp>` cut from the milestone branch.
  - Only independent work runs in parallel, at most 3 WPs at a time.
  - Shared contracts land first, in a contracts WP that I own: schemas,
    `openapi.json`, generated clients, fixtures, DB schema and specs. Other WPs
    never edit generated files.
  - I integrate WPs one at a time: review the diff, run the gates, then merge
    into the milestone branch with `--no-ff`.
- **(v2) Isolation:** every worktree gets a `.env` with its own
  `COMPOSE_PROJECT_NAME`, `QUICKR_DB_PORT`, `QUICKR_API_PORT`, `QUICKR_WEB_PORT`
  and `QUICKR_TEST_DATABASE_URL` (a test DB per worktree). Each also gets its
  own simulator device, made with `simctl clone`.
- **Before each milestone PR:**
  1. All gates are green (§8).
  2. A code-review sub-agent and `codex review` have both reviewed the diff, and
     every finding is fixed or answered.
  3. Demo media is recorded into `docs/ios/demo/mN/`.
  4. The validation checklist is ticked, with any skipped item explained.
  - **(v2)** Milestones without a UI (M0, M1) carry test reports and logs
    instead of media. This is a deliberate deviation from "screenshots, videos
    and GIFs".
- **Merging (see Q1):** by default, milestone PRs **don't wait for you**.
  - I merge once the gates and reviews pass, and you review asynchronously; your
    comments become fix-ups.
  - A PR **does wait for you** if it changes a decision in this plan, or if a
    spike comes back no-go.
- **Keeping current:** merge `main` into `feat/ios-app` at the start of each
  milestone.
- **Final step:** a PR from `feat/ios-app` into `main`. The backend changes ride
  along. If that PR gets too big, the PWA-safe backend changes can go to `main`
  first as separate PRs.
- **Backend during development (v2):**
  - Feature-branch backends run from their worktree with
    `docker compose up --build`. No published images are needed.
  - The simulator uses `http://localhost:<port>`.
  - The phone uses `http://<mac>.local:<port>` over the LAN, which needs
    `NSAllowsLocalNetworking` and the local-network prompt. You set the server
    URL in Settings.
  - The `.p8` key reaches the backend through a gitignored
    `docker-compose.override.yml`. It mounts the key read-only and sets the
    `QUICKR_APNS_*` variables.

## 5. Backend and PWA changes

All of these are additive. `make check` stays green, and every change
regenerates `openapi.json` and `frontend/src/client`.

| ID  | Change                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | When                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------- |
| B1  | The `answers` map uses `additionalProperties` (through `WithJsonSchema`, dropping the redundant int branch). Fix the type fallout in the frontend.                                                                                                                                                                                                                                                                                                                                                                                                                             | M0                                           |
| B2  | **Shared vectors.** A pytest generator writes `shared/fixtures/due-vectors.json` (DST grid: London, New York, Lord Howe, Kolkata, Kathmandu, UTC) and `quicklog-vectors.json`. Adds `make vectors` and a drift assertion.                                                                                                                                                                                                                                                                                                                                                      | M0                                           |
| B3  | **`ios` channel.** `ALTER TYPE … ADD VALUE` inside an `autocommit_block`. The downgrade remaps `ios` to `api` and rebuilds the type. Add an **explicit downgrade test**, because `alembic check` ignores enum values.                                                                                                                                                                                                                                                                                                                                                          | M0                                           |
| B4  | **Change feed (v2):**<br>• the `change_log` table, advisory-lock seq allocation and `deleted_ids`, written in the services so REST and MCP get them both, plus a backfill migration;<br>• the `GET /changes` endpoint;<br>• `feed_epoch`;<br>• 409 `entry_deleted` when a client replays a deleted id;<br>• replace the Python `datetime.now()` timestamps with server-side `now()` (`entries.py:187`, `topics.py:403`, and any others);<br>• `GZipMiddleware`;<br>• add the new tables to `TABLES` in `conftest.py`;<br>• **PWA:** the outbox treats `entry_deleted` as done. | M0                                           |
| B5  | **Contract fixtures.** `gen_api_fixtures.py` generates response fixtures. A pytest test validates the Swift request goldens. Both have drift checks.                                                                                                                                                                                                                                                                                                                                                                                                                           | M0 (responses), M1 (requests)                |
| B6  | **APNs:**<br>• an `apns_devices` table (token, environment, app version);<br>• endpoints to register, delete, and test this device;<br>• `apns_enabled` in `/push/config`;<br>• a `Sender` protocol shared with Web Push;<br>• `httpx[http2]` with an ES256 JWT cached for 50 min;<br>• an error map, and pruning on send failure (not only from the scheduler);<br>• concurrent sends, with the topic marks batched before commit.<br>The docs and tests state the semantics: **best-effort, at least once**.                                                                 | M3 (the code can land earlier, switched off) |
| B7  | **Actionable payload.** A channel-neutral `Notification` carrying `topic_id`, `version`, `due_since` and a `quick_log` descriptor. The descriptor comes from a Python port of `quickLogFor`, checked against the vectors, and holds the top 4 options and `last_value`.<br>On APNs: `category`, `thread-id`, `apns-collapse-id` and `mutable-content`. **No `badge`.**<br>Web Push gets only new optional fields.<br>Optional: a `content-available` push on data changes.                                                                                                     | M3                                           |
| B8  | **PWA parity:** Chromium notification `actions` for enum quick-log (up to `maxActions`, about 2). An action enqueues an outbox entry from the service worker. Show the `ios` channel badge.                                                                                                                                                                                                                                                                                                                                                                                    | M3                                           |
| B9  | **Hosting docs:** a Cloudflare Access service token, a policy for `/mcp`, and an AASA bypass if universal links are ever added.                                                                                                                                                                                                                                                                                                                                                                                                                                                | M7                                           |

## 6. Specs written before code (v2)

These are written in M0, while Xcode isn't available. They're reviewed in the M0
PR and become the reference the tests are built from.

- **`specs/sync-protocol.md`:** the feed contract, cursor, epoch and bootstrap;
  the two-layer store; the merge rules; resync; server partitioning; and reset.
  - A server row always lands in the server layer, and the outbox overlay
    applies on top of it.
  - A tombstone removes the row and **fails** any outbox items that depend on
    it, with "deleted elsewhere".
  - A topic tombstone also removes that topic's categories and widget configs.
  - Resync on an epoch mismatch keeps the outbox.
  - A local data reset warns about pending writes and offers to sync first.
- **`specs/outbox.md`:**
  - **Contents:** the kinds, the state machine, classification, per-entity
    ordering, the flush lock, coalescing, "delivery uncertain", undo, and
    handling of 404 and 409 `entry_deleted`.
  - **Test matrix:** about 40 cases, including:
    - the lock expiring and the old holder finishing late;
    - a lost response;
    - suspension;
    - a late POST arriving after a DELETE.
- **`specs/notifications.md`:**
  - **Payload contract:** the payload, category ids, the action-id scheme, the
    registration table, and the NSE flow.
  - **Badge:** set on the device only.
  - **Before first unlock:** the store is unreadable, so the NSE leaves the
    notification alone; it has no actions, and tapping it opens the app.
  - **Tokens:** re-register on every launch and every token change, and
    unregister when notification permission is turned off.
  - **Local fallback:** use the same identifiers, plus explicit rules for
    cancelling pending local notifications when a push arrives or an entry is
    logged. A local fallback can then be added later without a redesign.

## 6a. Binding protocol rules (v3, from Codex round 2)

The M0 specs must encode these rules, and the M0 and M1 tests must prove them. Each rule names the
Codex round-2 finding it answers ([review](reviews/plan-v2-codex.md)).

**Server: one write order (§2 feed)**

1. **One write order.** Every mutating service transaction (entries, topics, versions, deletes,
   archive) takes the feed advisory lock **as its first statement**, before any row or foreign-key
   lock.
   - The lock key differs from the scheduler's `0x716B7201`.
   - The scheduler never takes the feed lock, so the two can't deadlock.
   - Deadlocks and serialization failures are retried automatically up to 3 times.
   - Since every writer takes the same lock first, writes are serialized, and seq order equals
     commit order. For a single user the lock contention is negligible.
2. **Deletes reserve the id.**
   - `DELETE /entries/{id}` atomically inserts the id into `deleted_ids` even if the entry doesn't
     exist (or doesn't exist yet), and returns 204.
   - `create_entry` checks `deleted_ids` while holding the same lock. So a delayed POST that arrives
     after its undo-DELETE can never create the entry.
   - For a create, `entry_deleted` means "retire it": remove the optimistic overlay and never
     materialise the entry.
   - The PWA's `outboxEffects` rolls back on `entry_deleted`, in B4. Older cached PWA builds show
     it as a failed item the user can discard. This is acceptable and documented.
3. **Deleting a topic** tombstones its child entries and versions in the service: an
   `INSERT … SELECT` into `deleted_ids` runs before the foreign-key cascade, and the change_log
   gets a topic delete row.
   - Entry mutations do **not** log topic changes. Clients **must recompute** `entry_count`,
     `last_captured_at` and due state locally from entries.
   - The feed logs topic rows only when the topic's own fields change.
4. **Feed pages** are materialised in one REPEATABLE READ snapshot.
   - Within a page, an entity's latest seq wins.
   - An entity that has vanished is emitted as a deletion only if it is in `deleted_ids`. Otherwise
     it is skipped, because its own delete row follows later.
   - The `next` cursor is the highest seq in the page. `limit` is capped at 500.
5. **Restore detection.**
   - The server returns `head` (its highest seq). A client whose cursor is greater than `head`
     treats that as an epoch mismatch.
   - Restore and reset docs include `make rotate-epoch`.
6. **Stale writers.**
   - `entry` and `topic` rows carry a `revision` integer.
   - PATCH, archive and unarchive accept an optional `expected_revision`. A mismatch returns 409
     `stale_revision`. The client then refetches the entity and replays its own newer queued
     operations in order.
   - The PWA doesn't send `expected_revision`, so its behaviour is unchanged.

**Client: the store and notifications**

7. **Acknowledging a sent operation is atomic.** One GRDB transaction upserts the server row and
   removes the outbox item, so an operation can never show twice in the overlay.
8. **Notifications carry their origin.**
   - Every payload and every action identifier includes `server_id`.
   - An action handler only writes to the store that has that `server_id`. If that store no longer
     exists, the action is dropped and a local notification explains why.
   - Every outbox item belongs to its store file, so items never move between servers.
9. **Registering notification categories is serialised.**
   - Each process holds a GRDB IMMEDIATE write transaction on `notification_category` while it
     reads the whole table and calls `setNotificationCategories` with it.
   - The table is append-only. Rows are pruned only when older than 7 days and not referenced by
     any delivered notification.
   - Category ids hash the **complete ordered action descriptor**: labels, values, kinds and order.
   - Up to four actions is the _maximum_. Checkpoint D measures how many actually show, and the
     design must still work when only two show (the banner).

**Delivery, compatibility and coverage**

10. **Reminder delivery** is at-least-once per topic slot overall, and best-effort for each device.
    There is no per-device retry ledger, which is acceptable for a single user and documented.
11. **Future local fallback.**
    - Local notifications use the identifier `due-{topic_id}-{due_since}`.
    - When the NSE receives a push, it cancels any pending local request for the same topic and
      slot.
    - When a local notification fires and a delivered push for the same topic and slot exists, the
      handler removes the duplicate.
    - Logging an entry cancels pending and delivered notifications for that topic and slot.
    - All of this is specified now and built later.
12. **Coverage and minimum iOS.**
    - A test asserts that every `operationId` the Swift client uses has a response fixture, and
      every request it sends has a golden.
    - The CI Unit plan runs on an **iOS 26.x** simulator, the minimum we deploy to.

### Amendments from the M0 specs review (2026-10-17)

These amendments come from the Codex review of the specs ([review](reviews/m0-wp-specs-codex.md)).
They take precedence over the rules above where they conflict.

13. **Identity and epoch preconditions.**
    - Every response carries the `X-QuickR-Server-Id` and `X-QuickR-Epoch` headers.
    - A mutation may send `X-QuickR-Expect-Server-Id` and `X-QuickR-Expect-Epoch`. If either doesn't
      match, the server rejects it with 409 `server_mismatch` or `epoch_mismatch` **before
      executing**.
    - The iOS client always sends both, so a queued write can never run on the wrong server or
      generation.
    - Each request captures a local store generation. An outcome that comes back for an obsolete
      generation is discarded.
14. **Coordination.**
    - One coordinator owns both pulls and rebuilds, fenced by its lock token and generation, with a
      single global lock order.
    - Leases use boot-relative time plus a boot-session id, never wall-clock time.
    - A reset creates a fresh store file and bumps a registry generation, which other processes
      watch so they can reopen.
15. **Coalescing** applies only to adjacent, never-sent operations on the same entity, with no
    operation for the same topic in between. While an undoable delete is held, everything queued
    before it is kept.
16. **Notification categories (this amends rule 9).**
    - The category table is append-only, with no pruning in v1.
    - Registration takes the union of the table under the registry lock.
    - Delivered notifications are snapshotted outside SQLite.
    - Reconciliation (`getNotificationCategories` → re-register what's missing) runs on app
      activation and at NSE start.
    - Concurrent replacement is tested on the device at checkpoint D.
    - The NSE never flushes the outbox.
    - The badge comes only from the active store's derived due state.

## 7. Milestones

Effort is relative (S < M < L < XL). **Needs** lists the human steps (§9) that
must be done before the milestone can _finish_.

### M0: Backend foundations and specs · L · Needs: nothing

- **Work:**
  - B1–B4, plus the B5 response fixtures.
  - The three specs (§6).
  - `ios/project.yml`, the `Package.swift` manifest, `make ios-*` targets that
    fail fast without Xcode, and the `ios.yml` workflow. All of these are first
    compiled in M1.
  - `make check` stays Xcode-free.
- **Validation:**
  - Backend tests:
    - Feed ordering under concurrent transactions: in two sessions, the one that
      commits later always has the higher seq.
    - Pages that contain only deletions.
    - The backfill and the epoch.
    - Replaying a deleted id returns 409.
    - A delete made through MCP shows up in the feed.
    - The enum downgrade.
  - The drift checks for vectors and fixtures.
  - The PWA's `make check` stays green.
  - The specs get a `codex` review.
- **Demo:** test reports.

### M1: Core and data layer, plus proof of the riskiest platform parts · XL · Needs: H1, H2

- **QuickrCore:** models, validation (messages ported from `answerSchema.ts`),
  quick-log, and the due port. All vectors pass.
- **QuickrData:** the API client (fixtures and request goldens), the two-layer
  GRDB store, the sync engine, and the outbox, built to the spec's test matrix.
- **(v2) Multi-process tests.** They use file-backed databases and a macOS
  `ProcessHelper` run as a subprocess. They cover:
  - concurrent writers;
  - migrating while other connections are open;
  - a process killed while holding the flush lock;
  - the lock expiring and another process taking over.
- **(v2) Platform proof in the app skeleton:**
  - App Intents resolve from both the app and the widget extension.
  - A notification-action spike in the simulator, using local notifications:
    categories registered from the table, and an action handler that runs in the
    background with the app killed, writes, and flushes. Findings go in the PR.
- **Validation:**
  - `swift test` passes on the host. The UI test plan is still empty.
  - **(v2)** A **required** integration suite against the docker stack
    (`make ios-integration`), run here and in every milestone that touches sync.
    It covers:
    1. Bootstrap.
    2. Create offline, then flush.
    3. A web delete reaches the phone through a tombstone.
    4. Undo while a create is in flight.
    5. An epoch reset keeps the outbox.
  - CI (`ios.yml`) is green.
- **Demo:** test report, integration log, spike notes.

### D: Device checkpoint · S · Needs: H3, H4, H5 (+ H6 for push)

This runs on the first day a device is available. It is a **go/no-go gate**, not
a milestone.

- **Checks:**
  - Install the app with `devicectl`.
  - Measure when the NSE's category upsert takes effect.
  - Count the actions iOS shows.
  - Measure the action's background time budget.
  - Log from the Lock Screen while the store is protected until first unlock.
  - Check how widget buttons behave.
  - Check the Action button, if the phone has one.
- **Output:** a short findings PR. **If any check is no-go, the PR waits for
  you,** and I bring a proposal.

### M2a: Shell, design system and home · L · Needs: H2

- **Design system:**
  - Colour tokens for light and dark.
  - Static font instances, with a brand font helper that supports Dynamic Type.
  - Dot grid, chips, stepper, tiles, toast centre, sync pill.
  - App icon set and haptics.
- **Onboarding and Settings:** server URL (one store per server), the optional
  Cloudflare token, and notification permission with an explainer.
- **Home:** due-first, with search, filter, sort and the badge.
- **Quick-log tiles at PWA parity:** chips, a stepper with ✓, a dot showing the
  last value, the 1.6 s confirmation, and kept drafts.
- **Undo toasts.**
- **Validation:**
  - A UI test: quick-log a chip, then Undo.
  - Tile tap counts match the PWA table: single enum = 1, single number = 1 or
    2, undo = 1, offline = 1.
  - Screenshots in light and dark, and at Dynamic Type XL.
- **Demo:** GIFs and screenshots.

### M2b: Record screen, sync UX and background · L · Needs: H2

- **Record screen:**
  - A form engine covering every question type.
  - The focus rules.
  - "Same as last time", details, and "Log another".
  - When a topic has only one single-select question, tapping a chip saves
    immediately.
  - Fix mode.
- **Sync sheet:** retry, fix, discard.
- **Deep links** for the PWA's paths.
- **Flush triggers:** `scenePhase`, `NWPathMonitor`, the backoff timer, and
  `BGAppRefreshTask` (best-effort).
- **Validation:**
  - UI tests:
    - record a multi-question entry offline, then see it sync;
    - a deep link opens the record screen;
    - "Same as last time".
  - The full tap-count table is measured again, and every row is ≤ the PWA's.
  - Device install, once D has passed.
- **Demo:** GIFs.

### M3: Reminders and logging from notifications · L · Needs: H3–H6

- **Backend:** B6, B7 and B8.
- **iOS:**
  - APNs registration, with the environment read from
    `embedded.mobileprovision`.
  - The category table, and the NSE (upserts the category, sets the badge from
    local due counts).
  - The action handler: validates against `userInfo`, writes in one transaction,
    removes the matching delivered notifications, then flushes within its
    budget.
  - Number text input. If the input can't be parsed, a local notification says
    "tap to fix".
  - "Test this device".
- **Validation:**
  - Backend: MockTransport tests (JWT, headers, the error table, payloads ≤ 4
    KB); the scheduler fans out to web and APNs; partial-failure and
    commit-failure cases (at least once).
  - On the device, in the APNs sandbox:
    1. The reminder arrives.
    2. A chip action logs with the app killed.
    3. The server shows the entry with `channel=ios` and
       `source=ios.notification`.
    4. The badge updates.
    5. Publish a new version while a notification is still on screen. That
       notification's actions still log against the version they were sent with.
  - PWA: Chromium actions log entries.
- **Demo:** a device screen recording.

### M4: Widgets, Controls, Siri and Shortcuts · M · Needs: H3–H5

- **Work:** QuickrIntents (as in §2), the widgets, the controls, and the
  Shortcuts phrases.
- **Validation, on the device:**
  - A widget chip logs with the app killed and **no network**. The widget shows
    "queued", and the entry syncs on the next trigger.
  - The Action button runs Repeat-last (if the phone has one).
  - Siri: "Log water in quickR".
  - Multi-process soak: logging from the app, a widget and notification actions
    all at once surfaces no `SQLITE_BUSY` errors and no 0xDEAD10CC crashes.
- **Demo:** GIFs and a device recording.

### M5: History and entries · M · Needs: H2

- **Work:**
  - The entries list, read from the local store, with filters. Pending and
    failed entries are pinned at the top.
  - Editing an entry against its pinned version, applied optimistically through
    the outbox.
  - Delete with undo.
  - CSV export through the share sheet (online only).
  - Offline browsing of history.
- **Validation:**
  - A UI test: edit, delete, undo.
  - Integration:
    - an edit made on the web reaches the phone;
    - a web delete that arrives while an update is still pending drops the
      entry, and the update fails with a notice.
- **Demo:** GIFs.

### M6: Management parity · L · Needs: H2

- **Work:**
  - Overview and stats: Swift Charts, cached.
  - Topic creation.
  - Question builder (all types), with the compatibility report, publish, and
    conflict handling.
  - Versions.
  - Topic settings: details, schedule editor, archive with undo, delete with
    typed confirmation.
  - App settings: sync status, reset, about and licences.
- **Validation:**
  - Builder tests ported from `builder.test.ts`.
  - **(v2)** Chart-model unit tests assert bucket values and timezone bucketing
    from fixture stats.
  - A UI test: create a topic, log, publish v2, log again.
- **Demo:** GIFs.

### M7: Hardening, TestFlight and hosting · M · Needs: H7, H8

- **Work:**
  - `make ios-testflight`.
  - Hosting (B9), with an end-to-end test through Cloudflare.
  - Accessibility: VoiceOver, the accessibility text sizes, 44 pt tap targets.
  - Performance: cold start in under 1 s with 10k entries.
  - A test that upgrades from the v1 schema.
  - Docs.
  - The final PR into `main`.
- **Validation:**
  - TestFlight installs over the air.
  - APNs works in production.
  - The full regression checklist passes on the device.

**If enrollment is slow:** M5 and M6 need only Xcode, so they move ahead of M3
and M4. The order becomes M2b → M5 → M6 → M3 → M4.

## 8. Gates and CI

| Gate                   | Contents                                                                                                                                                                                                                                                                                                                                                                                                                                               | Where              |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------ |
| `make check`           | Today's checks, plus the drift checks for vectors, fixtures and request goldens. No Xcode needed.                                                                                                                                                                                                                                                                                                                                                      | Local and `ci.yml` |
| `make check-ios`       | `xcodegen generate`, `swift test`, `xcodebuild test` with the Unit and UI plans, a swift-format lint, and an Xcode version check                                                                                                                                                                                                                                                                                                                       | Local              |
| `make ios-integration` | The sync suite against this worktree's docker stack. **Required** for any milestone that touches sync.                                                                                                                                                                                                                                                                                                                                                 | Local              |
| `ios.yml` **(v2)**     | Checks out the repo and downloads the xcodegen binary.<br>• On push: `swift test` on the host, about 3 min.<br>• On a PR marked ready for review, or a manual dispatch: an `xcodebuild` build plus the Unit plan.<br>• Path filters, and in-progress runs are cancelled.<br>The repo is private, so macOS minutes count at 10× — the account is on **GitHub Pro** (3,000 min, so about 300 macOS min a month), and usage is checked at each milestone. | GitHub             |
| Device checklist       | Listed in each milestone's PR                                                                                                                                                                                                                                                                                                                                                                                                                          | Phone              |
| Reviews                | A code-review sub-agent plus `codex review`, for every milestone                                                                                                                                                                                                                                                                                                                                                                                       | Before the PR      |

**Definition of done:** the gates are green; every validation item and every row
of the **requirements matrix (§11)** for this milestone is ticked; demo media is
embedded; review findings are resolved; docs and specs are updated.

## 9. Who does what

### Your steps

| #      | Step                                                                                                                                                                                                            | Needed for | Effort  |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------- |
| **H1** | **Upgrade macOS to Tahoe 26.6 or later. Start now:** nothing in Swift compiles on this Mac until it's done.                                                                                                     | M1 onward  | ~1 h    |
| **H2** | **Install Xcode 27.x**, then run `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform iOS`                       | M1 onward  | ~1 h    |
| **H3** | **Enroll in the Apple Developer Program** (individual). **Start now**, because the review takes 0–2 days. Then send me the Team ID.                                                                             | D, M3, M4  | Minutes |
| H4     | Sign in to Xcode ▸ Settings ▸ Accounts                                                                                                                                                                          | D          | 2 min   |
| H5     | **Phone:** plug it in and tap Trust, turn on Developer Mode and reboot, and optionally turn on "Connect via network". **Tell me the model and iOS version**; the Action button needs an iPhone 15 Pro or later. | D          | 10 min  |
| H6     | **APNs key:** in Developer ▸ Keys, create a key with APNs for Sandbox & Production. Download the `.p8`; it can only be downloaded once. Keep it outside the repo and send me the Key ID.                        | M3         | 5 min   |
| H7     | **App Store Connect:** create the app record for `com.bahumia.quickr` and a Team API key (Admin role). Keep the `.p8` on the Mac and fill in `ios/testflight.env`; see ios/README.md, TestFlight.               | M7         | 15 min  |
| H8     | **Cloudflare:** the tunnel, an Access app, a service token for the app, and a policy for `/mcp`                                                                                                                 | M7         | ~1 h    |
| H9     | Review milestone PRs asynchronously (see Q1), and answer the open questions in §10                                                                                                                              | Ongoing    | —       |

### My work

Everything else:

- all code (backend, PWA and iOS), tests, specs, CI and scripts;
- builds, simulator and device installs, and test runs;
- demo media;
- orchestrating sub-agents, integrating their work, and opening PRs;
- the sub-agent and Codex reviews, and the fixes they lead to.

### What can happen when

| When           | What can proceed                              |
| -------------- | --------------------------------------------- |
| Now (no Xcode) | M0: backend and specs                         |
| After H1 + H2  | M1, M2a, M2b, M5 and M6, all on the simulator |
| After H3–H5    | Checkpoint D, device installs, M4             |
| After H6       | M3                                            |
| After H7 + H8  | M7                                            |

## 10. Open questions

All four were answered by the user on 2026-10-17:

- **Q1. Merge gating: decided.** Milestone PRs merge once their gates and reviews
  pass, and the user reviews afterwards.
- **Q2. Lock-screen logging: decided.** No Face ID, provided the experience is
  clean. Checkpoint D verifies it, and if it turns out messy we raise it rather
  than quietly adding authentication.
- **Q3. Siri: decided, with a follow-up.** Opening the record screen or using
  Repeat-last is acceptable for multi-question topics, **but** the design must use
  the newest Siri / Apple Intelligence capabilities available on iOS 26/27.
  Research is in `research/04-siri.md` and feeds the INTENTS WP.
- **Q4. Topics with 5–6 options: decided.** The 3 most-used options plus a 4th
  "More…" action that opens the app, with the truncation stated in the
  notification body (`specs/notifications.md`).

## 11. Requirements matrix

| Requirement (REQUIREMENTS.md)                                                               | Delivered in       | Proven by                                                                           |
| ------------------------------------------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------- |
| Native SwiftUI, iOS 26+, iPhone only                                                        | M1–M2              | Deployment target 26.0; the CI build on the 26.x SDK                                |
| Full parity: home, tiles and record                                                         | M2a, M2b           | UI tests and the tap-count table                                                    |
| Full parity: entries, edit, delete with undo, CSV                                           | M5                 | UI test and integration test                                                        |
| Full parity: topic create, builder, versions, schedule, archive and delete, stats, settings | M6                 | Builder and chart-model tests, plus a UI test                                       |
| Offline-first: instant logging, later sync, offline history                                 | M1, M2b, M5        | The integration suite and the offline UI test                                       |
| Server APNs reminders                                                                       | M3                 | Device sandbox checklist                                                            |
| A future local fallback stays possible                                                      | §6 spec, M3        | The spec's identifier and cancel rules, reviewed                                    |
| Log from a notification                                                                     | M3                 | Device checklist, with the app killed                                               |
| Widgets on the Home and Lock Screens, interactive                                           | M4                 | Device checklist, with the app killed and offline                                   |
| Siri, Shortcuts, Action button                                                              | M4                 | Device checklist (Action button only on a 15 Pro or later)                          |
| Native look with the brand                                                                  | M2a                | Light and dark screenshots; design-system components                                |
| Bundle IDs `com.bahumia.quickr.*`, App Group                                                | M0                 | `project.yml`                                                                       |
| Keep the PWA working, with parity where possible                                            | Every milestone    | `make check`; B8's Chromium actions                                                 |
| Cloudflare service-token headers, services stay open                                        | M2a (settings), M7 | End-to-end test through Cloudflare                                                  |
| Monorepo, `ios/`                                                                            | M0                 | The repository layout                                                               |
| Worktrees; a PR per milestone with demos; a final PR                                        | All                | The §4 process. M0 and M1 carry test reports instead of media (a stated deviation). |
| Local gate plus CI build                                                                    | M0–M1              | `make check-ios`, `ios.yml`                                                         |

**Infeasible or limited, stated explicitly:**

1. Interactive widgets need the phone to be unlocked. On the Lock Screen,
   logging goes through the notification actions instead.
2. The Action button exists only on the iPhone 15 Pro and later.
3. A notification can show at most 4 actions, so a topic with 5–6 options shows
   its 3 most-used plus "More…", and says so in the body.
4. Widgets have no number stepper in v1. A number topic gets "✓ last" only.
5. ~~Siri can't fill in a multi-question form field by field.~~ **Superseded by the Q3 research:** `LogTopicIntent` asks field by field and confirms in an interactive snippet. Free text is voice-only in the card. Widgets, Controls and the Action button still can't prompt, so they use fully specified intents.
6. PWA parity is limited by the platform:
   - iPhone Safari's web push has no actions, and Chromium allows about 2.
   - So on the iPhone, one-tap logging from a notification exists only in the
     native app.
7. A notification that arrives before the first unlock after a reboot has no
   actions.

## 12. Review resolutions (v1 → v2)

| Finding                                                                                                      | Resolution                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Codex B1:** the cursor can lose rows                                                                       | A commit-ordered `change_log` whose seq is allocated under an advisory lock, with one ordering for both changes and deletions (§2). Concurrency tests in M0.                                                                                        |
| **Codex B2:** undo relies on leases                                                                          | Permanent `deleted_ids` plus 409 `entry_deleted` make stale sends harmless. A create whose delivery is uncertain is never discarded (§2, §6).                                                                                                       |
| **Codex B3:** wipe-and-repull loses offline work                                                             | A two-layer store. Resync on an epoch mismatch rebuilds only the server layer (§2).                                                                                                                                                                 |
| **Codex M4 / Fable M4:** zombie entries, topic tombstones                                                    | Merge and failure rules in `sync-protocol.md`, covered by M5's integration tests                                                                                                                                                                    |
| **Codex M5:** a category's meaning drifts across versions                                                    | Categories `quickr.t.{id}.{hash}` are never changed in place, actions are validated against `userInfo`, and a registration table tracks them (§2)                                                                                                   |
| **Codex M6:** the fallback drops a requirement, and the spike comes too late                                 | A simulator spike in M1 and checkpoint D on day one. A no-go waits for you.                                                                                                                                                                         |
| **Codex M7:** fallback dedupe is unproven                                                                    | Explicit cancel rules in `notifications.md`, with no reliance on the collapse id                                                                                                                                                                    |
| **Codex M8:** GRDB multi-process access is untested                                                          | File-backed subprocess tests in M1 and a soak in M4. The JSONL fallback is dropped.                                                                                                                                                                 |
| **Codex M9:** widget delivery                                                                                | Durable enqueue, a "queued" state, flushes from the NSE and the action handler, and a test with the app killed and offline                                                                                                                          |
| **Codex M10:** "exactly once"                                                                                | Replaced by best-effort, at-least-once, with failure tests                                                                                                                                                                                          |
| **Codex M11:** backend deployment during development                                                         | Docker stacks per worktree, LAN access from the phone, and the `.p8` via a compose override (§4)                                                                                                                                                    |
| **Codex M12:** validation doesn't prove parity                                                               | The requirements matrix, request goldens, chart-model tests, and the required integration suite                                                                                                                                                     |
| **Codex M13 / Fable:** workflow isolation, and media for non-UI milestones                                   | Ports and databases per worktree, contract ownership, and the stated deviation (§4)                                                                                                                                                                 |
| **Codex "missing":** server changes, keychain while locked, repeat-last, token rotation, topic paging, reset | Store partitioning, `AfterFirstUnlock`, defined repeat-last rules, the notifications spec, the feed (which replaces topic paging), and the reset rules                                                                                              |
| **Fable B1:** the Command Line Tools can't build any Swift                                                   | Swift work starts at M1, after H1 and H2. M0 is backend work and specs. H1 and H2 start now.                                                                                                                                                        |
| **Fable B2:** at most 4 actions                                                                              | Designed for 4 (§2)                                                                                                                                                                                                                                 |
| **Fable B3:** the outbox isn't a port                                                                        | Labelled a new design, with its own spec and test matrix. M1 is sized XL.                                                                                                                                                                           |
| **Fable M1:** Xcode pinning                                                                                  | An explicit toolchain rule. CI uses Xcode 26.6, or `xcode-27` once that's generally available.                                                                                                                                                      |
| **Fable M2:** where `AppShortcutsProvider` lives                                                             | In the app target, proven in M1                                                                                                                                                                                                                     |
| **Fable M3:** the Action button needs specific hardware                                                      | The phone model is asked in H5, and the limit is stated                                                                                                                                                                                             |
| **Fable M5:** value arrives late and M2 is too big                                                           | Reordered so reminders and widgets come before history and management; M2 split; checkpoint D added                                                                                                                                                 |
| **Fable M6:** CI budget                                                                                      | Compile locally; `swift test` on push; the full build only on a ready PR or a dispatch; the xcodegen binary instead of brew                                                                                                                         |
| **Fable M7:** badge                                                                                          | Set on the device only; the payload has no badge                                                                                                                                                                                                    |
| **Fable minors**                                                                                             | Environment read from `embedded.mobileprovision`; the widget reload budget; plist keys; dev networking; the PWA parity limits listed; `conftest` TABLES                                                                                             |
| **Fable simplifications**                                                                                    | **Taken:** 3 targets, permanent tombstones (no retention), a trimmed M4, a single flush lock, cutting snapshot tests and JWT verification. **Not taken:** dropping one of the two drift mechanisms, because Codex asked for more contract coverage. |

### v2 → v3 (Codex round 2)

| Round-2 finding                                                                    | Resolution                                               |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------- |
| A DELETE must reserve an id it hasn't seen; creates and deletes must be serialised | §6a rules 1–2                                            |
| Lock ordering and deadlocks with the scheduler lock                                | §6a rule 1                                               |
| Topic cascades and derived topic fields                                            | §6a rule 3                                               |
| Materialising pages                                                                | §6a rule 4                                               |
| **New blocker:** notification provenance across servers                            | §6a rule 8, plus the store keyed by `server_id` (§2)     |
| Category registration race, and hashing the full descriptor                        | §6a rule 9                                               |
| Expired senders overwriting newer changes                                          | §6a rule 6                                               |
| Double overlays on acknowledgement                                                 | §6a rule 7                                               |
| A restore doesn't rotate the epoch                                                 | §6a rule 5                                               |
| Partial scheduler delivery                                                         | §6a rule 10: best-effort per device, a stated limitation |
| Rules for deduplicating the local fallback                                         | §6a rule 11                                              |
| Minimum-iOS testing and endpoint coverage                                          | §6a rule 12                                              |
| GitHub plan tier                                                                   | Confirmed: Pro (§8)                                      |
