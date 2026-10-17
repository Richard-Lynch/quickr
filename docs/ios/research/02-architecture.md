# Research 02: iOS app architecture (2026-10-17)

Inputs: [REQUIREMENTS.md](../REQUIREMENTS.md), [00-scouting.md](00-scouting.md),
`frontend/docs/pwa.md`, `frontend/src/lib/outbox/*`,
`frontend/src/lib/quickLog.ts`, `backend/app/services/schedule.py` and
`openapi.json`. Sources are numbered at the end. iOS 27 shipped in September
2026 [1]. We target iOS 26 as the minimum and use no newer API.

## Recommendations

One pick per question; the rejected alternative follows "not".

1. **Modules:** XcodeGen; app + widget extension + NSE; one SPM package
   `QuickrKit` (six targets) that also holds the App Intents. Not one fat
   target.
2. **Persistence:** GRDB 7 `DatabasePool` (WAL) in the App Group; only the app
   migrates. Not SwiftData (multi-process caveats, iOS 26.x regressions).
3. **Sync:** full local mirror, durable outbox ported 1:1 from the PWA, pull via
   a new `GET /api/v1/sync` feed with tombstones. Not re-paging every topic.
4. **API client:** hand-written Codable client with backend-generated fixtures.
   Not swift-openapi-generator.
5. **Due logic:** Swift port of `schedule.py` with explicit fold/gap handling,
   checked against Python-generated vectors. Not bare `Calendar` policies.
6. **Notifications:** one category per topic (options, or "✓ last" + text
   input), upserted by the NSE from the payload; `apns-collapse-id:
   due-{topic id}`. Not a content extension.
7. **Widgets:** per-topic `Button(intent:)` quick-log, local due times as
   timeline entries, plus Controls. Not network-backed widgets.
8. **App Intents:** `TopicEntity`; log, repeat-last and open-record intents.
   Not dynamic per-question parameters.
9. **UI:** `@Observable` models over GRDB observation, typed `Route` enum, form
   engine with `@FocusState`. Not TCA.
10. **Tests:** Swift Testing over shared fixtures + three XCUITest flows. Not
    XCTest everywhere.

**Backend changes** (all PWA-compatible): **B1** `GET /api/v1/sync` change feed
+ `deletions` table; **B2** `ios` channel value; **B3** APNs device registration
+ sender with the §6 payload; **B4** due/quick-log/API fixture generators with
CI drift checks; **B5** (optional) `updated_since` on `GET /topics`.

**Top risks:** see the end of the document.

## 1. Module layout

```
ios/project.yml                 XcodeGen; no hand-merged .pbxproj
ios/App/                        QuickR                       com.bahumia.quickr
ios/Widgets/                    QuickRWidgets                com.bahumia.quickr.widgets   (widgets + controls)
ios/NotificationService/        QuickRNotificationService    com.bahumia.quickr.notification-service
ios/QuickrKit/ (iOS 26, macOS 15)
  QuickrCore     models, AnswerValue, validation + messages, quick-log rules, due logic (no deps)
  QuickrAPI      HTTP client, DTOs, header decorator, outcome classification
  QuickrStore    GRDB schema, migrator, repositories, observation, Darwin-notify
  QuickrSync     outbox, sync engine, flush coordinator, NWPathMonitor
  QuickrIntents  AppEntities, queries, intents, AppIntentsPackage          [iOS only]
  QuickrUI       colour/font tokens, chips, stepper, tiles, toasts, charts  [iOS only]
ios/UITests/
```

- **Platform-free targets:** Core, API, Store and Sync import no UIKit,
  WidgetKit or AppIntents, so `swift test` runs on macOS CI without a simulator
  (possibly even on Command Line Tools alone; unverified).
- **App Intents in a package** are supported from Xcode 26 via
  `AppIntentsPackage` [8]. It is only needed when an `AppEntity` crosses a
  package boundary, and redundant declarations can duplicate metadata so intents
  fail to resolve [9]. We have `TopicEntity`, so the app and the widget each
  declare exactly one package including `QuickrIntents`, with a test that
  intents resolve from both. A known localization bug for packaged intents [9]
  doesn't matter while the app is English-only.
- **Shared:** App Group `group.com.bahumia.quickr` (database, defaults suite
  with base URL and settings); keychain group
  `$(AppIdentifierPrefix)com.bahumia.quickr.shared` (Cloudflare secrets); fonts
  and colours in `QuickrUI` (`Bundle.module`, fonts registered per process with
  `CTFontManagerRegisterFontsForURL`).
- **Rejected: Tuist.** Four targets don't need more than one YAML file.

## 2. Persistence: GRDB 7

**Setup.** GRDB 7.11.x is current [5]. One `DatabasePool` at
`<AppGroup>/Library/quickr.sqlite`, using GRDB's multi-process recipe [4]: WAL
with `SQLITE_FCNTL_PERSIST_WAL`, `busyMode = .timeout(5)`,
`observesSuspensionNotifications` plus `Database.suspendNotification` on
backgrounding (avoids the 0xDEAD10CC lock-while-suspended kill), and creation
coordinated with `NSFileCoordinator`.

**Cross-process changes.** GRDB observation can't see other processes' writes
[4], so every writer posts the Darwin notification
`com.bahumia.quickr.db-changed` after commit; the app re-runs observations and
widgets reload.

**File protection:** `.completeUntilFirstUserAuthentication` on the database
directory. Notification actions run while locked, when `.complete` files are
unreadable [13].

**Migrations.** Append-only `DatabaseMigrator`; only the app calls `migrate`
(Apple's "one process owns the schema" rule [1]). If an extension finds
`hasCompletedMigrations` false after an update, it degrades: the widget shows
"Open quickR", an intent asks the user to open the app, and a notification
action appends to `pending-logs.jsonl` in the App Group for the app to ingest.

**Schema v1.**

- `topic`: the server fields, plus `schedule_json` and `server_due_json`.
- `topic_version(topic_id, version, questions_json)`: immutable.
- `entry`: the server fields, plus `answers_json` and
  `local_state ∈ {synced, pending, failed, deleting}`, with an index on
  `(topic_id, captured_at DESC)`.
- `outbox(id, kind, entity_id, payload_json, created_at, updated_at, attempts, status, next_attempt_at, last_error_json, lease_owner, lease_until)`.
- `sync_meta`: the opaque cursor.
- `ui_draft`: tile and widget stepper values.

**Tests** run against an in-memory `DatabaseQueue` using the same migrator.

**Rejected: SwiftData.**

- Apple's guidance is that in app-plus-widget or app-plus-intents setups, one
  process must own migrations and the extensions must not carry the migration
  plan [1]. Developers report data loss when a widget builds its own container
  [2]. Our notification actions and widget intents can easily run before the
  first app launch after an update.
- There are recent regressions: an iOS 26.1 crash, `@ModelActor` running on the
  main queue, and views that don't refresh [3].
- It gives no control over SQL or indexes.

**Also rejected: Core Data.** It is first-party, but that is its only advantage,
and it needs more boilerplate.

**Optional later: SQLiteData 1.0** [6]. It adds SwiftData-like `@FetchAll` on
top of GRDB, and is only worth it if the observation helpers become tedious.

## 3. Sync engine

**Local data: mirror everything.**

- The mirror covers all topics including archived ones, all versions and all
  entries. A personal app produces about 10–20k entries a year, which is a few
  MB.
- That makes offline history, local due computation and "same as last time"
  trivial.
- The first sync backfills in pages of 500.
- Stats and series stay server-computed, with the last response cached and
  marked "last updated" when offline. This avoids duplicating the bucketing and
  histogram logic.

**Pull (B1).** Today there is no `updated_since`, and entry deletes are hard
deletes (`services/entries.py:202`). An efficient pull that also sees deletions
is impossible without a new endpoint:

```
GET /api/v1/sync?cursor=<opaque>&limit=500
→ { topics:[TopicDetail], versions:[TopicVersionOut], entries:[EntryOut],
    deleted:{topics:[uuid], entries:[uuid]}, cursor:"<opaque>", has_more:bool }
```

- **Tombstones.** The server writes `deletions(kind, id, topic_id, deleted_at)`
  in the same transaction as the delete.
- **The cursor.**
  - It encodes `(updated_at, id)`.
  - Each read overlaps the previous one by about 2 minutes, to catch
    transactions that commit out of order. Upserts are idempotent, so the
    overlap is harmless.
  - It stays an opaque string. A Swift `Date` can't round-trip Python's
    microseconds.
- **A check to make first:** every topic mutation must bump `topics.updated_at`.
- **Fallback if B1 slips.** Use B5 plus per-topic entry paging for topics whose
  `updated_at` or `last_captured_at` changed. Deletions made elsewhere then need
  a periodic full reconcile.
- **Merge rule.** Server rows overwrite local rows, unless the entity has an
  outbox item (pending, failed or leased). In that case the local row wins, so a
  pull never resurrects a queued delete or reverts an unsent edit.

**Push: the outbox.** This is a port of `frontend/src/lib/outbox` onto the
`outbox` table.

| Kind                               | Request                                                              |
| ---------------------------------- | -------------------------------------------------------------------- |
| `entry.create`                     | `POST /topics/{topic id}/entries`, where `id` = outbox id = entry id |
| `entry.update`                     | `PATCH`, sending only the changed keys                               |
| `entry.delete`                     | `DELETE`; a 404 counts as done                                       |
| `topic.archive`, `topic.unarchive` | The archive/unarchive endpoints                                      |

- **Online only:** topic create, publishing questions (which needs
  `base_version` and an immediate 409 path), topic delete and schedule edits.
- **Classification and backoff** are identical to the PWA: 2xx with JSON → ok;
  network error, 15 s timeout, 5xx, 401/403/408/425/429, any 3xx (redirects are
  never followed) or a non-JSON 200 → retry; any other 4xx → `failed`. Backoff
  `2s·2^(n-1)` ±20 %, capped at 5 min; a network error stops the pass.
- **Coalescing at enqueue:**
  - An update to an unsent create is folded into the create.
  - Two updates to the same entity merge.
  - **A delete of an unsent create removes the create and sends nothing.**
- **Undo.** The rule is that a create is never replayed after an undo-delete,
  because the server recreates deleted ids.
  - Undoing a log:
    - If the create is still queued, discard it.
    - If it is in flight, enqueue a delete that runs after it. Items for one
      entity run in `created_at` order.
    - If it was already sent, enqueue a delete.
  - Deleting with undo (from the entries list):
    - The row is marked `deleting` and hidden.
    - The delete is enqueued only after the 6 s toast ends or the app moves to
      the background.
    - Undo clears the mark.
- **Cross-process exclusion.** A flush leases items (`lease_owner`,
  `lease_until` = now + 30 s) inside an `IMMEDIATE` transaction. This replaces
  the PWA's Web Lock. The bookkeeping after a send is compare-and-set on
  `updated_at`, so an edit or discard made during a send wins.
- **Conflicts: last write wins**, as today. Later, optionally, send
  `If-Unmodified-Since` and surface a 412 as a failed item to fix.
- **Flush triggers:** enqueue (`sendNow`, waiting a few seconds before
  reporting "queued", like `recordEntry`); `scenePhase` active; `NWPathMonitor`
  `.satisfied`; a foreground timer for the next backoff deadline; after a
  notification action or widget intent (5–8 s budget); `BGAppRefreshTask`
  `com.bahumia.quickr.refresh` [18] (pull, flush, reload widgets, re-arm for the
  next due time); later, optionally, a silent push on web-side changes. Every
  flush runs inside `beginBackgroundTask`.
- **Rejected: background `URLSession` in v1.** A background upload is delivered
  outside our process, possibly after the user has pressed Undo. It would then
  recreate the deleted entry. Making it safe means cancelling system tasks
  before every delete, and the requests are tiny anyway.

## 4. API client

**Recommendation: a hand-written `APIClient` actor.**

- **Transport.** An ephemeral `URLSession` with no cookie storage, so no stray
  `CF_Authorization` cookie. A delegate returns `nil` from
  `willPerformHTTPRedirection`, which matches the PWA's `redirect: 'manual'`.
- **Answer values.**
  - `AnswerValue` is an enum: `int`, `double`, `string`, `strings` and `null`.
    It is decoded according to the question type, so the overlapping `anyOf`
    branches in the spec never matter.
  - `EntryOut.answers` arrives as a list, and `EntryCreate.answers` is encoded
    as a map.
- **Dates.**
  - Decoding accepts `Z` or `+00:00` and 0–6 fractional digits, using
    `Date.ISO8601FormatStyle` with a fallback.
  - `captured_at` is always encoded with an explicit offset.
- **Errors.** The `Problem` body is decoded, and its `errors[].loc` entries map
  to form fields.
- **Contract (B4).** `backend/scripts/gen_api_fixtures.py` dumps real responses
  from the test database. Swift tests decode every fixture, and CI fails when
  the fixtures drift.

**Rejected: swift-openapi-generator 1.12.x** [7b].

- The generator supports `anyOf`, `oneOf` with a discriminator, and
  `additionalProperties`. It does **not** support `patternProperties` or `const`
  [7].
- To use it, the spec would need five changes:
  1. Express `answers` with `additionalProperties`.
  2. Set FastAPI `separate_input_output_schemas=False`, so there is no
     `-Input`/`-Output` split.
  3. Write discriminators without `const`.
  4. Add a custom `DateTranscoder` for fractional seconds.
  5. Accept awkward wrappers for the overlapping int/number `anyOf`.
- The store needs its own domain models anyway, so the generated types would
  only sit behind a mapping layer.

**Headers.** A `RequestDecorator` used in every process adds:

- `X-QuickR-Channel: ios`. For B2, run
  `ALTER TYPE entry_channel ADD VALUE 'ios'`. `source` then distinguishes the
  iOS surfaces: `ios`, `ios.widget`, `ios.notification` and `ios.siri`.
- `CF-Access-Client-Id` and `CF-Access-Client-Secret` [16], read from the shared
  keychain group [19] with `kSecAttrAccessibleAfterFirstUnlock`, so they work in
  the background while the phone is locked. They are left unset for the local
  docker stack.

For local development over `http://<mac>:8100`, the app needs
`NSAllowsLocalNetworking` and a `NSLocalNetworkUsageDescription`.

## 5. Due logic on device

**The port.** Move `schedule.py` into `QuickrCore/Due`: `dailySlots`,
`satisfied`, `daily`, `interval`, `computeDue` and `dueMessage`, keeping the
constants (2 h early window, 16 days of lookback, 9 days of lookahead). The PWA
only patches due state with `dueAfterLogging`, so this port is new. It gives us:

- exact optimistic due clearing;
- widget timelines that work offline;
- the future local-notification fallback.

The server's `due` stays authoritative after each sync. Between syncs, the app
recomputes due from the later of the server's `last_captured_at` and the newest
local entry.

**DST handling.** Python's `fold=0` (PEP 495 [17]) uses the offset in effect
_before_ a transition, both for ambiguous times and for times in a gap. We
reproduce that explicitly instead of trusting `Calendar` policies:

```
W = wall time read as UTC; oB = offset(W − 1 day); oA = offset(W + 1 day)
valid = [W − oB, W − oA].filter { offset(at: $0) == offset used to make it }
two valid → the earlier one (first occurrence) · one → it · none (gap) → W − oB (after the gap)
```

**Shared vectors (B4).**

- `backend/scripts/gen_due_vectors.py` calls the real `compute_due`,
  `daily_slots` and `due_message`. It writes `due_vectors.json`, where each
  vector holds the schedule, now, last entry, since, archived flag, the expected
  result and the slots.
- The cases cover:
  - the New York gap on 2026-03-08 at 02:30;
  - the New York fold on 2026-11-01 at 01:30;
  - London;
  - `Australia/Lord_Howe`, which has a 30-minute DST shift;
  - weekly-only schedules;
  - the edge of the early window;
  - the `since` cut-off;
  - an interval schedule with no entries yet;
  - an archived topic;
  - each branch of `due_message`.
- A parameterised Swift test runs every vector. CI regenerates the file and
  fails on any diff.
- `quickLogFor`/`initialNumber` get the same treatment, with vectors generated
  from the TypeScript tests.

**Residual risk.** iOS and Python can ship different tzdata versions, so the
vectors should only use stable zones.

## 6. Notifications

**Registration (B3).** The app calls `registerForRemoteNotifications` and sends
the token to `POST /api/v1/push/apns-devices {token, environment, bundle_id}`.
The scheduler's `send_to_all` also sends to APNs, over HTTP/2 with a `.p8` JWT.
A 410 response removes the token.

**Categories.** Each quick-log-eligible topic gets its own category,
`qr.t.<topicId>.<hash>`. Two things keep the set current:

- **The app** registers the full set after every sync.
  `setNotificationCategories` replaces everything, so it always sends all of
  them.
- **The NSE** reads `quick_log` from the payload, upserts that topic's category
  (get, merge, set), and sets `categoryIdentifier`. This covers topics created
  on the web and the "✓ last value" title, which changes after every log.
  Registering a category inside the NSE just before display is common practice,
  but Apple doesn't document it as guaranteed.
  - **Spike this on a device early.**
  - Fallback: the generic `qr.due` category, with "Open" only.

**Actions.**

| Topic type     | Actions                                                                           |
| -------------- | --------------------------------------------------------------------------------- |
| Single enum    | One action per active option (no `.foreground`)                                   |
| Number         | "✓ 7.5 h" (the last value), plus a `UNTextInputNotificationAction` "Other value…" |
| Every category | "Open" (`.foreground`), which opens the record screen                             |

- **Option count.** Apple only says that with minimal space the first two
  actions show [14]. Cap the options at the quick-log limit of 6, and check the
  expanded layout on a device.
- **Typed numbers.** The keyboard type of a text-input action can't be set.
  Typed text is validated with the question's own rules. When it is invalid, the
  app posts a local "Couldn't log 'abc' — tap to fix" notification.
- **Locked phone.** Log actions have no `.authenticationRequired`, so logging
  from the lock screen takes 2 taps. The data is low sensitivity and the
  database is protected until first unlock. The user can flip this choice.
- **Identifiers.** Action identifiers must be unique across all categories [13].
  They follow the pattern `log|<topicId>|<version>|<key>|opt|<value>` or
  `…|num|last`. The handler re-validates against the stored version.
- **Rejected: a content extension with SwiftUI chips**
  (`UNNotificationExtensionUserInteractionEnabled` [15]). It would be a third
  process that also needs the database and a flush, and it still needs a
  category. Revisit it only if an in-notification stepper becomes a must.

**Handler.** The system launches the app in the background and calls
`didReceive` [13]. On a lean boot path (no UI): open the database, validate,
insert the entry and its `entry.create` row in one transaction
(`source = ios.notification`), recompute due, `setBadgeCount`, remove the
delivered `due-<topicId>`, post the Darwin notification, reload widgets, flush
within 5–8 s inside `beginBackgroundTask`, then call the completion handler. The
time limit is undocumented (about 30 s is commonly cited [21]), so durability
never depends on the network.

**Payload (B3).** The Web Push payload is unchanged.

```json
{
  "aps": {
    "alert": { "title": "Sleep", "body": "Time to log" },
    "category": "qr.due",
    "thread-id": "topic-<id>",
    "badge": 3,
    "sound": "default",
    "mutable-content": 1
  },
  "quickr": {
    "v": 1,
    "kind": "due",
    "topic_id": "<uuid>",
    "topic_slug": "sleep",
    "version": 4,
    "due_since": "…",
    "url": "/t/sleep/record",
    "quick_log": {
      "kind": "chips",
      "key": "quality",
      "options": [{ "value": "good", "label": "Good" }]
    }
    /* | {"kind":"number","key":"hours","last":7.5,"unit":"h","min":0,"max":24,"decimals":1} | null */
  }
}
```

- The headers are `apns-push-type: alert`, `apns-priority: 10` and
  **`apns-collapse-id: due-<topic id>`**. The collapse ID becomes the delivered
  request's identifier [20].
- A future local notification scheduled with the identifier `due-<topic id>`
  therefore replaces a server push for the same topic, and is replaced by one,
  as the web `tag` does today.
- The server computes `quick_log` with its own port of `quickLogFor`, checked
  against the shared vectors.

## 7. Widgets

**Quick-log widget (small and medium).**

- It is an `AppIntentConfiguration` with a `TopicEntity` parameter.
- It shows:
  - the topic and its due state;
  - chips as `Button(intent: LogOptionIntent(topic, value))`;
  - for number topics, `−` and `+` buttons that update `ui_draft`, plus a
    `✓ value` button.
- Widgets only allow `Button` and `Toggle`, so there is no text input [10].
- `perform()` runs **in the widget extension's process** by default. When it
  returns, the timeline always reloads, so the write must finish before then
  [10]. The intent writes the entry and outbox row, then tries a short flush.

**Lock Screen accessories** (circular and rectangular) show due or next-due
state, plus "✓ last".

- Their buttons are **inert until the phone is unlocked** [10]. The notification
  is the real lock-screen logging path.

**Due-list widget** (medium and large) shows "Due now" and "Coming up", with
deep links.

**Timeline.**

- One entry for now, plus one for every local `next_due_at` in the next 24 h,
  using the §5 logic. The policy is `.atEnd`.
- `reloadAllTimelines()` runs after every write, sync and background refresh.
- The iOS 26 `WidgetPushHandler` (`apns-push-type: widgets`) [11][12] could
  later push edits made on the web. It is budgeted, so it is a bonus rather than
  a guarantee.

**Controls.** `ControlWidgetButton`s, configured per topic and option (for
example "Log coffee"), can go in Control Center, on the Lock Screen, or on the
**Action button**.

**Tinted Home Screens.** Use `widgetAccentedRenderingMode(.accentedDesaturated)`
[12].

## 8. App Intents, Siri, Shortcuts and the Action button

**Entities.**

- **`TopicEntity`** (`IndexedEntity`) is backed by an `EntityStringQuery` over
  GRDB. The app indexes topics for Spotlight after each sync with
  `CSSearchableIndex.indexAppEntities` [8].
- **`TopicOptionEntity`** has a query that depends on the chosen topic
  (`@IntentParameterDependency`), so Shortcuts and Siri can offer dynamic option
  lists.

**Intents.**

- **`LogEntryIntent(topic, option?, number?, note?)`**:
  - Only for quick-log-eligible topics.
  - Validates with the Core rules and asks for anything missing with
    `requestValue`.
  - `supportedModes = [.background]` [8], so it doesn't open the app.
- **`RepeatLastEntryIntent(topic)`** works for **any** topic, including
  multi-question ones. It is the natural Action button default.
- **`OpenRecordIntent(topic)`** runs in the foreground. It is handled with
  `onAppIntentExecution` [8], which pushes the record screen.
  - Intent parameters are static, so multi-question topics can't be answered by
    voice. They open the record screen instead. **This is a documented
    limitation.**
- Log intents adopt **`UndoableIntent`** [8]. Undo deletes by entry id,
  following the §3 rules.

**App Shortcuts.** `AppShortcutsProvider` registers "Log \(\.$topic) in quickR",
"Same as last time for \(\.$topic)" and "What's due in quickR". The app calls
`updateAppShortcutParameters()` whenever topics change.

**Action button.** It binds to a Shortcut or a Control, so it needs no extra
API.

## 9. UI architecture

- **State:** one `@Observable` model per screen consuming
  `ValueObservation.values(in:)` in `.task`; `SyncEngine`, `Router`,
  `ToastCenter` and `Settings` injected via `@Environment`. No framework.
- **Navigation:** `Router` owns a `NavigationPath` of
  `enum Route { topic, record(fix:), entries, editEntry, versions, editQuestions, topicSettings, newTopic, settings }`.
  `Router.handle(url:)` parses the PWA paths (`/t/{slug}/record`, …) from
  `quickr://` links, the notification `url` and widget links. Universal links
  are optional (the AASA file needs a Cloudflare Access bypass).
- **Form engine:** `FormState` holds string drafts per key; `QuestionField`
  renders numbers (mono field, 52 pt ±, clamped, unit), text, chips (≤ 6) or a
  `Picker`, and multi-select chips with "pick 1–3" rules. Messages are ported
  from `answerSchema.ts`. `@FocusState<String?>` implements the PWA focus rules
  (first unanswered field, chips never focused, a chip moves focus on,
  `.onSubmit` → next). Single-select-only topics save on chip tap; edit renders
  the entry's own version with retired options.
- **Shared pieces:** tiles reuse Core's `QuickLog`; `ToastCenter` gives 6 s undo
  toasts and logging has no confirmations; `.sensoryFeedback` haptics; Swift
  Charts (`BarMark` histograms/option bars/stacked, `LineMark` mean +
  `AreaMark` min–max band).
- **Brand:** asset-catalog colour sets with dark variants;
  `Font.custom(_:size:relativeTo:)` for Dynamic Type; `Canvas` dot grid; stock
  lists, sheets and Liquid Glass chrome.

## 10. Testing

- **Package (Swift Testing):** Core (validation, quick-log, due vectors), API
  (fixture decoding; `URLProtocol` stub for headers, redirect policy,
  classification), Store (migrations, incl. from a previous-schema fixture),
  Sync (the ~30 `outbox.test.ts` cases ported, plus undo, coalescing, leases,
  merge rule; fake clock and transport).
- **Integration (opt-in):** sync engine against the docker stack on :8100.
- **XCUITest (stub server):** quick-log chip + Undo; offline log then sync;
  deep link to `/t/{slug}/record`. The notification handler is unit-tested
  (`xcrun simctl push` injects pushes, but action taps are hard to automate).
- **Optional:** `swift-snapshot-testing` for chips, tiles and widgets (light,
  dark, tinted).
- **`make check-ios`:** `xcodegen`, `swift test`, `xcodebuild test`, fixture
  drift checks.

## Risks and unknowns

1. **Notification action time** is undocumented; mitigated by writing to the
   outbox first.
2. **NSE category registration** and the number of visible actions need a
   device spike in an early milestone.
3. **Multi-process SQLite** (0xDEAD10CC, `SQLITE_BUSY`, extension before
   migration) relies on GRDB's recipe and the pending-log file; soak-test it.
4. **Lock Screen widget buttons** require an unlock [10].
5. **B1 is on the critical path:** without tombstones, deletes made on the web
   never reach the phone.
6. **Cloudflare Access** answers a bad token with a redirect or 403 (retryable,
   shown as "Sign-in problem"); universal links need an AASA bypass.
7. **Swift Testing on Command Line Tools alone** is unverified.

## Sources

1. WWDC26 "SwiftData Group Lab".
   https://developer.apple.com/videos/play/wwdc2026/8017/
2. Forums: SwiftData with App Groups and widgets.
   https://developer.apple.com/forums/thread/789173 ·
   https://developer.apple.com/forums/thread/764290
3. Forums: iOS 26.1 SwiftData crash; ModelActor issues.
   https://developer.apple.com/forums/thread/808020 ·
   https://developer.apple.com/forums/thread/770416
4. GRDB, "Sharing a Database".
   https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/DatabaseSharing.md
5. GRDB 7.11.1 (July 2026). https://swiftpackageindex.com/groue/GRDB.swift
6. SQLiteData 1.0.
   https://forums.swift.org/t/sqlitedata-1-0-an-alternative-to-swiftdata-with-cloudkit-sync-and-sharing/82211
7. swift-openapi-generator supported features.
   https://github.com/apple/swift-openapi-generator/blob/main/Sources/swift-openapi-generator/Documentation.docc/Articles/Supported-OpenAPI-features.md
   7b. Version 1.12.1 (2026-05-11).
   https://swiftpackageregistry.com/apple/swift-openapi-generator
8. WWDC25 "Explore new advances in App Intents".
   https://developer.apple.com/videos/play/wwdc2025/275/
9. Forums: AppIntentsPackage guidance; localization in packages.
   https://developer.apple.com/forums/thread/759160?page=2 ·
   https://developer.apple.com/forums/thread/806804
10. Apple, "Adding interactivity to widgets and Live Activities".
    https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
11. Apple, `WidgetPushHandler`.
    https://developer.apple.com/documentation/widgetkit/widgetpushhandler
12. WWDC25 "What's new in widgets" (notes).
    https://wwdcnotes.com/documentation/wwdc25-278-whats-new-in-widgets/
13. Apple, "Declaring your actionable notification types".
    https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types
14. Apple, `UNNotificationCategory` initializer.
    https://developer.apple.com/documentation/usernotifications/unnotificationcategory/init(identifier:actions:intentidentifiers:hiddenpreviewsbodyplaceholder:options:)
15. Apple, "Customizing the appearance of notifications".
    https://developer.apple.com/documentation/usernotificationsui/customizing-the-appearance-of-notifications
16. Cloudflare Access service tokens.
    https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/
17. PEP 495. https://peps.python.org/pep-0495/
18. Apple, BackgroundTasks.
    https://developer.apple.com/documentation/backgroundtasks
19. Apple, "Sharing access to keychain items among a collection of apps".
    https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
20. Apple, "Sending notification requests to APNs".
    https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
21. Batch SDK docs: about 30 s to handle an action (not an Apple guarantee).
    https://doc.batch.com/developer/sdk/ios/advanced/adding-notification-actions
