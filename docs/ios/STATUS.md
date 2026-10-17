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

**Last updated:** 2026-10-17 17:10. M0 PR #8 is open; M1 Wave 1 is running.

**Execution plan:** [DAG.md](DAG.md) (Fable). Waves of ≤4 WPs with at most 2 simulator-heavy at once. Milestones are stacked (squash-merge, then `rebase --onto`).

## Now

|                     |                                                                                                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Active milestone    | **M1** on `ios/m1-data`. M0 merged (#8, 6249b0e).                                                                                                                                      |
| Running             | M1 Wave 1 sub-agents: **C1** contracts (`ios/m1-c1`), **DS** design system (`ios/m1-ds`, sim), **B6** APNs backend, dark (`ios/m1-b6`), **TOOLS** integration harness (`ios/m1-tools`) |
| Waiting on the user | Apple enrollment activation and the Team ID; iPhone model and iOS version; answers to Q1–Q4; a session restart to load MobileBuildMCP                                                  |
| Next up             | Wave 1 reviews (Codex) → merge C1 first → Wave 2: STORE, API, DUE, VAL                                                                                                                 |

## Human steps (PLAN §9)

- [x] H1: upgrade macOS. The Mac is on **macOS 27.0.1**, not Tahoe; Xcode 27
      supports it.
- [x] H2: install Xcode 27.x with `xcodes`. Installed Xcode 27.1 (27A9275) at `/Applications/Xcode-27.1.0.app`, selected, with Swift 6.4. (another agent is doing it), then run
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
- [x] Xcode selected (`xcode-select -p` points at the xcodes install) and `xcodebuild -version` = 27.1. Smoke tests passed: `swift test` (Swift Testing) and a simulator build of an XcodeGen app with a local package.
- [x] Simulator runtimes installed: iOS 26.0 (minimum) and iOS 27.0, with an iPhone 17 on each ("quickR iOS-26-0", "quickR iOS27"). The smoke app builds, installs, launches and screenshots on both. A stray iOS 27.1 runtime supports only "iPhone Duo"; ignore it.
- [ ] MobileBuildMCP tools verified after a session restart; Xcode IDE bridge
      prompt approved
- [x] First CI run green on `macos-26` / Xcode 26.6 / iOS 26.2 sim (PR #8). [ ] `xcode-27` GitHub runner label checked for general availability (otherwise
      CI stays on `macos-26` with Xcode 26.6)

## M0: Backend foundations and specs

Branch `ios/m0-foundations`. PR → `feat/ios-app`.

### WP feed: `ios/m0-feed` (worktree `../ios-m0-feed`)

- [x] Implementation (sub-agent): 5 commits, up to 1169835. Follow-up in progress: identity/epoch headers (rule 13).
  - [x] B1: `answers` uses `additionalProperties`, plus a spec-shape test
  - [x] B3: `ios` channel, an autocommit migration, and an explicit downgrade
        test
  - [x] B4: the `change_log` table, the feed advisory lock (rule 1), and retry
        on conflict
  - [x] B4: `deleted_ids`. A DELETE reserves the id (204), and a create with
        that id gets 409 `entry_deleted` (rule 2)
  - [x] B4: deleting a topic tombstones its children (rule 3)
  - [x] B4: `GET /changes`, built from a REPEATABLE READ snapshot, plus a
        backfill migration (rule 4)
  - [x] B4: `feed_epoch`, `server_id`, `head`, and `make rotate-epoch` (rule 5)
  - [x] B4: `revision` and `expected_revision`, returning 409 `stale_revision`
        (rule 6)
  - [x] B4: server-side `now()` for `updated_at`, GZip, and the `conftest`
        TABLES
  - [x] PWA: `entry_deleted` handling in the outbox and its effects, with tests
  - [x] `openapi.json` and the TS client regenerated
- [x] Gate: `make check` green (orchestrator re-runs: 368, then 401 pytest after integration)
- [x] Codex review: 3 rounds plus a final check, all Majors resolved (bc6f4c1, c13d3ac, e6d94cc, 47fa746, 1c5b240, 238d4cb). Declined: a forward migration for the in-place migration edit (never merged or deployed).
- [x] Merged into `ios/m0-foundations` (5239b20)

### WP vectors: `ios/m0-vectors` (worktree `../ios-m0-vectors`)

- [x] Implementation (sub-agent): 4 commits. due-vectors.json has 1,831 due cases, 360 messages and 63 slots (671 KB). quicklog-vectors.json had 221 cases and api/ 29 fixtures at first. Now 380 quick-log cases (after the ±2^53 fix) and 32 fixtures (after integration).
  - [x] `shared/fixtures/due-vectors.json` with its drift test (DST grid)
  - [x] Python port of quick-log (`services/quicklog.py`), plus
        `quicklog-vectors.json`
  - [x] Frontend vitest proving TS and Python quick-log agree
  - [x] B5: API response fixtures and their generator
  - [x] `make vectors`, and `shared/fixtures/README.md`
- [x] Gate: `make check` green (orchestrator re-run: 324 pytest and 365 vitest passed)
- [x] Codex review: round 1 found 2 Majors, both fixed (0e2843f, f958671). Round 2 approved.
- [x] Merged into `ios/m0-foundations` (98584b1). Fixtures regenerated after the feed merge (42672c0): added `/changes` bootstrap and deletion fixtures and the `entry_deleted` problem body.

### WP specs: `ios/m0-specs` (worktree `../ios-m0-specs`)

- [x] Writing (sub-agent): commits c272125, 7f9edaf, bfeb91f. outbox.md has a 46-case test matrix.
  - [x] `specs/sync-protocol.md`
  - [x] `specs/outbox.md`, with a test matrix of about 40 cases
  - [x] `specs/notifications.md`, including the local-fallback section
- [x] Codex review of the specs: 3 rounds plus a final check. All Blockers and Majors resolved; the last provenance wording fix is 35c5319.
- [x] Merged into `ios/m0-foundations`

### WP scaffold: `ios/m0-scaffold` (worktree `../ios-m0-scaffold`), started 2026-10-17 by a sub-agent

- [x] `ios/project.yml`: targets, entitlements, Info.plist keys, bundle ids
      `com.bahumia.quickr.*`
- [x] `ios/QuickrKit/Package.swift` (tools 6.2): the Core, Data and UI targets,
      with empty tests
- [x] `make ios-*` targets with the Xcode guard. `make check` stays Xcode-free.
- [x] `.github/workflows/ios.yml`: path filters, the xcodegen binary,
      `swift test` on push, the full build on a ready PR or a manual dispatch
- [x] Local smoke test: `make ios-gen` and a simulator build of an empty app
- [x] Orchestrator re-check: `check-ios` passes on both simulators (Unit 3/3 and UI 1/1 on iOS 26.0 and 27.0, from the xcresults); screenshots reviewed.
- [x] Codex review: round 1 found 2 Majors + 4 Minors, fixed in b3fd2b6 and dc658ac. Round 2 approved.
- [x] Merged into `ios/m0-foundations` (d0647f7)

### Contract reconciliation (specs ↔ feed), checked at integration: all M0 items confirmed by the feed WP and Codex, and the specs were aligned (tagged-union page, query-param `expected_revision`, incremental topic-delete cascade).

These are the server details the specs assume. Each one must be confirmed in the feed WP's code
(or fixed, or the spec changed) before M0 merges.

- [x] Every `/changes` page carries `server_id`, `epoch`, `head`, `next`, `has_more` and
      `server_time`.
- [x] `server_id` survives a restore. A restore or reset rotates only `epoch`.
- [x] Feed rows are topics, versions (with `topic_id`) and entries. `deleted[]` items are
      `{kind: entry|topic|version, id, topic_id}`.
- [x] `revision` exists on entries and topics, starts at 1 and only ever increases. It is returned by
      POST, PATCH, archive and unarchive.
- [x] Deleting a topic writes the topic, its entries and its versions to `deleted_ids`. An incremental page emits only the topic deletion, and clients cascade it locally. A bootstrap emits each child deletion. This matches sync F3.
- [x] The backfill emits topics, then versions, then entries.
- [x] Error codes:
  - 409 `entry_deleted`: POST reuses a deleted id;
  - 409 `stale_revision`: `expected_revision` doesn't match;
  - 404: PATCH or GET of a deleted entry;
  - 204: DELETE of an id that is absent or already deleted.
- [x] The `X-QuickR-Server-Id` header is on every `/api/v1` response, including errors and
      `/health`.
- [ ] (M3) `due_since` in push payloads is UTC truncated to whole seconds.
- [ ] (M3) `quicklog-vectors.json` gains category-id cases, so Python and Swift produce identical
      `quickr.t.{id}.{hash}`.

### Backlog from M0 reviews (non-blocking)

- [ ] Feed: an ASGI disconnect/send-error test proving the CSV snapshot transaction closes and the connection is returned; a >500-row CSV with a mutation between pages.
- [ ] Feed: a dedicated regression test for the commit-time retry in `@writer`.
- [ ] Specs/fixtures: `quicklog-vectors.json` gains category-id cases (M3).
- [ ] Scaffold: confirm on the first real CI run that Xcode 26.6 honours `ios/QuickrKit/Package.resolved` (verified locally on 27.1 only). When GRDB lands in M1, run `make ios-resolve` and commit the lockfile.

### M0 integration and PR

- [x] All WPs merged (vectors, specs, feed, scaffold). Integrated gates green: `make check` (401 pytest, 532 vitest), plus `alembic upgrade head && alembic check` run separately on a fresh DB and `make check-ios` (iOS 26.0 + 27.0).
- [ ] Concurrency, feed and downgrade tests listed in the PR
- [x] Codex review of the whole milestone diff (BLOCK: 2 Majors, fixed over 2 rounds) and a Claude reviewer (SHIP WITH MINORS, fixed)
- [ ] PR body: the validation checklist, and test reports instead of media (a
      stated deviation)
- [x] PR [#8](https://github.com/Richard-Lynch/quickr/pull/8): CI green (backend, frontend, docker, and the **first iOS job**: build + Unit plan on Xcode 26.6 / iOS 26.2 in 3m32s). Squash-merged into `feat/ios-app` as 6249b0e, 2026-10-17 17:10.
- [x] STATUS updated; M1 branch `ios/m1-data` cut (stacked) and synced with `feat/ios-app` by merge

## M1: Core and data layer, plus platform proof · needs H1, H2

Branch `ios/m1-data` (stacked on `ios/m0-foundations`). WPs per [DAG.md](DAG.md).

| Wave | WP                                                                | Branch         | Status       |
| ---- | ----------------------------------------------------------------- | -------------- | ------------ |
| W1   | C1 contracts (models, DTOs, schema, protocols, TestSupport, GRDB) | `ios/m1-c1`    | [~] running  |
| W1   | DS design system (lands with M2)                                  | `ios/m1-ds`    | [~] running  |
| W1   | B6 APNs backend, dark                                             | `ios/m1-b6`    | [~] running  |
| W1   | TOOLS integration harness and fault proxy                         | `ios/m1-tools` | [~] running  |
| W2   | STORE · API · DUE · VAL                                           | —              | [ ] after C1 |
| W3   | OUTBOX · SYNC · SKEL · B7                                         | —              | [ ]          |
| W4   | MP · INT · SPIKE · FORM (M2)                                      | —              | [ ]          |

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

- 2026-10-17: WP vectors done and gate green. Findings to carry into the Swift due port: DST gaps can merge slots, slots must be sorted by UTC instant, the early window can be tiny, `next_due_at` ignores `schedule_since`.
- 2026-10-17: Plan v3 finalised (PR #6). Notebook merged to `main` (PR #7).
  macOS upgraded to 27.0.1. MobileBuildMCP configured. M0 started with 3
  sub-agents.
