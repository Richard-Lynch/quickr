# quickR iOS: status and checklists

This is the live tracker. [PLAN.md](PLAN.md) is the design; this file records
what is done, what is in progress, and what is next.

The orchestrator updates it at every state change: a WP starts or merges, a gate
result comes in, a review finishes, a PR opens or merges, a human step
completes. It changes in the same commit as the work, on the active milestone
branch.

**Legend:**

- `[x]` done
- `[~]` in progress
- `[ ]` to do
- `[-]` skipped, with a reason

**Last updated:** 2026-10-17, M0 in progress.

## Now

|                     |                                                                                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Active milestone    | **M0: backend foundations and specs** (branch `ios/m0-foundations`)                                                       |
| Running             | WP feed, WP vectors, WP specs (sub-agents, each in its own worktree)                                                      |
| Waiting on the user | Xcode install (via `xcodes`); Apple enrollment activation and the Team ID; iPhone model and iOS version; answers to Q1–Q4 |
| Next up             | Integrate the M0 work packages, with a Codex review each → `ios/` scaffolding once Xcode lands → M0 PR                    |

## Human steps (PLAN §9)

- [x] H1: upgrade macOS. The Mac is on **macOS 27.0.1**, not Tahoe; Xcode 27
      supports it.
- [~] H2: install Xcode 27.x with `xcodes` (another agent is doing it), then run
  `xcode-select` and accept the licence. Report the install path.
- [~] H3: Apple Developer enrollment. Submitted 2026-10-17 (order W1832720362),
  awaiting activation. Then send the Team ID.
- [ ] H4: Xcode ▸ Settings ▸ Accounts sign-in. Needed after H3, before
      checkpoint D.
- [ ] H5: phone. Trust this Mac, turn on Developer Mode, and send the model and
      iOS version.
- [ ] H6: APNs `.p8` key, with its Key ID (M3).
- [ ] H7: App Store Connect app record and API key (M7).
- [ ] H8: Cloudflare tunnel, Access app and service token (M7).

## Open questions (PLAN §10)

Each one is answered for now with the default shown below, marked provisional.
The user can override any of them.

- [ ] Q1: milestone PRs merge without waiting for review (default: yes)
- [ ] Q2: lock-screen notification logging without Face ID (default: yes)
- [ ] Q3: Siri opens the record screen for multi-question topics (default: yes)
- [ ] Q4: notifications show the 4 most-used options (default: yes)

## Environment and tooling

- [x] Docker and Postgres running (`make db`, :5433)
- [x] xcodegen 2.46 and xcbeautify installed (brew)
- [x] MobileBuildMCP 2.7.1 configured: project `.mcp.json` plus
      `.mobilebuildmcp/config.yaml`, and local scope for `~/code/quickr`
- [ ] Xcode selected (`xcode-select -p` points at the xcodes install) and
      `xcodebuild -version` = 27.x
- [ ] Simulator runtimes installed: iOS 27 and **iOS 26.x** (needed for
      minimum-version testing)
- [ ] MobileBuildMCP tools verified after a session restart; Xcode IDE bridge
      prompt approved
- [ ] `xcode-27` GitHub runner label checked for general availability (otherwise
      CI stays on `macos-26` with Xcode 26.6)

## M0: Backend foundations and specs

Branch `ios/m0-foundations`. PR → `feat/ios-app`.

### WP feed: `ios/m0-feed` (worktree `../ios-m0-feed`)

- [~] Implementation (sub-agent)
  - [ ] B1: `answers` uses `additionalProperties`, plus a spec-shape test
  - [ ] B3: `ios` channel, an autocommit migration, and an explicit downgrade
        test
  - [ ] B4: the `change_log` table, the feed advisory lock (rule 1), and retry
        on conflict
  - [ ] B4: `deleted_ids`. A DELETE reserves the id (204), and a create with
        that id gets 409 `entry_deleted` (rule 2)
  - [ ] B4: deleting a topic tombstones its children (rule 3)
  - [ ] B4: `GET /changes`, built from a REPEATABLE READ snapshot, plus a
        backfill migration (rule 4)
  - [ ] B4: `feed_epoch`, `server_id`, `head`, and `make rotate-epoch` (rule 5)
  - [ ] B4: `revision` and `expected_revision`, returning 409 `stale_revision`
        (rule 6)
  - [ ] B4: server-side `now()` for `updated_at`, GZip, and the `conftest`
        TABLES
  - [ ] PWA: `entry_deleted` handling in the outbox and its effects, with tests
  - [ ] `openapi.json` and the TS client regenerated
- [ ] Gate: `make check` green (the sub-agent's report and an orchestrator
      re-run)
- [ ] Codex review of the WP diff; findings fixed or answered
- [ ] Merged into `ios/m0-foundations`

### WP vectors: `ios/m0-vectors` (worktree `../ios-m0-vectors`)

- [~] Implementation (sub-agent)
  - [ ] `shared/fixtures/due-vectors.json` with its drift test (DST grid)
  - [ ] Python port of quick-log (`services/quicklog.py`), plus
        `quicklog-vectors.json`
  - [ ] Frontend vitest proving TS and Python quick-log agree
  - [ ] B5: API response fixtures and their generator
  - [ ] `make vectors`, and `shared/fixtures/README.md`
- [ ] Gate: `make check` green
- [ ] Codex review of the WP diff
- [ ] Merged into `ios/m0-foundations`. Then **regenerate the fixtures**,
      because the feed work adds fields and `/changes`.

### WP specs: `ios/m0-specs` (worktree `../ios-m0-specs`)

- [~] Writing (sub-agent)
  - [ ] `specs/sync-protocol.md`
  - [ ] `specs/outbox.md`, with a test matrix of about 40 cases
  - [ ] `specs/notifications.md`, including the local-fallback section
- [ ] Codex review of the specs (required by the plan); findings folded in
- [ ] Merged into `ios/m0-foundations`

### WP scaffold (starts once Xcode is installed)

- [ ] `ios/project.yml`: targets, entitlements, Info.plist keys, bundle ids
      `com.bahumia.quickr.*`
- [ ] `ios/QuickrKit/Package.swift` (tools 6.2): the Core, Data and UI targets,
      with empty tests
- [ ] `make ios-*` targets with the Xcode guard. `make check` stays Xcode-free.
- [ ] `.github/workflows/ios.yml`: path filters, the xcodegen binary,
      `swift test` on push, the full build on a ready PR or a manual dispatch
- [ ] Local smoke test: `make ios-gen` and a simulator build of an empty app

### M0 integration and PR

- [ ] All WPs merged; `make check` green on `ios/m0-foundations`
- [ ] Concurrency, feed and downgrade tests listed in the PR
- [ ] Codex review of the whole milestone diff, plus a Claude code-review
      sub-agent
- [ ] PR body: the validation checklist, and test reports instead of media (a
      stated deviation)
- [ ] PR opened → squash-merged into `feat/ios-app` (Q1 default)
- [ ] STATUS updated; M1 branch cut

## M1: Core and data layer, plus platform proof · needs H1, H2

- [ ] QuickrCore: models, validation, quick-log, and the due port (all vectors
      pass)
- [ ] QuickrData: the API client (fixtures and request goldens), the two-layer
      GRDB store, the sync engine, and the outbox (spec matrix)
- [ ] B5 request goldens validated by pytest
- [ ] Multi-process subprocess tests: concurrent writers, migrating while others
      are connected, a process killed holding the lock, lock takeover
- [ ] App skeleton: App Intents resolve from the app and the widget
- [ ] Simulator spike: notification actions with the app killed. Findings
      recorded.
- [ ] `make ios-integration`, all 5 scenarios
- [ ] `ios.yml` green
- [ ] Codex and Claude reviews; PR with test reports

## D: Device checkpoint · needs H3–H5

- [ ] devicectl install
- [ ] NSE category upsert timing
- [ ] How many notification actions are shown (banner and expanded)
- [ ] Background budget for a notification action
- [ ] Logging from the lock screen while the store is protected until first
      unlock
- [ ] Widget button behaviour
- [ ] Action button (if the phone has one)
- [ ] Go/no-go PR. A no-go waits for the user.

## M2a: Shell, design system, home · needs H2

- [ ] Design system: tokens, fonts, components, icon
- [ ] Onboarding and Settings (server URL, Cloudflare token, notification
      permission)
- [ ] Home, with due-first ordering
- [ ] Quick-log tiles at parity; undo toasts
- [ ] UI test (chip and undo); tap counts; screenshots in light and dark, and at
      Dynamic Type XL
- [ ] Reviews; PR with GIFs and screenshots

## M2b: Record, sync UX, background · needs H2

- [ ] Record-screen form engine and focus rules; "Same as last time"; "Log
      another"; auto-save; fix mode
- [ ] Sync sheet; deep links; flush triggers; BGAppRefresh
- [ ] UI tests; full tap-count table; device install (once D passes)
- [ ] Reviews; PR with GIFs

## M3: Reminders and logging from notifications · needs H3–H6

- [ ] B6 APNs sender, B7 payload, B8 PWA notification actions
- [ ] iOS: registration, the category table, the NSE, the action handler, number
      input, "Test this device"
- [ ] Backend MockTransport and failure tests; device sandbox checklist (5
      items)
- [ ] Reviews; PR with a device recording

## M4: Widgets, Controls, Siri and Shortcuts · needs H3–H5

- [ ] Intents, widgets, controls, Shortcuts phrases
- [ ] Device checks: logging with the app killed and offline, the Action button,
      Siri; multi-process soak
- [ ] Reviews; PR with GIFs and a recording

## M5: History and entries · needs H2

- [ ] Entries list and filters, edit (pinned version), delete with undo, CSV,
      offline
- [ ] UI test; integration (edit on the web, a web delete while an update is
      pending)
- [ ] Reviews; PR with GIFs

## M6: Management parity · needs H2

- [ ] Stats with Swift Charts, new topic, builder plus compatibility check and
      publish, versions, topic settings, app settings
- [ ] Builder tests, chart-model tests, UI test (create → log → publish v2 →
      log)
- [ ] Reviews; PR with GIFs

## M7: Hardening, TestFlight, hosting · needs H7, H8

- [ ] `make ios-testflight`; hosting B9 and an end-to-end test through
      Cloudflare
- [ ] Accessibility, performance, schema upgrade test, docs
- [ ] Full regression on the device
- [ ] Final PR `feat/ios-app` → `main` (squash)

## Log

- 2026-10-17: Plan v3 finalised (PR #6). Notebook merged to `main` (PR #7).
  macOS upgraded to 27.0.1. MobileBuildMCP configured. M0 started with 3
  sub-agents.
