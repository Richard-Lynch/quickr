# quickR iOS: delivery plan

Status: **draft v1** (2026-10-17), not yet adversarially reviewed. Inputs:
[REQUIREMENTS.md](REQUIREMENTS.md) (decisions, binding),
[research/00-scouting.md](research/00-scouting.md),
[01-toolchain.md](research/01-toolchain.md),
[02-architecture.md](research/02-architecture.md),
[03-backend.md](research/03-backend.md). The research files hold the detail and
the sources. This plan is what we commit to.

## 1. Summary

A native SwiftUI app (iOS 26+, iPhone) lives in `ios/` in this repo. It is a
thin XcodeGen project around a local Swift package, `QuickrKit`, which holds
almost all the logic. The app keeps a full offline mirror in GRDB/SQLite inside
the App Group. Writes go through a durable outbox ported from the PWA, and reads
come from a new entries change feed with tombstones. Reminders are server-sent
APNs with per-topic actionable categories, so you can log straight from the
notification. Widgets, Controls and App Intents (Siri, Shortcuts, the Action
button) write to the same shared store.

The backend gets additive, PWA-safe changes: an `ios` channel, a change feed
with tombstones, an APNs sender, an actionable push payload, shared test vectors
and fixtures, and an OpenAPI tweak. The PWA keeps working and picks up parity
features where the web platform allows.

Delivery runs through 8 milestones (M0–M7). Each one is a PR into `feat/ios-app`
with demo media and a validation checklist. A final PR merges `feat/ios-app`
into `main`.

## 2. Key decisions

Each decision is the recommended option. The rejected option and the reason are
in the research files.

| Area                 | Decision                                                                                                                                                                                                                                                                                                         | Rejected (why)                                                                                                         |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Project              | **XcodeGen** `ios/project.yml`. The `.xcodeproj` is gitignored and generated.                                                                                                                                                                                                                                    | Committed pbxproj (churn, agent-hostile); Tuist (more moving parts)                                                    |
| Code layout          | Local SPM package `ios/QuickrKit` with these targets: `QuickrCore` (models, validation, quick-log rules, due logic; no dependencies), `QuickrAPI`, `QuickrStore` (GRDB), `QuickrSync`, `QuickrUI`, `QuickrIntents`. Core, API, Store and Sync also build for **macOS** so `swift test` runs without a simulator. | One fat app target                                                                                                     |
| Targets              | `QuickR` app, `QuickRWidgets` (widgets and controls), `QuickRNotificationService` (NSE), unit tests, UI tests                                                                                                                                                                                                    | Notification content extension (not needed for v1)                                                                     |
| Persistence          | **GRDB 7** `DatabasePool` (WAL) in `group.com.bahumia.quickr`. Only the app runs migrations; extensions degrade gracefully.                                                                                                                                                                                      | SwiftData (cross-process and migration problems, 26.x regressions)                                                     |
| Local data           | Mirror **everything**: all topics including archived, all versions, all entries. Stats and series are **server-computed and cached**, and show as stale when offline.                                                                                                                                            | Windowed history (can't browse old data offline)                                                                       |
| Sync pull            | Re-pull the topic list (`status=all`); fetch versions when `current_version` moves; new **`GET /entries/changes?cursor=`** keyset feed plus a **`deleted_records`** tombstone table.                                                                                                                             | Combined `/sync` endpoint (more new shapes); re-pulling a window (misses old edits and deletes)                        |
| Sync push            | Outbox table, a 1:1 port of the PWA state machine (same retry and terminal classification, same backoff). Kinds: `entry.create/update/delete`, `topic.archive/unarchive`. Coalescing at enqueue. Leases for cross-process exclusion.                                                                             | Background `URLSession` (out-of-process replays could recreate undone entries)                                         |
| Online-only ops      | Topic create, question publish (needs a live 409), topic delete, schedule edit. Each gives a clear "needs connection" error.                                                                                                                                                                                     | Queuing them (conflicts that need a person to resolve)                                                                 |
| API client           | **Hand-written Codable client** (about 25 endpoints). Contract-tested against **backend-generated JSON fixtures** with a drift check.                                                                                                                                                                            | swift-openapi-generator (patternProperties, const, overlapping anyOf, fractional dates; the models get wrapped anyway) |
| Due logic            | Swift port of `schedule.py` with explicit PEP 495 fold semantics, verified against **Python-generated vectors** in `shared/fixtures/`. The server stays authoritative after each sync.                                                                                                                           | Trusting `Calendar` DST heuristics                                                                                     |
| Reminders            | Server APNs. **Frozen contract:** `apns-collapse-id` = request identifier = `due-{topic_id}`, `thread-id` = `topic-{topic_id}`. A future local fallback uses the same identifier and dedupes for free.                                                                                                           | Local-only (stale when logged elsewhere)                                                                               |
| Notification actions | Category per topic, `quickr.topic.{id}`: one action per chip option, or "✓ last value" plus a text input for a number, plus "Open". The app registers all categories after every sync; the NSE upserts the category from the payload's `quick_log` descriptor.                                                   | Content extension with custom UI                                                                                       |
| Widgets              | `AppIntentConfiguration` per topic, `Button(intent:)` quick-log, a due-list widget, Lock Screen accessories, `ControlWidgetButton`s (Control Centre and the Action button). Timelines are computed locally.                                                                                                      | Network-backed widgets                                                                                                 |
| App Intents          | `TopicEntity` (IndexedEntity, Spotlight), `LogEntryIntent` (quick-log-eligible topics), `RepeatLastEntryIntent` (any topic), `OpenRecordIntent` (fallback), App Shortcuts phrases                                                                                                                                | Per-question dynamic parameters (impossible)                                                                           |
| UI                   | `@Observable` screen models fed by GRDB `ValueObservation`. `NavigationStack` with a typed `Route` and a URL parser for the PWA paths. A schema-driven form engine with `FocusState`. Swift Charts. System navigation, lists and sheets with brand tokens and fonts.                                             | TCA or another framework                                                                                               |
| Headers              | `X-QuickR-Channel: ios` (new enum value). `source` is one of `ios`, `ios.widget`, `ios.notification`, `ios.siri`. `CF-Access-Client-Id/Secret` from the shared Keychain group, sent only when configured.                                                                                                        | n/a                                                                                                                    |
| Dependencies         | GRDB; swift-snapshot-testing (tests only); tools: xcodegen, swift-format, ffmpeg, rsvg-convert, fonttools (uvx). Backend: `httpx[http2]`, explicit `pyjwt[crypto]`.                                                                                                                                              | fastlane, aioapns                                                                                                      |

## 3. Repository layout (target)

```
ios/
  project.yml                     XcodeGen spec (targets, entitlements, Info.plist, schemes)
  QuickrKit/Package.swift         QuickrCore, QuickrAPI, QuickrStore, QuickrSync, QuickrUI, QuickrIntents
  QuickrKit/Tests/…               Swift Testing; Fixtures/ links shared vectors + API fixtures
  App/  Widgets/  NotificationService/  UITests/  TestPlans/
  Resources/Fonts (static instances + OFL.txt), Assets.xcassets (colours, AppIcon)
  scripts/                        icons.sh, fonts.sh, sim.sh, device.sh, demo.sh, testflight.sh
  Local.xcconfig (gitignored)     DEVELOPMENT_TEAM, device id
shared/fixtures/                  due-vectors.json, quicklog-vectors.json, api/*.json (all generated, drift-checked)
backend/…                         changes in §5
docs/ios/                         REQUIREMENTS, PLAN, research/, demo/ (media used in PRs)
.github/workflows/ios.yml         macOS build + unit tests, path-filtered
```

## 4. Workflow and branch management

- **Integration branch:** `feat/ios-app` (worktree `../quickr-worktrees/ios`).
- **Milestone branch:** `ios/mN-<name>`, cut from `feat/ios-app`. One PR per
  milestone into `feat/ios-app`.
- **Work packages:** each milestone is split into work packages (WPs) with
  disjoint file ownership.
  - Each WP runs in a sub-agent with its own worktree
    (`../quickr-worktrees/ios-mN-<wp>`) on branch `ios/mN-<wp>`, cut from the
    milestone branch.
  - I (the orchestrator) review each WP diff and run the gates, then merge it
    into the milestone branch with `--no-ff`, so the history keeps one merge per
    WP.
  - Contracts between WPs (DTOs, table schemas, protocols) land first, in a
    "contracts" WP, so the parallel WPs build against stable interfaces.
  - At most 3–4 parallel WPs per milestone.
- **Before opening a milestone PR:**
  1. All gates green (§8).
  2. A code-review sub-agent pass, plus a `codex` review of the milestone diff.
  3. Demo media recorded with `make ios-demo-record` / `ios-shots`, stored under
     `docs/ios/demo/mN/` and embedded in the PR.
  4. The PR body carries the milestone's validation checklist with each item
     ticked, or marked as skipped with a reason.
- **Merging milestone PRs:** to keep moving, milestone PRs are **non-blocking by
  default**.
  - I merge into `feat/ios-app` once the gates and reviews pass, then start the
    next milestone.
  - You review the PR (and its demos) asynchronously. Comments become fix-ups on
    the next milestone branch.
  - A PR is **blocking** if it changes a decision in this plan or needs your
    input. Then I wait. _(See open question Q1.)_
- **Keeping up with `main`:** merge `main` into `feat/ios-app` at the start of
  each milestone.
- **Final:** a PR from `feat/ios-app` into `main` after M7. It carries the full
  release notes and a final demo. Backend changes ride along. If that PR gets
  too large, B1–B4 can be split out to `main` early, since they are PWA-safe.
- **Commits:** follow the repo's style ("Area: summary"). No force-pushes on
  shared branches.

## 5. Backend and PWA changes (B-series)

All of these are additive and keep `make check` green. Each change regenerates
`openapi.json` and `frontend/src/client` in the same commit. Details and file
references are in [research/03-backend.md](research/03-backend.md).

| ID  | Change                                                                                                                                                                                                                                                                                                                                                                              | Milestone                        |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| B1  | OpenAPI: `answers` map uses `additionalProperties` (via `WithJsonSchema`, dropping the redundant int branch). Typecheck fallout in the frontend is fixed.                                                                                                                                                                                                                           | M0                               |
| B2  | **Shared vectors.** A pytest generator writes `shared/fixtures/due-vectors.json` (DST grid: London, New York, Lord Howe, Kolkata, Kathmandu, UTC) and `quicklog-vectors.json`, with a drift assertion and `make vectors`.                                                                                                                                                           | M0                               |
| B3  | **`ios` channel:** `ALTER TYPE … ADD VALUE` in `autocommit_block`. Downgrade remaps to `api` and rebuilds the type. Plus a roundtrip test.                                                                                                                                                                                                                                          | M0                               |
| B4  | **Change feed:** `GET /entries/changes?cursor=&limit=` returning `{server_time, items, deleted, next_cursor, has_more, resync_required}`. Also a `deleted_records` table (90-day retention, written in the services so REST and MCP both record it, and cleared when an id is re-created), an `(updated_at, id)` index, server-side `now()` for `updated_at`, and `GZipMiddleware`. | M1                               |
| B5  | **API fixtures:** `backend/scripts/gen_api_fixtures.py` dumps representative responses (every question type, enum_list, problems, pages, change feed) to `shared/fixtures/api/`, with a drift check.                                                                                                                                                                                | M1                               |
| B6  | **APNs:** an `apns_devices` table, register, delete and test endpoints, and `GET /push/config` gains `apns_enabled`. A `Sender` protocol shared with Web Push. `httpx[http2]` with an ES256 JWT cached for 50 min, an error map, pruning, concurrent sends with batched topic marks in the tick. The `QUICKR_APNS_*` config stays off unless set.                                   | M5 (code can land earlier, dark) |
| B7  | **Actionable payload:** a channel-neutral `Notification` with `topic_id`, `version`, `due_since` and a `quick_log` descriptor (a Python port of `quickLogFor`, checked against the shared vectors, with `last_value`). APNs `category`, `thread-id`, `apns-collapse-id`, `mutable-content`. The Web Push payload gains optional fields only.                                        | M5                               |
| B8  | **PWA parity:** Chromium notification `actions` for enum quick-log (≤ `maxActions`). `notificationclick` with an action enqueues an outbox entry. Display of the `ios` channel badge.                                                                                                                                                                                               | M5                               |
| B9  | **Hosting:** docs for Cloudflare Access (service token, `/mcp` policy, AASA bypass if universal links are used). Optional `Cf-Access-Jwt-Assertion` verification behind `QUICKR_ACCESS_AUD`.                                                                                                                                                                                        | M7                               |

## 6. Milestones

Size is relative effort (S < M < L < XL). **Blocked by** lists the human steps
(§7) that must be done before the milestone can _finish_. Work starts earlier
wherever possible.

### M0: Foundations and shared contracts · M · Blocked by: none

- **Backend:** B1, B2, B3.
- **iOS skeleton:**
  - `ios/project.yml` with all targets, entitlements (App Group;
    `aps-environment` added in M5), bundle IDs
    `com.bahumia.quickr{,.widgets,.notification-service}`.
  - The QuickrKit package skeleton.
  - `make ios-*` targets with the fail-fast Xcode guard. `make check` is
    unchanged; `check-ios` is separate.
  - `.github/workflows/ios.yml` on `macos-26` with Xcode pinned, path-filtered,
    concurrency-cancel.
- **QuickrCore:**
  - Domain models: Topic, Version, the Question enum, AnswerValue, Entry,
    Schedule, DueStatus.
  - Validation rules and messages ported from `answerSchema.ts`.
  - Quick-log eligibility and the initial-value port.
  - The due-logic port: slots, satisfied, daily, interval, `compute_due`,
    `due_message`.
- **Validation:**
  - `swift test` for QuickrCore passes every due and quick-log vector. It runs
    on CI `macos-26`, and locally via the Command Line Tools if Swift Testing
    works there.
  - A migration roundtrip test for `ios`.
  - `make check` green. The OpenAPI and TS client regenerate cleanly.
- **Demo:** CI run link, test summary, vector counts. There is no UI yet.

### M1: Data layer: API client, store, sync engine · L · Blocked by: none (host tests)

- **Backend:** B4, B5.
- **QuickrAPI:**
  - Client actor, ephemeral `URLSession`, redirect refusal, header decorator,
    date strategy (0–6 fraction digits in, an explicit offset out), Problem
    decoding with `loc` mapping, response classification.
- **QuickrStore:**
  - GRDB schema v1: `topic`, `topic_version`, `entry` (with `local_state`),
    `outbox`, `sync_meta`, `ui_draft`. The migrator.
  - Repositories, `ValueObservation` helpers, a cross-process Darwin-notify
    signal.
  - File protection `completeUntilFirstUserAuthentication`.
- **QuickrSync:**
  - The outbox state machine: classification table, backoff, coalescing, undo
    rules, leases, compare-and-set bookkeeping.
  - Pull: topics, versions, change feed, the tombstone merge rule ("local outbox
    wins").
  - Initial backfill. A `resync_required` wipe-and-repull.
  - Flush triggers as protocols (the app wires them in M2).
- **Validation:**
  - Fixture decoding covers every `shared/fixtures/api` file.
  - About 30 outbox cases ported from `outbox.test.ts`, plus undo, coalesce,
    lease and merge tests, using a fake clock and transport.
  - An opt-in integration test plan against the docker stack:
    1. Seed.
    2. Full sync.
    3. Create offline, flush, verify on the server.
    4. Delete on the server, and see the tombstone applied locally.
    5. Undo after send.
  - Backend tests for paging with equal timestamps, tombstones from REST and
    MCP, and retention.
- **Demo:** an integration test log and a short write-up of a sync trace. No UI.

### M2: App shell and daily logging · XL · Blocked by: H1, H2 (Xcode)

- **Design system** (QuickrUI): asset-catalog colour tokens (light/dark, from
  `index.css`), static font instances plus a `Font.brand` with Dynamic Type, the
  dot-grid `Canvas`, chips, the stepper, the tile, the toast centre, the sync
  pill, the app icon set (`make ios-icons`), haptics.
- **App:**
  - Settings onboarding: server URL; the CF token is optional and stored in the
    Keychain.
  - Home (due-first: Due now / Coming up / Topics; search, filter and sort; the
    badge count).
  - Quick-log tiles with exact PWA parity: chips, a number stepper with ✓,
    last-value dot, the 1.6 s confirmation, kept stepper drafts.
  - The record screen: the form engine for all types; focus rules; "Same as last
    time"; the details section; "Log another"; auto-save on a chip for
    single-select-only topics; the fix mode for failed items.
  - Undo toasts (6 s).
  - The sync sheet: retry, fix, discard.
  - Deep links `quickr://t/{slug}/record` (and the other PWA paths).
  - Flush triggers wired up: `scenePhase`, `NWPathMonitor`, backoff timer,
    `BGAppRefreshTask`.
- **Validation:**
  - XCUITest flows:
    1. Chip quick-log, then Undo.
    2. A multi-question entry offline, then back online, then synced.
    3. A deep link to record.
  - **Tap-count table re-measured** on the simulator, meeting every PWA number
    (the tap-count table in `frontend/docs/design-loop.md`).
  - Dark and light screenshots of every screen. Dynamic Type at XL checked.
  - Device install once H3–H5 are done (see §7).
- **Demo:** GIFs for a quick-log chip with Undo, a stepper log, offline logging
  then sync, and same-as-last-time. Home screenshots in light and dark.

### M3: History and entries · M · Blocked by: H2

- Entries list (filters: range, version, source; pending and failed items pinned
  at the top), infinite scroll from the local store.
- Edit an entry, rendered against its pinned version with retired options shown.
  Optimistic, via the outbox.
- Delete with undo (`deleting` state, sent after 6 s or on backgrounding).
- CSV export through the share sheet (online; server CSV).
- Offline history browsing.
- **Validation:**
  - UI test for edit then delete then undo.
  - Unit tests for the version-pinned rendering.
  - An integration test confirming that an edit made on the web appears on the
    phone via the feed.
- **Demo:** GIFs of the entries list, an edit, and delete with undo.

### M4: Management parity · L · Blocked by: H2

- Topic overview and stats: summary, numeric (mean, the stats grid, a histogram,
  a mean line with a min–max band), enum (option bars, stacked bars over time),
  text. Swift Charts. Cached responses carry a "Last updated" label.
- New topic. The question builder for every type (enum options, multi-select
  limits, archiving options, required, help text). The version check with a
  compatibility report sheet, publish, and the "someone else published first"
  conflict flow.
- The versions screen.
- Topic settings: details, the schedule editor (none, daily times and weekdays
  with a timezone, interval; notify), archive with undo, delete with typed
  confirmation.
- App settings: notifications (permission and test push), sync status and "Sync
  now", local data reset, about and licences.
- **Validation:**
  - Builder unit tests ported from `builder.test.ts`.
  - UI test: create topic, log, publish v2, log again.
  - Charts match the PWA numbers on seeded data (screenshot comparison).
- **Demo:** GIFs of creating a topic, editing questions with a compatibility
  warning, and the stats screens.

### M5: Reminders and logging from a notification · L · Blocked by: H3, H4, H5, H6

- **Backend:** B6, B7, B8.
- **iOS:**
  - APNs registration on launch (token and environment).
  - Per-topic categories, registered after each sync.
  - The NSE upsert, with a fallback to the generic `quickr.due` category.
  - The action handler: lightweight boot, write the entry and the outbox row in
    one transaction, recompute due, set the badge, remove the delivered
    notification, flush with a budget, then complete.
  - Number text input parsed with the question's rules. Invalid input produces a
    "tap to fix" local notification.
  - Settings: the "Test this device" button.
- **Spikes first (on a device):**
  1. The NSE category-upsert timing.
  2. How many actions the expanded notification shows.
  3. The action background-time budget.
  4. Logging from the Lock Screen with the store protected until first unlock.

  Go/no-go is recorded in the PR.

- **Validation:**
  - Backend: `MockTransport` tests (JWT, headers, error table, payload ≤ 4 KB),
    the scheduler fans out to web and APNs exactly once, payload golden tests.
  - Device end to end in the sandbox:
    1. A due reminder arrives.
    2. A chip action logs with the app killed.
    3. The entry shows on the server with `channel=ios` and
       `source=ios.notification`.
    4. The badge updates.
  - The PWA shows actions in Chromium, and logging from them works.
- **Demo:** a device screen recording of a reminder, a long-press, logging from
  the action, and the PWA/home updating.

### M6: Widgets, Controls, Siri and Shortcuts · L · Blocked by: H3–H5 (device verification)

- **QuickrIntents:**
  - `TopicEntity` and `TopicOptionEntity` with a dependent query.
  - `LogEntryIntent`, `RepeatLastEntryIntent`, `OpenRecordIntent`, each
    `UndoableIntent` where applicable.
  - `AppShortcutsProvider` phrases, and Spotlight indexing after sync.
- **Widgets:**
  - A per-topic quick-log widget (small and medium: chips, or stepper plus ✓
    using `ui_draft`).
  - A due-list widget (medium and large).
  - Lock Screen accessories.
  - `ControlWidgetButton` per topic and option, usable from the Action button.
  - Timelines at the next due times within 24 h. Reload after every write, sync
    and background refresh. Accented and tinted rendering.
- **Validation:**
  - Intents resolve from both the app and the widget.
  - Simulator snapshots of widgets in light, dark and tinted.
  - On the device:
    1. A widget chip logs with the app killed.
    2. The Action button runs `RepeatLast`.
    3. "Log water in quickR" works through Siri.
  - The multi-process soak: logging repeatedly from the app, the widget and a
    notification at the same time leaves no `SQLITE_BUSY` errors and no
    0xDEAD10CC crashes.
- **Demo:** GIFs of logging from a widget, the Action button, and Siri.

### M7: Hardening, delivery and hosting · M · Blocked by: H7 (TestFlight), H8 (Cloudflare)

- **TestFlight:** `make ios-testflight` (archive, then export with upload, using
  an App Store Connect API key). Build numbers come from the git commit count.
- **Hosting:** B9, the server URL and CF token in Settings, an end-to-end test
  against the Cloudflare host, and documentation of the MCP policy.
- **Polish:**
  - An accessibility pass (VoiceOver labels, Dynamic Type up to AX sizes, 44 pt
    targets).
  - Performance (cold start under 1 s to an interactive home with 10k entries).
  - Upgrade-migration test from the v1 schema.
  - Docs: `ios/README.md`, and an iOS section in the root README and `pwa.md`.
- **Final PR** from `feat/ios-app` into `main`.
- **Validation:**
  - A TestFlight build installs over the air.
  - The production APNs path works from TestFlight.
  - The full regression checklist (every milestone's flows) passes on the
    device.

## 7. Who does what

### Human steps (yours)

| #   | Step                                                                                                                                                                                                                                                           | Needed before       | Effort                           |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | -------------------------------- |
| H1  | **Upgrade macOS to Tahoe 26.6+** (the Mac is on 15.6.1; Xcode 27 needs Tahoe)                                                                                                                                                                                  | H2                  | ~1 h                             |
| H2  | **Install Xcode 27.x** from the App Store or `xcodes`, then `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform iOS`. I'll run `brew install xcodegen` myself. | M2                  | ~1 h                             |
| H3  | **Enroll in the Apple Developer Program** (individual, $99/yr). Note the Team ID.                                                                                                                                                                              | Device installs, M5 | Minutes, then 0–2 days of review |
| H4  | **Xcode ▸ Settings ▸ Accounts:** sign in with the enrolled Apple ID (once)                                                                                                                                                                                     | First device build  | 2 min                            |
| H5  | **Phone:** connect it by cable, tap Trust, turn on Developer Mode (Settings ▸ Privacy & Security, then reboot), and optionally enable "Connect via network". Tell me the phone's iOS version.                                                                  | First device build  | 10 min                           |
| H6  | **APNs key:** developer.apple.com ▸ Keys ▸ + ▸ APNs, environment "Sandbox & Production". Download the `.p8` (it can only be downloaded once) and save it outside the repo. Give me the Key ID and Team ID.                                                     | M5                  | 5 min                            |
| H7  | **App Store Connect:** create the app record `com.bahumia.quickr`, then a Team API key (App Manager role). Note the key `.p8`, Key ID and Issuer ID.                                                                                                           | M7 TestFlight       | 15 min                           |
| H8  | **Cloudflare:** tunnel to the home box, an Access application, and a service token for the app. Decide the `/mcp` policy.                                                                                                                                      | M7 hosting          | ~1 h                             |
| H9  | **Milestone PR reviews** (asynchronous, see Q1). Optional: an Icon Composer layered icon.                                                                                                                                                                      | Ongoing             | —                                |

### Claude's work

Everything else:

- all code (backend, PWA, iOS), tests, CI, scripts, docs, project generation;
- simulator and device builds, installs and test runs;
- demo media;
- orchestrating sub-agents, and merging their work packages;
- milestone PRs, reviews (sub-agent and `codex`), and fix-ups.

I ask you only for the H-steps above, or when a plan decision needs to change.

### What can proceed before each human step

- **Now (no Xcode):** M0 and M1 in full. The Swift packages compile and test on
  CI `macos-26`. That CI run is the first real compile, and the `swift test`
  host tests run there.
- **After H2, before H3:** M2–M4 in the simulator, including UI tests, widgets
  in the simulator, `simctl push` with the payload contract, and demos.
- **After H3–H5:** device installs from M2 onward, and real APNs (M5).
- **After H7 and H8:** M7.

## 8. Validation and gates

| Gate                | Contents                                                                                                                                                          | Where                     |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| `make check`        | Existing backend and frontend gate, plus the vector and fixture drift checks                                                                                      | Local, and CI `ci.yml`    |
| `make check-ios`    | `xcodegen generate`; `swift test` (QuickrKit); `xcodebuild test` with the Unit and UI plans on the pinned simulator; swift-format lint; asserts the Xcode version | Local (needs Xcode)       |
| `make ios-check-ci` | The same, without UI tests, with `CODE_SIGNING_ALLOWED=NO`                                                                                                        | CI `ios.yml` (`macos-26`) |
| Integration plan    | Sync engine against the local docker stack (opt-in, needs `make up`)                                                                                              | Local, before M1–M4 PRs   |
| Device checklist    | A per-milestone manual and scripted checklist on the phone, listed in the PR                                                                                      | Local device              |
| Reviews             | A code-review sub-agent plus `codex review` on every milestone diff, with findings addressed or answered in the PR                                                | Before each PR            |

**Definition of done for a milestone:**

- Gates green.
- Validation items ticked.
- Demo media embedded.
- No unresolved review findings.
- Docs updated: `docs/ios/` and the research decisions, if any changed.

## 9. Risks and mitigations

| Risk                                                                           | Mitigation                                                                                                                             |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| The macOS or Xcode upgrade is delayed                                          | M0 and M1 are host- and CI-only, and CI `macos-26` compiles the code. If needed, fall back to Xcode 26.3 on Sequoia for the simulator. |
| Notification-action background time, and NSE category timing, are undocumented | Write to the outbox first and flush opportunistically. Spike at the start of M5. Fall back to a generic category with "Open".          |
| Multi-process SQLite: locks, 0xDEAD10CC, migrations owned by one process       | GRDB's sharing recipe, suspension notifications, migrations in the app only, a pending-log fallback file, the M6 soak test             |
| Commit-order gaps in the `updated_at` cursor                                   | A 2-minute overlap re-read, and idempotent upserts                                                                                     |
| DST mismatch between Python and Swift                                          | Explicit fold logic plus about 1–2k shared vectors from stable zones                                                                   |
| Interactive widgets don't run while the phone is locked                        | Documented. The notification action is the lock-screen path.                                                                           |
| Unauthenticated device registration before Cloudflare                          | Local network only until M7. Cloudflare Access covers it afterwards.                                                                   |
| macOS CI minutes cost about 10× on a private repo                              | Path filters, concurrency cancel, unit tests only in CI, an 8-minute target                                                            |
| Scope (full parity plus extras)                                                | Milestones are ordered so the daily-use value (M2, M5) arrives early. Each PR ships something usable.                                  |

## 10. Open questions for you

- **Q1. Milestone PR gating.** The default above is that I merge milestone PRs
  into `feat/ios-app` once the gates and reviews pass, and you review
  asynchronously. Do you prefer that, or should each milestone PR wait for your
  approval?
- **Q2. Logging from the lock screen.** Notification actions log **without**
  Face ID by default (the 2-tap bar). Should logging from the lock screen need
  authentication?
- **Q3. Siri and Shortcuts for multi-question topics.** These would open the
  record screen; there's no voice entry for every field. Acceptable?
