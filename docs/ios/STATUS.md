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

**Last updated:** 2026-10-19 21:00 EDT. **M1 merged** into `feat/ios-app` (#9, 48fa566). M2 is in progress on `ios/m2-ui`, starting with WIRE.

**Execution plan:** [DAG.md](DAG.md) (Fable). Waves of ≤4 WPs with at most 2 simulator-heavy at once. Milestones are stacked (squash-merge, then `rebase --onto`).

## Now

|                     |                                                                                                                                                                |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Active milestone    | **M1** on `ios/m1-data`. M0 merged (#8, 6249b0e).                                                                                                              |
| Running             | Cap raised to **6 agents** (simulator-heavy ≤2; Mac has 14 cores). STORE (last Codex fix: intent token), API, B7, SKEL (sim), OUTBOX, SYNC, PWA zod length fix |
| Waiting on the user | Apple enrollment activation and the Team ID; a session restart to load MobileBuildMCP                                                                          |
| Next up             | Wave 1 reviews (Codex) → merge C1 first → Wave 2: STORE, API, DUE, VAL                                                                                         |

## Human steps (PLAN §9)

- [x] H1: upgrade macOS. The Mac is on **macOS 27.0.1**, not Tahoe; Xcode 27
      supports it.
- [x] H2: install Xcode 27.x with `xcodes`. Installed Xcode 27.1 (27A9275) at `/Applications/Xcode-27.1.0.app`, selected, with Swift 6.4. (another agent is doing it), then run
      `xcode-select` and accept the licence. Report the install path.
- [~] H3: Apple Developer enrollment. Submitted 2026-10-17 (order W1832720362),
  awaiting activation. Then send the Team ID.
- [ ] H4: Xcode ▸ Settings ▸ Accounts sign-in. Needed after H3, before
      checkpoint D.
- [~] H5: phone is an **iPhone 16 Pro Max on iOS 26.6.2**. It has the Action button and Apple Intelligence (A18 Pro), so one-sentence Siri logging is available. Still to do: trust this Mac and turn on Developer Mode (after enrollment).
- [ ] H6: APNs `.p8` key, with its Key ID (M3).
- [ ] H7: App Store Connect app record and API key (M7).
- [ ] H8: Cloudflare tunnel, Access app and service token (M7).

## Open questions (PLAN §10)

Each one is answered for now with the default shown below, marked provisional.
The user can override any of them.

- [x] Q1: milestone PRs merge without waiting for review. **Yes.**
- [x] Q2: lock-screen logging without Face ID. **Yes, if it's clean.** Verified at checkpoint D.
- [x] Q3: Siri opens the record screen or runs Repeat-last for multi-question topics. **Yes, and better:** research `04-siri.md` shows multi-question topics CAN be logged by voice on iOS 26 (`LogTopicIntent`: field-by-field turns plus an interactive confirmation card; one-sentence parsing on Apple Intelligence phones). Plan and DAG updated.
- [x] Q4: **3 most-used + "More…"** (opens the app) for 5–6 options, with the truncation stated in the body.

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

- DeviceProbeTests.aStepWaitingForTheLockGivesUpAtTheDeadline asserts a wall-clock gap under 0.5 s and failed once in the parallel core run (it passed alone and on a rerun). It is load-sensitive: give it a bounded or injected clock, or gate it with TimingTests.
- A11Y L5 (answers): the answer values in Entries rows keep `lineLimit(2)` at AX sizes (UIT-6's Grid change left them as they were); lift it at AX sizes.
- A11Y C1: check "Export CSV" at XXXL now that slice A's X3 lets capsule buttons wrap; close it if it's fine.
- A11Y L2 (Low): a day rotor for the long, date-ordered Entries list.
- A11Y H3: home tile reading order. The open button sits behind the content with no sort priority; give it `accessibilitySortPriority` so the combined title element is read before the quick-log controls (TileView.swift).
- A11Y T5: at AX XXXL the toast's single HStack (text, Undo, ✕) squeezes the text column; stack the actions under the text at AX sizes (ToastView.swift).
- A11Y SE6: each licence is one huge Text element; split it into paragraphs so VoiceOver can move through it (LicencesView.swift).
- A11Y SE2: on the device, check that VoiceOver's escape gesture does nothing on the Cloudflare token sheet while a secret is typed, and that leaving through Cancel keeps no secret (DEVICE-DAY §6, "The token sheet keeps no secret").
- A11Y: the Home due-pulse doesn't stop if Reduce Motion is switched on mid-animation; stop or restart it when the setting changes (HomeView.swift).
- UIT-6 stall (not reproduced): once, on iOS 27 under load from other simulators, the app never went idle on the record screen just after a topic was created. Every XCUITest action waited out the 120 s "wait for app to idle" ("App animations complete notification not received", 4×), so TopicLifecycleUITests overran its 5 min allowance; the screen looked static. Not reproduced in 6 further runs (test times 102–129 s), with the app's log stream and periodic `sample` showing nothing stuck. Ruled out: the A11Y shared code (not in that build), PerfProbe (passive), and the full keyboard on the int field (by design: no minimum means negatives are allowed). If it recurs, sample the app during the stall and check the record screen's `.task`s and any repeating animation.
- Tooling: `make ios-uitest-e2e` doesn't pass the IOS_SIM_DEFAULTED marker, so a plain run picks the shared base device rather than the worktree clone (it still counts toward the cap). Extend simcap's per-target defaulting to it.
- LIST flake: EntriesTests.testAccessibilityXXXL. The swipe-Delete button can land under the home indicator in the full-plan layout (it passes alone 2/2; seen by TOPIC).
- Tooling: xcodebuild sometimes hangs after the tests finish (seen by TOPIC); the watchdog kills it once the results are written. Investigate the 60 s post-final-line deadline.
- TOPIC: details and schedule PATCHes send no expected_revision (PWA parity), so a concurrent edit elsewhere is overwritten. Consider optimistic concurrency on both clients.
- A11Y: at AX XXXL, the topic tabs (LIST's segmented Overview/Entries/Versions control) stay small while the rest of the screen grows. Use a scaled custom tab bar, or a menu/picker at AX sizes (found by STATS).
- REG: add push-activation tests for several consecutive foreground trips, and a quick return before startup finishes, with expiry around it (Codex r4 coverage note).
- Both clients: a prefilled number field (the min-0 prefill or the last value) keeps the caret where it was tapped, so typing "3" gives "30". Select all on the first focus of a pristine prefill, or clear a pristine min-0 prefill when typing starts. PWA: AnswerField.tsx NumberInput, quickLog.ts initialNumber. iOS: QuickLog.initialText and AnswerField. Tap counts are unchanged. (Found by UIT-2.)
- SYNC-UX: add a deterministic test for repeated background/foreground cycles during a held startup (Codex r4 note; the expiry-first ordering is covered by activationWhileAnExpiredStartUnwindsConnects).
- **D checkpoint (device):** measure how many notification categories iOS keeps; CAT's registry is append-only per §5.1 and Apple documents no limit.
- `ios/scripts/test.sh` should run gen.sh, or detect a stale xcodeproj, before building (RECORD hit a stale project after deleting files).
- RECORD/forms: limits (text lengths etc.) come from built-in server defaults until something fetches the server's limits; fetch and cache them per server (found by RECORD).
- HOME: consider a plain VStack at every size (the PWA renders every row); today LazyVStack is kept at non-AX sizes (TILES's layout-loop fix).
- Backend + clients: topic name sort is byte-order in practice (postgres:18-alpine/musl ignores en_US.utf8 for lower(name)), so "zed" sorts before "éclair". Switch to an ICU collation (e.g. `und-x-icu`) in Postgres, then regenerate home-vectors and update the iOS comparator and the PWA together (found by HOME).
- PWA: real-browser e2e harness (Playwright, Chromium with service workers) for the B8 notification actions: real notification UI and `maxActions`, event lifetimes, Background Sync retries, auth-proxy redirects. The simulated SW harness covers the logic only.
- **M3 HANDLER:** action-originated `entry.create` must use the shared name-based id from (server_id, topic_id, due_since), per the §7.1 amendment coming with B8, with shared vectors, so iOS and PWA actions on the same reminder dedupe server-side.
- M3 (from Codex's M1 milestone review): Swift category-id generation verified against shared vectors (notifications.md:255 MUST); `NotificationCenterProtocol` can't represent B7's `open` action (NotificationCenterProtocol.swift:63); N1/N3/N5–N15 coverage; production category reconciliation, action validation, badge/dedupe, token lifecycle.
- M1 review backlog: one pool per (server, gen) per process (StorePartitions.swift:221 opens a new pool on every open); write façade (enqueue plus requestFlush); dead StoreLink probes and empty service protocols removed by WIRE; widget intents on placeholder topics until M4; coalesce per-call Tasks in `handle(_:)`/`requestFlush` bursts. All are folded into WIRE where they apply.
- STORE test: `LeaseTimeSamplingTests` sleeps 50 ms assuming a writer is already waiting; under load it passes but proves less. Replace the sleep with a barrier (found by FLAKE).
- **Milestone checklist item (from SKEL):** before every milestone PR that touches intents or widgets, run `ios/scripts/widget-proof.sh` on an iOS 26.0 clone first, then on 27; and run the Intents plan locally on 27 via check-ios. CI (iOS 26.x, Unit plan) only covers the `IntentMetadataTests` guard. Add the same requirement to the WIDGETS and INTENTS done-criteria.
- App composition root (SKEL follow-up / M2 SYNC-UX): wire `Outbox(onSignal: coordinator.handle)` and `OutboxFlushBridge.bind(scheduler)` on every store open, reset and server switch (nil when there's no store), per INT.
- S10 (APNs register vs a rotated epoch): done in M3, `PushIntegrationTests` (INT, real backend).
- DS: NumberStepper's fixed 52 pt trailing unit padding lets the value touch the unit at AX XXXL ("30min"); use @ScaledMetric (found by FORM).
- CAT: point MP's N4 test (SyncMP.n4) at the real category `register` once it exists; for now the agent runs the §5.2 procedure itself.
- RECORD: at accessibility text sizes with the keyboard up, the sticky Save bar covers much of the form; consider hiding it while the keyboard is visible (found by FORM).
- xcodebuild occasionally hangs after the tests finish (seen by FORM): add a timeout/watchdog to `ios/scripts` test runs and a CI step timeout.
- PWA parity bugs found by BUILDER (server is authoritative; fix the PWA to match): slugify (server drops non-ASCII after NFKD, falls back to `topic`; PWA gives `stra-e`/empty); duplicate-label check (server `casefold`, PWA `toLocaleLowerCase`); whitespace strip (pydantic Unicode White_Space vs JS `trim`, e.g. U+FEFF). Use `shared/fixtures/builder-vectors.json` in the PWA tests.
- [ ] Feed: an ASGI disconnect/send-error test proving the CSV snapshot transaction closes and the connection is returned; a >500-row CSV with a mutation between pages.
- [ ] Feed: a dedicated regression test for the commit-time retry in `@writer`.
- [ ] Specs/fixtures: `quicklog-vectors.json` gains category-id cases (M3).
- [ ] App integration (SKEL/SYNC-UX): post GRDB suspension notifications on app background/foreground (`Database.suspendNotification` / `resumeNotification`) in the app and extensions, the 0xDEAD10CC guard (from the STORE review).
- [ ] NSE links QuickrData, so it also carries App Intents metadata (from SKEL). Harmless for now. If duplicate-metadata warnings or resolution issues appear, split intents into a `QuickrIntents` package target linked only by the app and widget.
- [~] Backend test isolation (`ios/m1-testiso`): advisory locks ARE per-database (verified), so there's no deployment hazard. The cross-talk is the tests' `pg_locks` queries not filtering by database, plus wall-clock APNs budget tests. Fixing the tests only.
- [ ] Registry can't update a known server's `base_url`: connecting to the same `server_id` at a new URL keeps the stored URL. Needed when hosting moves behind Cloudflare (M7) or the LAN address changes (from SYNC).
- [ ] Backend: reject NUL in every text field the API stores (notes, source, labels, names…) with a 422 Problem instead of a Postgres 500. Today only str answers are checked (found by VAL).
- [x] ~~PWA zod UTF-16 lengths~~: not a bug. zod 4.6.7 counts code points. Regression tests merged (b760fdf) so that a zod or generator change back to UTF-16 counting is caught.
- [ ] Notifications WP: a fake-center orchestration test for ReminderDedup L1 (pending local cancel) and L2 (suppression/activation cleanup), from the C1 review.
- [ ] TILES (M2): at accessibility text sizes, badges and the sync pill truncate and the tile stays side by side. Consider a stacked tile layout at AX sizes (from DS).
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

| Wave | WP                                                                                                                                                                                                                                      | Branch         | Status                                                                                                                                                                                                                                |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| W1   | C1 contracts (models, DTOs, schema, protocols, TestSupport, GRDB)                                                                                                                                                                       | `ios/m1-c1`    | [x] **Merged** (77d0e72) after 2 Codex rounds. Minor deferred: a dedup orchestration test (notifications WP).                                                                                                                         |
| W1   | DS design system (lands with M2)                                                                                                                                                                                                        | `ios/m1-ds`    | [x] **Merged** (6a579a4 + integration d6f367b: QuickrDesignTests, Resources/AppIcon, DEBUG catalogue hook). check-ios green on iOS 26.0 + 27.0.                                                                                       |
| W1   | B6 APNs backend, dark                                                                                                                                                                                                                   | `ios/m1-b6`    | [x] **Merged** (4b398b9) after 4 Codex rounds (lifespan order, delivery deadline, token log redaction, sandbox config, slot-progress table against starvation, TTL only for abandoned slots). 494 pytest.                             |
| W1   | TOOLS integration harness and fault proxy                                                                                                                                                                                               | `ios/m1-tools` | [x] **Merged** (6205724) after 4 Codex rounds (HTTP framing, hop-by-hop, control validation, docker-assigned ports, startup cleanup, kernel-lock sim-clone). Smoke 12/12 on the merged branch; 2 wording/error minors as a follow-up. |
| W2   | [x] **Complete:** DUE, VAL, STORE and **API merged** (API after 2 Codex rounds: per-header identity checks, precondition evidence, trusted bodies, load-tolerant transport tests). Gates: 182 Swift data tests, 627 pytest, 726 vitest. | —              | [x]                                                                                                                                                                                                                                   |
| W3   | **B7 merged** (bb4729a). OUTBOX+SYNC (b69bb6a), testiso (07b489e), SKEL (2891f06) merged after Codex rounds; FORM (M2) done on `ios/m2-form` (1f731f8)                                                                                  | —              | [x]                                                                                                                                                                                                                                   |
| W4   | MP (85ae3b0), INT (0681189), SPIKE (289fc2f), WATCHDOG, FLAKE (065aa9f), M1-FIXES (01cba48) merged; gate evidence (183ec1a)                                                                                                             | —              | [x]                                                                                                                                                                                                                                   |

- [x] QuickrCore: models, validation, quick-log, and the due port (all vectors
      pass)
- [x] QuickrData: the API client (fixtures and request goldens), the two-layer
      GRDB store, the sync engine, and the outbox (spec matrix)
- [x] B5 request goldens validated by pytest
- [x] Multi-process subprocess tests (24 cases): concurrent writers, migrating while others
      are connected, a process killed holding the lock, lock takeover
- [x] App skeleton: App Intents resolve from the app and the widget
- [x] Simulator spike: notification actions with the app killed. Findings
      recorded.
- [x] `make ios-integration`, all 5 scenarios (S1; offline→flush; 17/18; 12/51/59; S9/38), 2/2 at 15/15
- [x] `ios.yml` green (after the NSE compiler-crash, pool-starvation and timing-isolation fixes)
- [x] Codex and Claude reviews done (both MERGE AFTER FIXES → fixed); PR #9 with test reports, merged 48fa566

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
- [ ] Device checks: logging with the app killed and offline, the Action button, Siri; **a 3-question topic by voice while offline; editing and confirming in the Siri card; the one-sentence path on an Apple Intelligence phone**; multi-process soak
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

- 2026-10-21 06:15 (EDT): **WIDGET-SKEW merged** (04bbd9a): widget due state and order use server time (device time plus skew_ms); timeline transitions map back to device time; the fingerprint includes the skew; skew-only pulls reload the timelines; PushLifecycleTests are isolated. Unit 1043/0 on 26; Codex r1–r2 resolved. run_limited (limit.pl process-group supervisor) is merged via ios/m3-media (43e7618). **Last two WPs before the M3 PR:** APP-SKEW (m2-form: Home and topic due state on server time, the same §10 gap in the app) and SIMINFRA (m1-testiso: shutdown traps and unique result dirs).

- 2026-10-21 06:00 (EDT): **ROUTE-SCOPE merged** (3a455bf; Codex r1–r4 resolved). Reminder and widget links carry the topic id plus the server or store scope. LinkScope refuses another registered server ("Can't open that here", naming it), refuses stale or unknown links and reloads the widgets, counts a reset in progress as busy, and bounds the cold-launch wait. Sims on 26: Links+WidgetViews 9/0, the Media widget test 1/0, and QuickRTests 81/0. WIDGET-SKEW: r2 resolved both Majors, with one ordering-test Minor left.

- 2026-10-21 05:45 (EDT): **S10 merged** (2a73596): the real-backend APNs register across an epoch rotation (409, then rebuild, then a 201 retry), integration 22/22 ×2; the obsolete stub is removed. ROUTE-SCOPE: links carry the topic id plus the server or store scope, and LinkScope refuses another registered server (never switches) and refuses a stale or unknown one, which reloads the widgets. Spec §7.5. Codex r1's Majors are fixed; r2 and the sim runs (Unit, Links, WidgetViews, the Media widget test, plus a refusal-alert UI test) are in progress. WIDGET-SKEW: r1's 2 Majors are fixed; r2 and Unit are running. Infra traps: the run_limited process-group helper is done (Codex r2); the test.sh/perf traps and unique result dirs are next.

- 2026-10-21 05:30 (EDT): The slice C picker valueLabel is merged (b6f7bac). ROUTE-SCOPE (c7db3fc), WIDGET-SKEW (c9e2565) and S10 (510132d) are in progress with commits. The sim-trap infra fixes haven't started yet (chased).

- 2026-10-21 05:20 (EDT): Milestone fixes A merged (ce2f904; Codex approved with minors, both fixed). The CF manual check feeds the headers through `curl --config -` (no secret in argv); the MCP `--header` step warns where the secret lands; the a11y-audit E1 entry is resolved; DEVICE-DAY §6 has the SE2 token-sheet item.

- 2026-10-21 05:10 (EDT): **The HANDLER-RESUME end-to-end test passes** (Media plan 3/0 on 26: the same app process scheduled the reminder and logged the action). RELTEST is merged (55b08df, `make ios-release-test-build`). **M3 milestone Codex review** (4 areas, on 42499bf):
  - Notifications: REQUEST CHANGES.
  - Intents and widgets: REQUEST CHANGES.
  - A11Y: APPROVE WITH MINORS.
  - Infra: REQUEST CHANGES.
  - No Blockers. Six Majors, being fixed in parallel:
    - **ROUTE-SCOPE** (m1-sync): notification body and More… taps, and cached widget links, lose server provenance, so a same-slug topic on another server opens or saves.
    - **WIDGET-SKEW** (m2-form): widget due state ignores the stored clock skew.
    - **Sim traps** (m1-testiso): test.sh and perf-cold-start boot clones with no shutdown trap.
    - **CF docs** (m1-review): the curl check exposes the secret in `ps`.
  - Minors: picker valueLabel in slice C (m1-skel), the PushLifecycleTests category center (m2-form), unique result bundles (m1-testiso), A11Y doc and DEVICE-DAY fixes (m1-review), and the S10 integration test (m6-builder).

- 2026-10-21 04:50 (EDT): **A11Y slice C merged (360e66d). A11Y is complete:** A, B, C, Lows and widgets are all on ios/m3. C covers Topics, Schedule, Builder and Versions (TP1–6, BD1–8); full audits at each screen's top, element-scoped mid-list, with the manual XXXL check in DEVICE-DAY §6. Topic+Builder+Lifecycle 17/0 with B merged; Codex r1–r3 resolved. **The Reduce Motion lint is now strict by default** (47edc15). On the merge: lint, core, script tests and the app build are green. **The M3 milestone Codex review starts now**, in parallel with the small tails (RELTEST make target, widget-proof process-group fix, the notification E2E on ios/m3).

- 2026-10-21 04:40 (EDT): RELTEST: three QuickrUI test files drop `@testable` (84d2e26, Codex approved). QuickrDataTests' 19 `@testable` files can't build with plain `swift build -c release --build-tests`, so the release check uses `swift test -c release` or `-enable-testing` through a new make target. A11Y C's final result and the notification E2E on ios/m3 are pending.

- 2026-10-21 04:25 (EDT): **Merged MEDIA, CATCAP and HANDLER-RESUME into ios/m3.**
  - MEDIA: DEBUG hooks (`-QuickrDemoNotify` built from the shared apns payload vectors, `-QuickrDemoShared`, `-QuickrSnippetGallery`) and an opt-in Media plan. Demo server ids are now UUIDs.
  - CATCAP: registry v3; a capped (90), prioritised registration set (push_seq first, then due within 7 days, then delivered, then used); the app prunes and the NSE only adds and evicts; registration-generation checks in refresh and reconcile. Codex r1–r4 resolved.
  - HANDLER-RESUME: AppSession's counted store hold (with an epoch on expiry) is used by notification responses, in-app intents and widget buttons. A real-suspension lifecycle test is added; Unit 990/0 on 26.
  - Semantic conflict: MEDIA's DemoNotify called the pre-CATCAP `rows(in:)`, fixed in a follow-up commit.
  - On the merge: lint, core (781+217+187+21), the lifecycle suite, the app build and build-for-testing of every target are green; MEDIA's merge also passed make check and the vectors.
  - The notification end-to-end test (Media plan) against the fix is pending (m1-testiso).

- 2026-10-21 04:10 (EDT): **CATCAP Codex r4: no Blocker or Major** (one spec wording Minor being fixed); it merges next. **HANDLER-RESUME Codex r2 clean.** A process-wide hold resumes GRDB for notification, intent and widget responses and re-suspends afterwards, with epoch and generation guards; the Unit run and the Media end-to-end proof follow. A11Y C: 17/17 on fbf37eb, rerunning on db8b014 with slice B merged.

- 2026-10-21 03:55 (EDT): CATCAP Codex r3 resolved r2; its 1 new Major (the same stale-answer race in reconcile) is fixed in cb97ece; r4 is running. HANDLER-RESUME is committed (244b283) and MEDIA is updated (f013ce9). A11Y C's final run is on fbf37eb.

- 2026-10-21 03:40 (EDT): **A11Y slice B merged** (9af89e6). It covers topic tabs, Entries (long-press Delete fixes the XXXL flake), Edit, Export, Stats charts (AXChartDescriptor with the year in bucket names, scaled heights), the FormSaveBar below content (F8) and the picker valueLabel. Every B audit allow-list is empty. Codex r4 is clean. Stats 4/4; the full UI run gave 82/1 before the Stats-only fix. On the merge: lint, core and the app build are green, and the vectors show no drift. A11Y C is on its final run (fbf37eb); mid-list audits are element-scoped only (a full-list audit re-lays out the List), and the manual check is in DEVICE-DAY §6.

- 2026-10-21 03:25 (EDT): **Real HANDLER bug found by the MEDIA proof run:** a notification action tapped while the app is alive but backgrounded fails with `refused: storeUnavailable`. `didEnterBackground` suspends the GRDB store, and the action path never resumes it; a killed app starts unsuspended, which is why spike F3/D3 and the tests missed it. This is the common case on a phone. WP **HANDLER-RESUME** (m2-form): resume for the response, re-suspend while still backgrounded, a shared helper for every in-process background entry point, and a hosted regression test. MEDIA is committed (936f334): the snippet and widget-log GIF hooks are proven; the notification capture fails on this bug by design (opt-in Media plan). CATCAP r2's Majors are fixed (push_seq ordering, must-include, a registration generation checked under the lock); r3 is running.

- 2026-10-21 03:10 (EDT): A11Y B full UI (1d4caa7, with A and UIT-6) gave 82/1/20. The failure was its own ST4 change hiding on-screen histogram text; it's fixed in ae91301 and a Stats rerun is going. A11Y C full run (6341e7c) gave 15/17; both are fixed in a090676 (+Time as our own text, a false-positive mid-list audit removed). Codex r2 found 1 Minor (narrow the Min/Max audit after scrolling the fields fully into view). Its final run is going. CATCAP Codex r2 left 2 Majors: wall-clock push ordering (clock rollback or ties can exclude the incoming push) and a refresh that reads the installed snapshot outside the lock (a missed registration). Fixing: a monotonic push sequence plus must-include, and validation inside the lock. MEDIA: proof runs are visible in the scratchpad, but nothing is committed after 2 h and there's no reply.

- 2026-10-21 02:55 (EDT): **suspend-iso merged** (3c4331e; Codex: no findings). On iOS 26 the full Unit plan, run in parallel, gave 956/0/27, and QuickrLifecycleTests passes 2/2. **CATCAP:** r1's 3 Majors are fixed (pushed tier, bounded due window, refresh checks the system's actual set, monotonic times). The UPG v3 test is in: 650 rows reach v3, the first refresh registers exactly 90 and prunes the rest, and the outbox is untouched. The NSE never prunes: about 9 ms over 650 rows, with the app's prune about 11 ms. Pushed at 48b41c8; Codex r2 is running. A11Y B and C full runs are done; results pending. MEDIA: no commit or reply for about 75 minutes (chased).

- 2026-10-21 02:40 (EDT): CATCAP is implemented (189d87f): registrationCap = 90; selection by due within 7 days, then delivered, then used; prune after a 1-day grace; the reconcile compares against the capped set (no churn). The NSE registers its reminder as due now. D9 registers uncapped. Spec §5, D1, OQ5 and PLAN rule 16 are updated. Pending: the UPG v3 upgrade test, the NSE timing test at 650 rows, and Codex r2. A11Y C: the full Topic+Builder+Lifecycle run is going on 6341e7c. A11Y B: the full UI run is still going on 1d4caa7.

- 2026-10-21 02:25 (EDT): **CATCAP measured:** a year of one simulated user (12 topics) gives a never-pruned category union of 42 (day 7), 104 (day 30), 197 (day 90) and 644 (day 365), driven by number topics (each last value is a new id), while only about 10 are current. The work is registry v3 (current, due_at, used_at) and a capped, prioritised registration set (due within 7 days, then delivered, then recently used). The app prunes; the NSE only adds and evicts. The UPG test is extended for v3. A11Y B's full UI run on 1d4caa7 has empty allow-lists everywhere. A11Y C Codex r1: 0 Majors and 3 Minors (tests prove too little); fixes plus a full Topic+Builder+Lifecycle run follow. suspend-iso is queued for its simulator. MEDIA hooks are running their first sim check.

- 2026-10-21 02:20 (EDT): **UIT-6 merged** (1b00dd0; 27: 1/0; 26: UIT-6+Entries+Edit 19/0). **DPROBE merged** (ca77bce; the AppEnvironment conflict with the categoryCenter parameter resolved by keeping both). It adds `aps-environment: development` on the app target only (export re-signs to production through the distribution profile; the README has a one-time check), and the DEBUG-only D8/D9 probe (DeviceProbe, `-QuickrDProbe d8|d9`, results in the App Group, `dprobe-summary.py`). It compiles out of Release (0 symbols). Codex needed 6 rounds. **New finding: on the iOS 26 simulator, `notificationCategories()` reads back at most 100 categories** (100 of 150, 1,000 and 5,000). If the device caps the same way, §5's append-only full-union registration loses actions past about 100 categories, and §5.3's reconcile re-registers on every activation. Spec note plus a capacity-bounded registration WP (CATCAP) started; D9 on the device confirms. On the merge: lint, core, script tests and the app build are green.

- 2026-10-21 02:10 (EDT): **A11Y widgets merged** (added2e; WidgetViewsUITests 3/0 and Intents 6/0 on 27). A11Y B: Codex r3 clean (09ee928); it's being rebased onto ios/m3 with A so one full UI run validates both, and H4/F9 is already fixed by A. The M3 milestone Codex review is prepared: 4 parallel area reviews, plus a runner script that uses a detached worktree at origin/ios/m3. MEDIA hooks are building. DPROBE has a new commit (56564e7).

- 2026-10-21 01:55 (EDT): Remaining before the M3 PR: A11Y B (bac3b5d, short rerun), A11Y C (full Topic+Builder run), A11Y widgets (queued), UIT-6 final (26 run going), suspend-iso (7aa59d1; sim run after UIT-6), DPROBE, and MEDIA (hooks under way). M3 milestone Codex review prompts are being prepared (m1-review). The PR body draft is in the scratchpad (m3-pr-body.md).

- 2026-10-21 01:40 (EDT): **A11Y slice A merged into ios/m3.** It covers Home, tiles, Record and Form, toasts (VoiceOver persistence, magic tap through AppDelegate plus a toast-level fallback), Sync, onboarding (the address wraps at AX sizes) and Settings, with the shared error focus and announce, 7 XXXL audit tests and a Reduce Motion launch test. Final runs: Unit 957/1 (WidgetReloader: test isolation, fixed separately on ios/m3-suspend-iso) and UI 80/2 (both fixed; rerun 16/16 with empty allow-lists). Codex r1–r3 resolved. On the merge: lint and core are green, and the app builds. The WidgetReloader "Database is suspended" failure was a **test-isolation** problem: hosted SyncControllerTests posted GRDB's process-wide suspend. Fix: a private NotificationCenter, plus a gated, serialized real-suspension E2E test (QuickrLifecycleTests, already a separate CI step). A11Y B run 3 gave 44/45; the last failure is a genuine 2 pt clip, fixed in bac3b5d.

- 2026-10-21 01:25 (EDT): **SIMFIFO merged** (db0775a): ticketed FIFO admission to the simulator slots, with dead and reused-pid tickets pruned and the caller's traps preserved. Codex approved at r4, and sim-cap-test passes. UIT-6's stall was **not reproduced** in 4 hunt runs (1 in 7 overall, under load); it's going to the backlog, and the final runs are on 0ad94d8. A11Y A's final run: Unit 957/1/27, UI 80/2/20. Its 2 UI failures are fixed, and the E1 allow-list entry is removed because the F8 fix cleared it. The Unit failure is **WidgetReloaderTests "Database is suspended"** in the full plan; m2-form is investigating whether it's order-dependent or a write-after-suspend bug. M3 PR prep is under way (m1-testiso). A11Y C is at 414ecc2.

- 2026-10-21 01:10 (EDT): **F8 fixed (A11Y B, approved by A):** FormSaveBar lays the bar out below the form (VStack, opaque background) instead of floating over it, so content is no longer covered at XXXL. Bar height, the toast offsets and the keyboard-toolbar handoff are unchanged. A's E1 allow-list entry may now fail as "no longer occurs"; whichever slice merges second removes it. UIT-6 stall hunt: round 1 passed (129 s, samples clean); rounds 2–4 are running. If it isn't reproduced, UIT-6 merges and the stall goes to the backlog with the evidence. SIMFIFO is progressing (081386f). A11Y A's final run is in progress.

- 2026-10-21 00:55 (EDT): A11Y A: Codex r2's 2 Majors are fixed (form focus requests are fixed-destination and one-off; a paste no longer connects). The r3 residual (pasting the identical address plus a newline counts as Return) is **accepted**: it connects to what Go would. The final Unit+UI run is on 7e868de. A11Y B: run 2 gave 39/40. The Stats XXXL audit is clean, and L1 (long-press Delete) fixes the EntriesTests flake. The failure is real: the **floating Save bar covers content at XXXL** (Edit; Record and Form are being checked, backlog F8), so the content gets inset rather than the audit scrolled. Codex r1 had 1 Major (chart buckets need the year), fixed. A11Y widgets (W1 etc.) is on ios/m3-a11y-widgets with Codex r1 fixed; a combined WidgetViewsUITests plus Intents run is queued. DPROBE is progressing (1cf4680).

- 2026-10-21 00:50 (EDT): **WIDGETS merged into ios/m3** (044bc26; Unit 11/0 and WidgetViewsUITests 3/0 on 27). **All M3/M4 feature code is now on ios/m3.** **A11Y Lows (N1 and the snippet) merged:** notification number actions read "Log 72 kg" across backend, PWA, vectors and iOS. Category ids changed; old "✓" categories still log or open (host tests). On the merge: lint and core are green, backend 709, frontend 856. W1 and the widget buttons are next (m1-sync).

- 2026-10-21 00:40 (EDT): **ios/m3 c386b2e is green on iOS 26.2** (CI parity): Unit 5002/0/28, UI 78/0/20. BuilderUITests pass, which confirms the Builder fix, and the post-test silence didn't recur. A11Y A: the 4 XXXL audit issues are fixed or allow-listed with reasons (number field stacks; server address wraps at AX sizes with Return still connecting; the Record details line waits for B's E1; the system Done button). Codex r1 had 3 Majors (focus replays, a stale push-test result, Log another focus), fixed in 933ee2a; r2 is in. Simulator-slot priority went to WIDGETS by holding the A11Y runs; SIMFIFO is in progress (d3e47f6). The UIT-6 stall hunt now has a slot.

- 2026-10-21 00:25 (EDT): **The 2-slot simulator cap is the bottleneck.** Six WPs are queueing, and `sim_boot`'s 15 s polling isn't FIFO (WIDGETS has waited about 30 minutes while later runs got in). WP SIMFIFO (m1-testiso) adds ticketed FIFO admission. A11Y A: the first run found the magic tap never installed (SwiftUI ignores NSPrincipalClass); it's now AppDelegate's `accessibilityPerformMagicTap` plus a toast-level `.magicTap` fallback, both on the device list. The XXXL audits flagged clipping on Record, Form and onboarding and partial Dynamic Type on Sync; assertAccessible now names the element. A11Y B: QuickrSegmentedPicker gets a `valueLabel` for the menu form. A11Y Lows: N1 is committed and passes the vectors and old-category-fallback checks; Codex r3 is running.

- 2026-10-21 00:10 (EDT): UIT-6's stall is under a bounded investigation. The A11Y shared code is ruled out (not in 75dd47a), and the full keyboard is by design (negatives allowed, and the number pads have no minus key). A11Y B found the menu picker exposes an empty value at AX sizes; the fix goes in the picker, not the test. A11Y C is written (TP1–TP6, BD1–BD8) and its first run is on 27. A11Y Lows: the snippet a11y is committed; N1 "✓ 72 kg" becomes "Log 72 kg" across backend, PWA, vectors and iOS (category ids change). The 26.2 Unit+UI run is on c386b2e. Load peaked at about 60 with every agent on the simulators.

- 2026-10-20 23:55 (EDT): **INTENTS merged into ios/m3** (171d34f; Codex r3 clean). The per-topic Shortcuts tile check is deferred to M4-DEV; the harness skips as inconclusive. **Builder fix merged** (2fd9e0b; BuilderUITests 5/0 on 27 ×3 and on 26). WIDGETS is synced with ios/m3 (cb2a049) and its 27 run is queued. UIT-6: 2 of 3 rounds green on 27; round 3 hit XCUITest's 120 s wait-for-idle ("App animations complete notification not received") on the record screen, and the int field showed the full keyboard. Investigating whether the A11Y shared code loops, no retries added. A11Y A, B and C are all in progress; m1-sync has the Lows outside the slices (W1, N1, the snippet). DPROBE (aps-environment plus the D8/D9 probe) is in progress.

- 2026-10-20 23:50 (EDT): **Device day merged** (484c23c, 523705e): `docs/ios/demo/DEVICE-DAY.md` (prerequisites, D, M3-DEV, M4-DEV with the W9 Shortcuts tile, VoiceOver checks, an agent-vs-user map, the M7 regression list) and `make ios-device-run` (signed Debug, devicectl install and launch, device identifiers filtered; device-run-test passes, 9/9 mutations caught). Codex r1–r3 resolved. **Gaps found:** no `aps-environment` entitlement (no APNs token), and D8/D9 need a DEBUG probe; both are now WP DPROBE (m6-builder). UIT-6's "Glasse" failure was the Builder binding bug, not a flake; the retype workaround was rejected, and UIT-6 now runs on the Builder fix. A11Y A WIP is pushed (e4567b5; magic tap through a UIApplication subclass, the error-focus call sites, 7 XXXL audit tests, a Reduce Motion test); its run is queued. The combined ios/m3 builds for iOS 26.2.

- 2026-10-20 23:35 (EDT): **A11Y shared code merged** (87d368e). App/ phase split three ways: A (m1-review, started), B (m1-outbox, started on Stats, Export and tabs; Entries after UIT-6), C (m1-skel, after the Builder fix). INTENTS step 3 **Codex r3 clean** (edd166b); Intents 6/0 on 27, Unit 922/0 on 26. The Shortcuts per-topic tile can't be started on the simulator, so it's made an explicit skip and moved to M4-DEV. Builder typing fix at f5acdcf (live-by-id bindings; Codex r1 has 1 Minor). UIT-6 found a fake-server gap (create didn't feed v1; 7a552f6). **iOS 26.2 baseline:** Unit 4971/0/24 on c875fc4, but xcodebuild was silent for about 9.5 min after the tests exited (the known post-test hang; it would trip CI's 5 min watchdog if it happens on Xcode 26.6). UI on 26.2 is running. Device-day guide is at 6bc0bf9 (Codex r1 fixes).

- 2026-10-20 23:25 (EDT): **PERF+UPG merged into ios/m3** (ccd27ba; Makefile conflict with TF resolved by keeping both target sets). On the merge: lint, core and script tests are green. PERF's last run on d813106: UI 77/1/20 skipped and Unit green. The one failure is a **real BUILDER bug**: the question-label TextField binding reads a stale captured `question`, so under load typed characters are lost ("Glasses of w"). It's assigned as a separate fix.

- 2026-10-20 23:20 (EDT): **The iOS 26.2 runtime (23C54) is installed**; a CI-parity baseline on ios/m3 is next. UIT-6 Codex r2 is clean (0d8577d); merge once the simulator runs are green. INTENTS s3 r2 resolved 3 of 4. 1 Major is left: an evicted draft falls back to the original answers; it should throw expired. 1 Minor: the stuck-model test cooperates with cancellation. A11Y shared code is at 4a016cd; its Codex r1 is in. The App/ phase (about 3–3.5 agent-days) will be split three ways after the open branches merge. m6-builder is writing the device-day guide (ios/m3-devday).

- 2026-10-20 23:15 (EDT): **TF merged into ios/m3.** It adds `make ios-testflight` and `-dry-run`, with credentials from the env or the gitignored `ios/testflight.env`, IDs redacted, and output scrubbed before the watchdog writes it. Build numbers are UTC timestamps reserved atomically. `ITSAppUsesNonExemptEncryption = NO`. H7 needs an **Admin**-role ASC API key. Codex: r1 and r2 Majors fixed, r3 clean. testflight-test passes 23 checks; the real dry run archives. The A11Y audit list is on ios/m3-a11y (e01f06d, about 90 findings). Highs and Mediums are in scope; the shared helpers start now, and the App/ call sites wait for the open branches. UIT-6 found that entry rows didn't read their answers (AnswerGrid → Grid, 0f050ab). INTENTS step 3 r1 fixes are at 2031fba (FM 8 s deadline, undo bound to the committing store, multi-select drafts, Booleans); its Codex r2 and simulator chain are running.

- 2026-10-20 23:05 (EDT): TF r1 had 2 Majors (a `bash -x` credential leak, and the watchdog's raw logs before the scrub) and 1 Minor (build-number collisions), all fixed (0291718, 1ebab15). Codex r2 is running. `ITSAppUsesNonExemptEncryption = NO` is going in (only OS-provided TLS). UIT-6 r1 had 1 Major (the digit assertions match the date) and 1 Minor (v2 not proven); fixes are in progress. INTENTS step 3 Codex r1 is running; the Shortcuts harness rerun is on the iOS 27 clone. PERF's post-merge UI run is in progress. The A11Y audit has started (read-only). The iOS 26.2 download was retried with a 2 h bound (the first try hit our own 50 min timeout at 77 %).

- 2026-10-20 23:00 (EDT): **HOST merged into ios/m3.** It adds docs/hosting (backend, APNs `.p8` via the compose override, CF Access). The fault proxy has an `access` rule, and AccessIntegrationTests passes 21/21. ServerProbe treats a 3xx as `.notQuickr`, so the app asks for a token instead of saying it couldn't reach the server. Codex: r1 requested changes, r2 approved with minors, all fixed. Strict service-token mode is org-wide; confirm it's on during H8. On the merge: lint and core are green, and the proxy pytest passes 99. INTENTS step 3 is at 1a4f711 (Intents 11/0, Unit 916/0); its Codex r1 is running. TF is at 02b8040 (dry run validated; Codex r1 running). H7 needs an **Admin**-role ASC API key. UIT-6 is at 59332c9 and running on simulators.

- 2026-10-20 22:50 (EDT): **WIDGETS final run green** on c922320: Unit 11/0, UI 3/0. It is ready and merges after INTENTS. **PERF+UPG Codex r2 approved** (r1 fixed in 5f387ed; ios/m3 merged as d813106); its post-merge UI and Unit run is in progress. INTENTS step 2 is committed (85b5da8, Unit 908/0); step 3 (LogTopicIntent question loop, FM extraction, confirmation snippet) is written and running on simulators. New W11 packages started: UIT-6 (m2-form), HOST (m1-review, docs and the CF token e2e), TF (m6-builder; the script is dark until the Team ID and ASC key arrive). A11Y waits until no App WP is open. The iOS 26.2 runtime download ended without installing; checking.

- 2026-10-20 22:35 (EDT): Codex PERF+UPG r1: no Blockers. 1 Major: the PerfSeed tests don't compile in Release (`swift test -c release`). 1 Minor: the outbox ids in the seed are random. Fixes in progress. WIDGETS merged ios/m3 (c922320); its final run is pending. INTENTS merged ios/m3 (9f4aec5); step 3 is in progress. The iOS 26.2 runtime download is still running.

- 2026-10-20 22:20 (EDT): **M2 merged into feat/ios-app: PR #10, squash 21a6c2d.** CI was green on the final tip (backend, frontend, docker, swift test, build + Unit plan). Post-open fixes: an Xcode 26 compile error in a test, a CI starvation sweep plus a CI-only Swift Testing width cap of 4, and a stats tie-order backend bug. **STATUS now lives on `ios/m3`**, which has merged the final m2-ui and records the squash (ours-merge, trees equal; 3d651fa). M3 in progress: HANDLER and NSE are in; WIDGETS is approved (merges after INTENTS); INTENTS is on step 3; PERF+UPG is in Codex r1.

- 2026-10-20 21:25 (EDT): PR #10: the build + Unit plan job still fails on CI starvation in hosted suites (AppSessionTests, EntriesModelTests). A second sweep (ios/m2-ci-flakes2) covers every Unit-plan target and caps CI-only test parallelism. M3: **WIDGETS approved** (Codex r2; WidgetLogIntent pinned to its EntryScope, Control reloads, a no-prompt Control fallback, SQL counts); it merges after INTENTS. INTENTS step 2 (39f8cdb: repeat-last, open record, what's due, undo, App Shortcuts) is done; step 3 (LogTopicIntent) is next. PERF: a release-build cold-start breakdown (6902593).

- 2026-10-20 20:45 (EDT): PR #10 CI. Backend, frontend and docker pass. `swift test` is green after two fixes: an Xcode 26 region-isolation compile error in OutboxBridgeTests (f21d99c) and widened success bounds in case42 and LeaseTests (0fb7240, 1775654). The **build + Unit plan** job fails 6 CI-only tests: a Keychain -34018 in the unsigned CI build (SettingsTests), PushLifecycleTests, and LeaseTests/LeaseTimeSamplingTests (SQLite busy and short waits under starvation). A systematic CI-starvation sweep (ios/m2-ci-flakes, test-isolation agent; reproduces with 10 background-priority copies) is fixing all of them; it merges into m2-ui and then CI reruns.

- 2026-10-20 20:00 (EDT): The Intents test fix is merged (95c5db3; test-only; 2/2 ×2 on iOS 27). **The M2 PR is open: #10 (ios/m2-ui → feat/ios-app)**, with the final validation in its body. CI is running (backend, frontend, docker, swift test, build + Unit plan). The PR merges (squash) once CI is green.

- 2026-10-20 19:40 (EDT): Final M2 validation on 77c6924 is complete. Unit 844/0 and UI 78/0 on both 26.0 and 27. E2E 14/0 (3 demo skips). Integration 19/19 ×2. `make check`: backend 694, frontend 856. `make vectors`: no drift. Only the iOS 27 Intents plan (0/2) failed; its test-only fix on ios/m2-intents-fix is running twice on 27. The M2 PR opens once that's merged.

- 2026-10-20 19:25 (EDT): Final M2 validation on 77c6924: Unit 844/0 and UI 78/0 on both 26.0 and 27. **The Intents plan (iOS 27 only, AppIntentsTesting) fails 0/2**: SKEL-era tests assume the placeholder TopicEntity, which now reads the real (empty) store, and the LogEntryIntent test prompts for its topic (error 206). It hadn't run since M1, because earlier check-ios runs stopped before it. A minimal test-only fix is being made on ios/m2-intents-fix; it blocks the M2 PR. E2E, integration and `make check` are still running.

- 2026-10-20 18:25 (EDT): The final M2 validation on 77c6924 is running (check-ios on 26). The M2 PR body is final apart from the validation numbers. On ios/m3: INTENTS (spike; Intents test target on a 27 clone), WIDGETS (data and timeline host tests, 6e59883) and PERF+UPG (the 10k seed and timing tests, e552fe6) are in progress. Load is around 40; PERF baselines are deferred to a quiet machine.

- 2026-10-20 18:05 (EDT): ios/m3 now carries all of M2 (206eac2) plus HANDLER and NSE. Started: **INTENTS** (CSV/REG agent; a time-boxed Siri spike first, findings into research/04-siri.md) and **WIDGETS** (FORM agent; read-only widget parts first, then interactive buttons on INTENTS' shared types). Final M2 validation on 77c6924 is running; the PR body is being finalized.

- 2026-10-20 18:00 (EDT): **iOS 27 fixes merged into ios/m2-ui** (77c6924; Codex ×2). RECORD, EDIT and the topic screens show the system back button while clean (iOS 27 gives no content swipe with a hidden back button) and the guarded back once changed; the token sheet clears the secret after an awaited Keychain save and before closing, and can't be swipe-dismissed while a secret is typed (the iOS 27 Passwords prompt); the XXXL row-swipe test and the content-swipe test are fixed. UI 78/0 on both 26 and 27. Lint, core and the app build pass on the merge. **M2 is code-complete.** Final validation on 77c6924 is running, and the M2 PR body is being finalized.

- 2026-10-20 16:30 (EDT): **BUILDER-UI merged into ios/m2-ui** (Codex ×2; on 8e58e92: UI 95 with 1 failure, the known Record content-swipe flake being fixed on ios/m2-ios27; builder UI 5/5 light and dark; mutants 24/24; 14 deviations in docs/ios/demo/m2/builder-deviations.md). Lint, core, vectors with no drift, the app build and check-frontend pass on the merge. M2 PR: waiting only on the iOS 27 fixes (26 run in progress, then content-swipe ×3 on 27).

- 2026-10-20 15:55 (EDT): BUILDER-UI (875b0aa; full builder, preview, edit questions, Review via a dry-run /check, publish v(n+1), the 409 sheet, the Versions tab from the store; builder UI 5/5 light and dark; mutants 16/16; 12 PWA deviations). Codex r1: 3 Majors, all async races (publish discards later edits; "Keep my draft" during Load latest; a late /check reviews a stale draft) and 1 Minor (pending option text is view-local). Fixing, with suspended-response tests. iOS 27 fixes (3ca356a): the 27/26 validation is still running.

- 2026-10-20 14:55 (EDT): The PWA `tsc -b` failed on m2-ui (TOPIC's schedule.vectors.test.ts imported node:fs by literal); fixed in eb4e212, check-frontend green. iOS 27 fixes: Codex found 1 Major (swipe-dismissing the token sheet bypassed the secret clearing); fixed in b6b81c6 with interactiveDismissDisabled while a secret is typed, plus a UI test whose no-prompt check is proven by mutation. Its 27/26 run seems to have died at the start; being restarted. BUILDER-UI committed (fb12777: builder screens, publish v(n+1), the 409 conflict sheet, the Versions tab); 4 BuilderUITests failures (duplicate add-question ids, a missing Preview button) being fixed.

- 2026-10-20 14:25 (EDT): **NSE merged into ios/m3** (8915831; Unit 851/0 on 4c16dfd). The NSE agent found an ~11% flaky assertion in EDIT's aRefusedEditIsFixedInPlace (a substring check across a random UUID); the fix is ported to m2-ui (923026c). The M3 code so far is HANDLER and NSE (device verification needs the Team ID and APNs key). M2 PR: only the iOS 27 UI fixes remain. BUILDER-UI is in progress.

- 2026-10-20 14:10 (EDT): **New `ios/m3` collection branch** (from m2-ui 2bab7fe) holds the M3 work until the M2 PR lands; **HANDLER merged into it** (5a7aced; Unit 863/0 on 1ac5667; lint and core pass). NSE: after merging m2-ui, EDIT's SessionEntryWriterTests.aRefusedEditIsFixedInPlace fails on the NSE branch (an overlay-fold vs EDIT fix-mode semantics clash from merging the two); being fixed. iOS 27 fixes (ios/m2-ios27): the native back button on a clean form (iOS 27 gives no content swipe to a screen with a hidden back button; the SwipeBack helper is removed); the token sheet clears the secret before closing (to avoid the iOS 27 Passwords prompt); the XXXL test scrolls the row middle into view. Validation runs going. BUILDER-UI started (skeleton agent). Load peaked around 70.

- 2026-10-20 14:00 (EDT): **TOPIC merged into ios/m2-ui** (Codex ×3; on 88c84ab: Unit 831, UI 85/0, router mutants 2/2, lease mutants 6/6; lint, core, vectors with no drift, the app build and frontend vitest pass on the merge). **All 21 M2 packages are in.** Remaining before the M2 PR: the iOS 27 UI fixes (ios/m2-ios27), then a final check-ios (26 and 27) on the tip, then the PR into feat/ios-app.

- 2026-10-20 13:55 (EDT): M2 pre-validation on a05a3a1 finished. check-ios: iOS 26.0 Unit 774/0, UI 65/0; iOS 27 Unit 774/0, UI 62/3 (being fixed on ios/m2-ios27: an iOS 27 Save-Password prompt over Settings, the XXXL row-swipe test, and the content swipe on 27). E2E 14/0 (3 demo skips). Integration 19/19 ×2. `make check` (backend and frontend) green. `make vectors`: no drift. TOPIC's final UI run is going; ios27 fixes are on the 27 clone.

- 2026-10-20 13:40 (EDT): **TOPIC approved** (Codex r3: the lifecycle under the flush lease, with all paths releasing and no same-lease deadlock; a route-bound handoff). Its final simulator runs are going, then the merge. M2 pre-validation, check-ios on a05a3a1: **iOS 26.0 green** (Unit 774/0, UI 65/0); **iOS 27**: Unit 774/0, UI 62/3. The failures are RecordUITests.testAContentSwipeGoesBackFromACleanForm (XCUITest "Invalid frame dimension" warnings), SettingsUITests.testSettingsShowsTheServerAndKeepsTheTokenInTheKeychain, and EntriesTests.testAccessibilityXXXL (the known flake). Triage and fixes are with the FORM agent on ios/m2-ios27. E2E, integration ×2, `make check` and vectors are next in the run.

- 2026-10-20 13:25 (EDT): TOPIC r2 fixes committed (88c84ab: the delete lifecycle under the flush lease; a route-bound settings handoff); Codex r3 running, focused on lease deadlocks. The M2 pre-validation is in check-ios's iOS 27 UI plan; the swipe-guard tests log XCUITest "Invalid frame dimension" warnings on 27, so results are pending.

- 2026-10-20 13:10 (EDT): M2 pre-validation (on a05a3a1, everything except TOPIC) is running in ios-m2-validate: check-ios on 26.0 then 27 (now on the 27 Unit plan), then E2E, integration ×2, `make check` and vectors. TOPIC r2 fixes: one TopicWrites swift-test was orphaned and hung for 26 min at 0% CPU (likely a flush-lease deadlock) and was blocking later runs via the SwiftPM lock. The lead killed it by PID; the agent has been told to fix the deadlock and bound every lease wait in the tests.

- 2026-10-20 12:45 (EDT): **UIT-2 swipe follow-up merged** (e913853; tests only, no app change). The clean-form content-swipe control has been added; the changed-form tests are proven by mutation (guard off fails exactly the 3 changed-form tests); a 2 s Home poll replaces the fixed sleep; the flick is anchored at the Type label's height, 30% across. Lint and build-for-testing pass on the merge. **TOPIC is the last M2 package** (r2 fixes in progress: the lifecycle under the flush lease, a route-bound handoff).

- 2026-10-20 12:25 (EDT): **UIT-5 merged into ios/m2-ui** (Codex ×2; E2E 14/0; a holdDuration=0 mutation is caught by both delete tests; the outbox-ordering argument for Undo was verified by Codex). Lint, the build and build-for-testing pass on the merge. Remaining for the M2 PR: the UIT-2 swipe follow-up (e913853 being proven) and TOPIC (r2 Majors in progress).

- 2026-10-20 12:10 (EDT): TOPIC r2: the round-1 items are RESOLVED (the delete sends the queued archive itself; the slug save hands off the model). Two new Majors: the direct archive and DELETE aren't serialized with the outbox flusher (a double-send, or a queued unarchive in between gives a 409), so the whole lifecycle sequence will run under the flush lease; and the slug handoff can leak a stale model (to be bound to a one-shot token plus the topic id). The M2 PR body is drafted (scratchpad m2-pr-body.md; deviations from every package filled in from the agents' reports). UIT-2 follow-up: Mutation A run done; HEAD result awaited. UIT-5: r1 fixes in progress.

- 2026-10-20 11:55 (EDT): **APPSET merged into ios/m2-ui** (Codex ×3; on f8b3115: full UI 52/52, Unit 765; lint, core and the app build pass on the merge). UIT-5 (a54e0a8; E2E 13/0) Codex r1: 2 Majors (the Undo case sleeps rather than awaiting a confirmed flush; the no-Undo case doesn't prove the 6 s hold) and 1 Minor (entry lookup only searches page 1). TOPIC: r1 fixes in progress. UIT-2 swipe follow-up: Minors fixed in 8996ef2, run going.

- 2026-10-20 11:40 (EDT): TOPIC reconciled with m2-ui (65d94ef; the diff against m2-ui is TOPIC only). Codex r1: 2 Majors (a slug save recreates the settings model and drops an unsaved schedule; a delete can be blocked forever when the queued archive sits behind failed entry changes) and 1 Minor (the fake server's schedule_updated_at). UIT-2 swipe follow-up (7a1278e, tests only): no Majors; two Minors (a fixed sleep before the "still here" assert; an unanchored flick), with #1 being fixed before the merge. APPSET: AppSettingsUITests 3/3 after its LabeledContent test fix; full UI run going. UIT-5: E2E rerun on a54e0a8 after a compile fix.

- 2026-10-20 11:10 (EDT): **EDIT merged into ios/m2-ui** (Codex ×2; on b5cb86c: Unit 676, UI 61/61; lint, core and the app build pass on the merge). EDIT's 9 PWA deviations are recorded in its report: changed keys only; offline edits via the outbox; Fix for refused edits (outbox.md §11 "latest correction wins"); a refused local create redirects to RECORD's Fix; Delete as a tap-only form row; Save in the keyboard toolbar; an unchanged form leaves without writing; current-version questions as the fallback; a save after a switch is refused. APPSET: one AppSettingsUITests failure (sync section) still being fixed. TOPIC: reconciling its separate BUILDER merge with m2-ui. UIT-2 swipe follow-up: proof run going.

- 2026-10-20 10:55 (EDT): **NSE approved** (Codex r4: grouped topic states plus a streamed entry fold; memory bounded). It goes into `ios/m3` with HANDLER after their Unit runs, which are deferred until the M2 simulator runs clear. M2 runs in progress: EDIT's full UI on b5cb86c; APPSET's fix for its failing sync-section UI test (m2-ui merged, ed2ffaa); UIT-2's swipe-test proof (7a1278e; the content-swipe "regression" was a slow test drag, so the re-enable change is reverted); TOPIC's UI run.

- 2026-10-20 10:40 (EDT): Codex approvals: **EDIT r2** (fix-mode prefill and CAS; outbox safety; the tap-only Delete row; final full UI run on b5cb86c pending), **APPSET r3** (canonical OFL hash; merge after its simulator run), **HANDLER r4** (decide-act-reconcile badge, scope-checked flush, activeScope; goes into a new `ios/m3` collection branch). NSE r3: cache, cancellation and exact ints RESOLVED; a new Major remains, since viewTopics still loads all topic outbox items (to be streamed). TOPIC: no commit for 1 h; asked. UIT-2 content-swipe fix (518f070): proving run pending. Simulator slots are the bottleneck; EDIT has been queued for over 30 min.

- 2026-10-20 10:25 (EDT): Codex round-up.
  - HANDLER r3: L2 RESOLVED. The ActiveStoreGate still isn't decide-and-act (the act closure leaves the main actor; the pre-bind registry path can accept a stale store while the first bind is pending). Agreed approach: a synchronous main-actor start, badge reconciliation afterwards, a scope-checked flush inside the scheduler, and a pending bind counts as not active.
  - NSE r2: the cutoff is RESOLVED. Still open: the QuestionBook cache is unbounded; reconciliation isn't cancellation-checked; integer bounds are compared as Double, the same class as CAT's.
  - APPSET r2: everything RESOLVED except the font licence texts (they need a canonical full-text or hash check).
  
  UIT-2's content-swipe fix (518f070: re-enable the content-pop recognizer while RECORD owns it) is in its proving run. EDIT and TOPIC have been asked for status (EDIT has had no commit for 2 h).

- 2026-10-20 10:10 (EDT): NSE (CSV agent, c090c86; host-testable NotificationPreparation, N9; the extension is untestable on the simulator per spike F1, so device checkpoint): Codex r1 found 2 Majors (unbounded overlay reads against the 24 MB NSE limit; the 50-entry cutoff misses satisfied slots) and 2 Minors (expiry doesn't cancel side effects; tampered descriptors are registered). APPSET (f1ec038; sync section, About, licences): Codex r1 found 4 Majors (Sync now never pulls; the Online badge is wrong when the pill state outranks offline; licence completeness covers only QuickrKit's lockfile; licence texts aren't exactly enforced) and 1 Minor ("Last synced" goes stale). All are being fixed. EDIT: Delete is now a tap-only row (a drag can't trigger it). HANDLER r2 fixes, TOPIC's m2-ui/BUILDER merge and the UIT-2 content-swipe follow-up are in progress. The m2-ui integration run is still queued for a slot.

- 2026-10-20 10:00 (EDT): **BUILDER merged into ios/m2-ui** via ios/m2-builder-land (84bf2f8). Its conflicts were the Makefile vectors and the fixtures README. A semantic duplicate, Limits.serverDefaults (identical in BUILDER and RECORD), was resolved by keeping RECORD's. On the landing branch: check-backend 694, the backend docker build (python 3.14.7-slim), vectors with no drift, frontend 852, core (QuickrCore 184, QuickrData 562), lint and the app build. TOPIC can now merge m2-ui. APPSET is next (SYNC-UX agent).

- 2026-10-20 09:55 (EDT, check): BUILDER landing merged in ios/m2-builder-land (7e3ba18); verification pending. EDIT: the new swipe-back test found a real hazard (a blocked swipe on a dirty form whose release lands on "Delete Entry" deleted the entry); fixing with a drag-release guard. HANDLER r2 fixes in progress (delivered-reminder removal matched on server, topic and slot; an ActiveStoreGate for the badge and flush). TOPIC: UI tests running (076fe17). NSE started (CSV agent). The m2-ui integration Unit+UI run is queued for a slot.

- 2026-10-20 09:55 (EDT): **UIT-2 (c47406c) and CSV merged into ios/m2-ui.** UIT-2: Codex ×2; E2E 13/13, UI 41, Unit 618. CSV: Codex ×4; Unit 634, export UI 4/4. The CSV merge conflicted in the UITestLaunch fake server (the CSV route vs the stats route); I kept both. Lint, core, script tests and the app build pass on the merge; an integration Unit + UI run on m2-ui follows. UIT-2 follow-up: the content-swipe guard test was vacuous under mutation; a positive control is in 271d271 (possibly a clean-form content-swipe regression), as a separate commit. EDIT can now merge m2-ui.

- 2026-10-20 09:45 (EDT): **STATS merged into ios/m2-ui** (Codex ×3; on afad7e0: Unit 652, UI 40/40; lint, core, the app build and frontend vitest pass on the merge). CSV: Codex r4 approved (d5e6a65); merge after a final m2-ui merge in its branch. HANDLER r2: exactly-once and duplicate flush RESOLVED; still open are L2 removing a same-ID reminder from another server, and the active check spanning awaits before the badge and flush. UIT-2: approved, awaiting its final report. EDIT: r1 fix gates pending. TOPIC: BUILDER landing requested again.

- 2026-10-20 09:25 (EDT): Codex results.
  - STATS r3: approved. Its final run on the m2-ui merge (afad7e0) is going, then the merge.
  - UIT-2 r2: approved (c47406c). Its final run is going, then the merge, then EDIT can follow.
  - CSV r3: the handOver race is resolved, but the launch sweep can delete an active export (start() re-runs on background refresh); the fix is to sweep once per process, over pre-existing folders only.
  - HANDLER r1: 3 Majors (background-task expiry doesn't guarantee completion; no foreground local/remote dedupe; isActive goes stale across awaits for badge and flush) and 1 Minor (a duplicate tap skips the forced flush).
  - EDIT r1 fixes: gates done or pending.
  
  TOPIC: host-side schedule, details and requests in progress; the BUILDER landing (step 0) is still to do. Machine load peaked around 97.

- 2026-10-20 08:55 (EDT): More parallel host-first work. TOPIC started (skeleton agent): step 0 lands BUILDER (ios/m6-builder 22865b8, which was never merged into m2-ui; the trial merge conflicts only in the Makefile vectors and the fixtures README). HANDLER (M3) started (test-isolation agent, ios/m3-handler): action handling host-first, local notifications on the simulator until the Team ID and APNs key arrive. EDIT r1 fixes in 687678d (fix mode prefills from before the refused edit; the user's correction wins over later queued updates, written into outbox.md §11; a CAS miss reconciles the draft; mutations 7/7). STATS r2 fix in 0c80a8f (abandonment check after every await). CSV and UIT-2 final simulator runs in progress.

- 2026-10-20 08:40 (EDT): STATS r2: zone and freshness RESOLVED; overlapping loads NOT RESOLVED (the cache-miss branch mutates state without an abandonment check); fixing. EDIT final run green on 862e2a5 (Unit 591, UI 48, mutations 15/15; 9 PWA deviations accepted). Codex r1: 2 Majors in fix mode (the prefill includes later queued updates, which then overwrite the correction; CAS recovery keeps a stale draft); fixing. CSV r1 fixes in 2b942ab (store-owned exports, fail-closed identity, a directory per export, streaming to disk with a 120 s deadline; mutations 9/9); simulator gates running. UIT-2: the keyboard Save is now a labelled prominent "Save" after Next/Done (7c94e88); final runs going. Merge order: UIT-2, then EDIT.

- 2026-10-20 08:25 (EDT): CSV Codex r1: 4 Majors (a stale export after a server switch; the identity lookup fails open; overlapping exports share one directory; the whole body is buffered with a 15 s deadline); fixes in progress. STATS r1 fixes in 83f681c (zone read per load; the latest load wins; per-series staleness); simulator run pending, then r2. EDIT merged ios/m2-uit2 at f98d5a5 (formSaveBar) and adopted it. Delete is now a red "Delete Entry" form row (a PWA deviation). Final run in progress. **Merge order: UIT-2 into m2-ui before EDIT.** UIT-2: formSaveBar 21/21; demo regen and full plans next.

- 2026-10-20 08:10 (EDT): Apple Developer Program enrolment confirmed (valid through 2027-10-19). Still to come: the Team ID, Xcode signed in on the Mac, and an APNs key; these unblock M3 device work. STATS Codex r1: 2 Majors (the device zone is snapshotted at model creation; overlapping identical loads can publish an older result) and 1 Minor (a series' cached freshness isn't shown); fixes in progress. RECORD Save: the shared `.formSaveBar` (Save goes into the keyboard toolbar while typing; f98d5a5 on ios/m2-uit2) is under simulator test; EDIT will merge it and adopt it before its final run. CSV gates: results pending.

- 2026-10-20 08:00 (EDT): STATS green at 7af157d (Unit 615, UI 40/40 with StatsUITests 4/4 in light and dark; backend 691, frontend 852); screenshots in d68e06d; Codex r1 running. CSV started and is gating (9b27ba1; online-only share-sheet export with LIST's filters; deviations: the filename date comes from the device, there's an offline message, the icon stays fixed at AX sizes). RECORD Save bar: the UIKit-frame pin failed (bar under the keyboard even before editing). Now Save moves into the keyboard toolbar while the keyboard is up, built as a shared QuickrUI/Form component because EDIT's screen likely has the same bug. EDIT: test-side fixes (the unit in the number field's AX value; cursor placement) before the rerun.

- 2026-10-20 07:35 (EDT): **REG merged into ios/m2-ui** (Codex ×4; on 8a54b8a: Unit 618, UI 36/36 on 68832d3; lint, core and the app build pass on the merge). No real APNs token until the aps-environment entitlement and Team ID land (M3). Remaining for M2: EDIT (UI rerun after the demo-version fix), STATS (final run), UIT-2 (Save-bar fix run, demo assets), then the M2 PR(s) into feat/ios-app.

- 2026-10-20 07:25 (EDT): REG: Codex r3 resolved the residual M2 and the requested tests, but found 2 new Majors in the foreground-trip guard (background→inactive→active wasn't counted as a trip; push could activate after a backgrounded .active plus expiry). Fixed in 8a54b8a, simulator checks pending, then r4. STATS: Unit 613, StatsUITests 4/4 light and dark. The screenshots found a real pull-to-refresh cancellation bug (fixed, 7e91164), plus chart layout fixes. The unstructured refresh must be scope-guarded (asked). The offline zone-change message is being added; the final run follows. RECORD Save bar: the first theory (toolbar shape) was wrong; the bar drops on re-render with no nav change. Now pinned to UIKit's keyboard frame (439ced0); fallback: Save in the keyboard toolbar. The swipe-back guard and VoiceOver escape are kept as independent improvements. EDIT: UI run in progress on 8c7352e.

- 2026-10-20 07:10 (EDT): REG: on 68832d3, focused 12/12, app mutants 3/3, Unit 617 ×2; UI result pending, then Codex r3. STATS: views on LIST's tabs and ranges (m2-ui merged, cda06b8). The cache key names the store, and a zone change is never served from cache: offline it shows "unavailable", since the old zone's buckets would be wrong (decision). StatsUITests running. EDIT: gates running on 8c7352e. UIT-2: RECORD fix runs pending. The two booted simulators are the EDIT and STATS clones.

- 2026-10-20 06:55 (EDT): **simcap merged into ios/m2-ui** (Codex ×2). Any booted "quickR …" device counts toward IOS_SIM_CAP. Plain `make ios-test`/`ios-uitest`/`ios-sim-run`/`check-ios` default to this worktree's clone(s), per target. The real run on its clone passed: Unit 570. Script tests and lint pass on the merge. **Every worktree should merge m2-ui before its next sim run.** EDIT: Fix for refused edits added (entryUpdateFixDraft; mutations 8/8); gates queued. UIT-2: real RECORD bug fixed (the Save bar slid under the keyboard's Done after the first edit; c7948b2, 6a04d7c: toolbar shape kept constant, swipe-back and VoiceOver escape guarded). REG: simulator gates on its clone.

- 2026-10-20 06:40 (EDT): simcap Codex r2 = all 3 RESOLVED (one README nit); merging after its real run. REG: Codex r2 resolved 5 of 6 (residual M2: lifecycle ordering) and asked for 4 missing tests. Fixed in 68832d3 (reconcile from stored state; v1→v2 migration test; queue cancellation and recovery tests), together with two merge-interaction fixes in AppEnvironment (no push work after a cancelled start; push created lazily and activated once per foreground trip). Simulator gates are running on its own clone, then r3. STATS: host side complete (96 server responses + PWA chart vectors; models bit-for-bit; StatsLoader with an epoch-checked cache); views in progress on LIST. EDIT: EditModel WIP (a0260df). Decisions: queue changed keys only (a deviation from the PWA); Fix for refused edits in scope; source editable on the edit screen. UIT-2: Save-bar-above-keyboard test (7ead8db); demo capture in progress.

- 2026-10-20 06:25 (EDT, check): EDIT started (LIST agent, ios/m2-edit from 5d16bac). STATS: chart models and StatsLoader in progress (2f3d7a8). UIT-2: test isolation and the tap-count table committed (61e5d3f); demo capture in progress. simcap Codex r1: 3 Majors (explicit IOS_SIM still defaults; check-ios still uses base devices; MAKEFLAGS leaks into the nested-make tests); fixing per target, with check-ios on the clone. REG: UI run on the base device; asked for results and a shutdown.

- 2026-10-20 06:25 (EDT): **LIST merged into ios/m2-ui** (Codex ×3; on 7bf0452: UI 36/36, Unit 587, integration 19/19; lint, core, the app build and the frontend vitest pass on the merge). LIST's 8 PWA deviations are recorded in its report: local filters with no paging; swipe-delete with Undo on the list; Waiting/Not-synced badges; a "not synced" count that includes refused; alphabetical source-filter ties; device formats with no CSV or table; a minimal topic header; and the list sorts by id ASC. simcap (scripts fix: the base device counts toward the cap; make targets default to the worktree clone) is at eb4f317, under Codex review. UIT-2: E2E and TapCount 10/10 on 88b761f; demo capture next. REG: Unit 563 ×2, UI running.

- 2026-10-20 06:10 (EDT): LIST: Codex r3 = Major RESOLVED, no new findings. m2-ui (SYNC-UX) is merged in (7ef3163), and a semantic build break (Binding.scope) is fixed in 7bf0452. Final Unit, UI and integration runs are going, then the merge. STATS started (SYNC-UX agent, ios/m2-stats): the server buckets; the plan is server and PWA chart vectors, models, an epoch-checked StatsLoader, then the views, which wait for LIST's TopicTabsView in m2-ui. REG: simulator gates running on 676567b, but on the base device "quickR iOS-26-0", which bypasses the clone cap (load peaked around 54). Follow-up: make sim_boot/test.sh refuse the base device. UIT-2: E2E rerun not running yet; asked.

- 2026-10-20 06:05 (EDT): **SYNC-UX merged into ios/m2-ui** (6f206a1; Codex ×4; on 8f7171f: UI 30/30, Unit 570 ×2; lint, core and the app build pass on the merge). It brings the process-wide SystemCategoriesLock for app tests, and test environments pass `categoryCenter: nil`. W6 is complete (RECORD, SYNC-UX, CAT). Remaining for M2a/M2b: LIST (Codex r3 pending), REG (r2 pending), UIT-2.

- 2026-10-20 05:55 (EDT): SYNC-UX: Unit green ×2 on 8f7171f (570, with CAT's test passing); its UI run seems to have ended with the clone still booted, and I've asked for the results and a shutdown. LIST: Codex r2 fix committed (305a17e: rows carry their binding; EntryDeleter); full gates running. REG: r1 fixes in 676567b (lint and core green, mutations 8/8; registry v2 adds register_attempts/register_due); simulator gates queued. UIT-2: test bugs fixed (88b761f); all six tap-count scenarios equal the PWA; table drafted; E2E rerun queued for a slot.

- 2026-10-20 05:40 (EDT): REG done at 7bc805f (Unit 553 ×2, UI 20/20, mutations 9/9; 5 deviations recorded; no real token until the aps-environment entitlement and Team ID arrive in M3). m2-ui is merged in at b284286. Codex r1 found 4 Majors (a pending deletion can remove a renewed registration; an in-flight registration escapes switch cleanup; a failed rotation isn't retried; an unbounded epoch-recovery loop) and 2 Minors (the status isn't observable; the didFail deviation only holds right after a success). Fixes are in 676567b and being gated. SYNC-UX: a process-wide suspending lock for system-category tests (8f7171f); final runs pending. LIST: delete-scope capture fix in progress. UIT-2: test fixes (88b761f); the offline-record toast failure is under investigation.

- 2026-10-20 05:25 (EDT): SYNC-UX: on the RECORD-merged tree, CAT's live-categories test failed once because sync unit tests registered categories through AppEnvironment.live (process-wide state). Fixed in b44dffa (the sync tests pass no category center); CAT's suite is being serialized; Unit ×2 and UI rerunning. LIST: Codex r2 resolved items 2 and 3 (all 51 range vectors confirmed against the PWA code), but the delete-scope race is NOT RESOLVED (the callback reads `model.binding` lazily); fix in progress on 386781f (m2-ui is merged in at 7322441). REG: 2 commits. UIT-2: E2E + tap-count tests committed (44f18ce); first simulator run in progress.

- 2026-10-20 05:20 (EDT): SYNC-UX re-merged RECORD (9f96439; the conflict was in the UITestLaunch fake server, combined on RECORD's transport); core and lint green; final UI and Unit plans running. LIST: Codex r1 fixes committed (1889166: delete uses the rows' binding; a late topic shows up; midnight DST gaps match the PWA, with 6 Santiago vectors); full gates running, then Codex r2. REG: 2 commits in (bc16544: APNs token registration; Settings push setup and "Test this device"). UIT-2: WIP.

- 2026-10-20 05:10 (EDT): **RECORD merged into ios/m2-ui** (ce08276; Codex ×2; UI 27/27, Unit 521; lint, core and the app build pass on the merge). UIT-2 started (FORM agent). SYNC-UX is green at 84b1d0a, with the expiry-first test added; it is re-merging ce08276 (UITestLaunch conflict) before a final UI run and the merge.

- 2026-10-20 05:00 (EDT): **CAT merged into ios/m2-ui** (f4ca317, Codex ×2; exact int bounds past 2^53 with 4 new server vectors; `\A…\z` anchors; minimal UNUserNotificationCenter adapter live). SYNC-UX: the r3 Major is fixed (6c6d9cb/c70d480), Codex r4 = no Blocker/Major, and CAT is merged in (d8fdecc). An expiry-first test is being added, then the full UI plan, then the merge. LIST (8bbc69d, 8 parity deviations recorded in its report): Codex r1 found 2 Majors (a stale row's delete uses the active store's scope; a topic missing at the first lookup never recovers) and 1 Minor (the PWA's midnight-DST-gap rangeStart); fixes in progress. RECORD: the full UI rerun on 069366b is pending. REG (W7) started on ios/m2-reg from f4ca317.

- 2026-10-20 04:45 (EDT): W6: SYNC-UX green at e32d2e5 (unit 545, UI 23, integration 18/18; one EntryScope in QuickrCore). Codex r3 resolved 5 of 6 round-2 items, but found a new Major: background expiry cancels a shared startup that a foreground activation is waiting on, leaving the open app disconnected. Fix in progress. RECORD: Codex r2 approved (069366b); full UI rerun pending, then merge. CAT is fixing the >2^53 bounds and ICU anchors. LIST gates are running. Agents now prefix scratchpad logs with their package name, because a shared UI.log was overwritten.

- 2026-10-20 04:10 (EDT): W6: RECORD re-merged TILES and moved onto EntryWriter/EntryToasts (42f9b56); its integration test caught a TILES sendNow bug where fixed entries reported "queued" (fixed in 16a06f1); UI rerun pending. SYNC-UX r2 fixes in 383af22 (startup expiry cancels the start; flush lease release is uncancellable); merged m2-ui (e32d2e5); gates running. CAT done (c04d411); Codex = REQUEST CHANGES (int bounds above 2^53 compared as Double; ICU `$` anchors); minimal UNUserNotificationCenter adapter being added. LIST WIP 01a57b1, with entries server vectors and PWA range-start vectors.

- 2026-10-20 03:45 (EDT): **TILES merged into ios/m2-ui** (Codex ×3; the final round scoped the QuickLogModels cache and drafts to the store via EntryScope; the XXXL layout loop is fixed with a VStack at AX sizes). Gate on the merge: lint, core green; TILES's own UI 20/20 and integration 18/18. W5 is complete (HOME, TILES, LINKS+SETTINGS, B8, WIRE, FORM). RECORD and SYNC-UX now re-merge m2-ui.

- 2026-10-20 01:25 (EDT): **HOME merged into ios/m2-ui** (02e0d7d, Codex ×3; onboarding → HomeView via the router). TILES is merging m2-ui to replace HOME's stub tile (9e41822), gates running. RECORD (FORM agent) and SYNC-UX (OUTBOX agent) started; their first model commits are in. SYNC-UX owns the sync-pill swap in HOME's header.

- 2026-10-20 01:00 (EDT): **LINKS+SETTINGS merged into ios/m2-ui** after 3 Codex rounds: typed Route and DeepLink with PWA parity and origin-checked https links; onboarding; settings (server switch with an unsynced warning, reset with Sync first, about); **per-server Keychain Cloudflare Access credentials**, resolved per request; secret redaction in all HTTP descriptions. Gate on the merge: lint, core green. TILES approved (r2), waiting on HOME. HOME r2 approved up to 8529c4b; the follow-up 51395c7 (AX header scroll-away, title and sort fixes) is gating.

- 2026-10-20 00:30 (EDT): TILES ready (80ff85b; UI 11/11, integration 16/16, tap counts match the PWA); in Codex review. HOME r1 fixes 59acd66 (offline empty state, rebind reset with a generation token, byte-order name sort matching the musl server, collation vectors); gates running. LINKS+SETTINGS r2: per-server Keychain credentials (decided) to fix token isolation.

- 2026-10-20 00:10 (EDT): Another API outage, ~22:25 to 00:10, stalled HOME, TILES and LINKS+SETTINGS mid-gate; all resumed. LINKS+SETTINGS Codex = REQUEST CHANGES (no "Sync first" in reset, the token is committed before the switch is confirmed, a warning-read failure allows the switch, and the secret leaks via HTTP header descriptions); fixes are in 090bf61, gates pending. HOME at d3daf9c (UI tests, screenshots), gates pending. TILES merged HOME's demo store; its gates are pending. A commit security-review hook also failed during the outage (log: ~/.claude/security/log.txt).

- 2026-10-19 21:15 (EDT): **B8 merged into ios/m2-ui** (Codex r2: all majors resolved; real-browser coverage is a documented gap). The PWA now sends identity preconditions for notification actions, uses the shared §7.4 action entry id with Python-generated vectors, and gives visible feedback for every outcome. Gate on the merge: `make check` green (pytest 688, vitest 840). HOME, TILES (2/3) and LINKS+SETTINGS are in progress, with 2 simulators booted (TILES, SETTINGS).

- 2026-10-19 21:00 (EDT): FORM merged into ios/m2-ui (a20fd41). LINKS+SETTINGS assigned (FORM agent). B8 done (3edb2b8, 36afb5e, 5879f9e; make check green). Codex = REQUEST CHANGES: server_id isn't preserved (wrong-server writes), failures silently dismiss the reminder. Decision: a **shared cross-client action entry id** (name-based from server_id, topic_id, due_since) with Python-generated vectors, amending §7.1. HOME and TILES (1/3: 5f0afbb) in progress.

- 2026-10-19 21:15 (EDT): **W5 started.** Shared brief docs/ios/specs/m2-screens.md (c0eda29). HOME → ex-INT/WIRE agent (ios/m2-home); TILES → SYNC agent (ios/m2-tiles); B8 → OUTBOX agent (ios/m2-b8, PWA Chromium actions). FORM is re-landing on top of WIRE; its agent then takes LINKS+SETTINGS.

- 2026-10-19 21:00 (EDT): **WIRE merged into ios/m2-ui** after 4 Codex rounds. AppSession is the composition root: one pool per store, a serialized rebind with retire-before-publish, generation-ordered pause and resume for the scheduler and coordinator, background episodes, GRDB suspend/resume, read-only widget stores that never create a -shm, a write façade, and an isolated lifecycle test step. Gate on the merge: lint, ios-core-test (STRICT) green. Next: FORM lands, then the W5 screens (HOME, TILES, LINKS, SETTINGS) start on WIRE's API.

- 2026-10-19 21:00 (EDT): **PR #9 green and squash-merged into feat/ios-app (48fa566). M1 done.** ios/m2-ui moved onto it (9278742, tree identical to feat/ios-app). From here STATUS lives on ios/m2-ui. WIRE r3 fix d06e1b0 is in Codex r4; FORM (ios/m2-form) and BUILDER (ios/m6-builder) wait to be merged into their milestone branches.

- 2026-10-19 20:45 (EDT): CI-TIMING merged (9616f61): the real-time and MP tests run under `TimingTests`/`MultiProcessTests`, gated by QUICKR_TIMING_TESTS=1, in a serial `make ios-timing-test` (STRICT off, MP children never inherit STRICT, the agent reads stdin on its own thread); logic tests run under STRICT. Proven: 3/3 with 4 spinners, 2/2 with 20 spinners (load ~50), Unit plan 427 passed on 26.0. Pushing to PR #9.

- 2026-10-19 20:15 (EDT): Repeated API outages from 2026-10-18 ~11:15 to now (ENOTFOUND, quota) stalled every agent; no work lost (CI-TIMING WIP: 16 uncommitted files in ios-m1-citiming; WIRE at 9dc05b8). WIRE Codex r3: all r2 items resolved; one new Major (a replacement scheduler published while paused loses activation's resume). Both agents resumed.

- 2026-10-18 10:50: PR #9 CI run 39114982916: no hang any more (it fails fast, CI-HANG works). Real-time tests fail on the 3-core runner: all MP cases (30 s reply timeouts; STRICT leaks into the child processes), Outbox 16b–16k, sendNow, lease polling, and a transport timing test (also on the simulator, without STRICT). Root cause: parallel Swift Testing suites plus few cores starve real-time deadlines. CI-TIMING (SYNC agent) isolates timing tests into a serialized `make ios-timing-test` step without STRICT; logic tests stay under STRICT; the simulator Unit plan skips the timing tests.

- 2026-10-18 10:30: CI-HANG merged (bf1d773: the blocked writer runs on its own queue; real barrier replaces the 50 ms sleep; .timeLimit on all suites; STRICT pool in swift-test.sh; CI Build + Unit 15 min with a 5-min silence watchdog; the host `swift test` job now runs on PRs). Gate green on the merge. Pushing to PR #9 for one CI run.

- 2026-10-18 10:10: Streaming fix merged into ios/m1-data (d7e7ddb; Codex major fixed: process-group signal forwarding; exit 128+N). CI-HANG root cause: `LeaseTimeSamplingTests` parked cooperative threads on DispatchSemaphore inside sync GRDB writes, so 4 parallel tests starved a 3-thread pool. Production is clean. Fix fba4e2e is being verified. WIRE r2: read-only opens and cleanup ordering resolved; still open: a stale episode resumes background₂'s pause, reentrant bind publishes before the prior retirement, lifecycle tests aren't process-isolated, plus a coordinator pause for the residual. c978616 (-shm guard) is done. Not pushed to PR #9 until CI-HANG is verified, to save CI minutes.

- 2026-10-18 09:50: Network outage ~08:00–09:50 (API ENOTFOUND) failed CI-HANG's and the streaming WP's turns; all agents resumed at 09:50. Streaming committed b8d0b20; WIRE merged m1-data (10c2a28), report pending; CI-HANG has a 47-file WIP (checkpoint requested).

- 2026-10-18 07:15: PR #9 iOS CI failed twice more on the 25-min step limit. **Corrected diagnosis:** not a simulator-boot stall. The log looked silent only because the watchdog/xcbeautify output is flushed at exit. The partial xcresult shows the build finished in ~2 min and QuickRTests/QuickrCoreTests ran, then **QuickrDataTests hung** after a connection-refused URLSession test (05:51:42 onwards). Hypothesis: blocking waits on the cooperative pool deadlock with ~3 CPUs, and Swift Testing ignores xcodebuild's per-test allowance. The CI-HANG package (SYNC agent) reproduces with LIBDISPATCH_COOPERATIVE_POOL_STRICT=1, fixes it, and adds .timeLimit. The 3c269c5 sim_boot change stays (harmless, bounded). Backlog: make CI output stream (watchdog/xcbeautify buffering).

- 2026-10-18 06:20: PR #9 CI: backend/frontend/docker green; iOS `build + Unit plan` failed: Xcode 26.6's region-isolation checker crashed compiling the DEBUG spike code in NotificationService.swift (Xcode 27.1 compiles it). Fix ae90611 passes only Sendable values into the task; CI rerunning. WIRE done (fdcdb1e, 0dc1762, design-note fixes 60bce0b); Codex = REQUEST CHANGES: stale background suspend after activation, expiration suspend before cleanup, bridge publishes the new scheduler before the old retires, widget opens are writable/recovering. Fixing.

- 2026-10-18 06:05: **M1 PR #9 opened** into feat/ios-app (https://github.com/Richard-Lynch/quickr/pull/9). CI running.

- 2026-10-18 06:00: **M1 evidence complete** (183ec1a): check-ios on iOS 26.0 and 27 green (446 unit + UI each, Intents 2/2 on 27); ios-integration 2/2 at 15/15; widget-proof 26.0 and 27; spike-proof 26.0; backend 686. check-ios needed 3 attempts (sim-cap env leak, fixed 39eb3ec; 16d/16f load flake, slack made scalable 8ba77e7). Opening the M1 PR into feat/ios-app.

- 2026-10-18 04:20: Gate evidence on ios/m1-evidence: widget-proof iOS 26.0 and 27, Intents plan 27 (4ad33df); ios-integration 2/2 at 15/15, backend check 686 passed (910dcf2). An earlier run was disturbed by two agents sharing one worktree's compose project (orchestrator error); it was rerun clean. spike-proof is rerunning in ios-m1-spike; check-ios on both runtimes is next. **M2 started:** ios/m2-ui fast-forwarded to the M1 tip; WIRE assigned (ex-INT agent).

- 2026-10-18 03:55: M1-FIXES merged (33c64ca, ad88eb1; Codex: all 4 resolved, no new majors; ios-core-test 375/83/29, ios-integration 2/2 at 15/15). Both milestone reviews' must-fix code items are done. Remaining before the M1 PR: gate evidence (part 1 sim proofs running; part 2 check-ios on 26.0 and 27, ios-integration ×2 on the final tip).

- 2026-10-18 03:30: SPIKE merged (289fc2f; Codex fixes b446d4d plus b11f876 verified by the orchestrator: App Group opt-in gate, strict version validation, background/main-thread assertions). **All M1 work packages are now on ios/m1-data.** Codex M1 milestone review = MERGE AFTER FIXES. Must-fix: connecting via a new URL doesn't persist it (SyncCoordinator.swift:160) → M1-FIXES; final gate evidence pending. Backlog → WIRE (M2) and M3 notification items. M1-FIXES now holds 4 items (enqueue contract, offline→flush INT case, connect URL update, ObservationTests barrier).

- 2026-10-18 03:25: Claude M1 milestone review = MERGE AFTER FIXES. Must-fix: SPIKE merged; gate logs captured and committed; the `OutboxRepository.enqueue` public contract (doc claims coalescing, the impl bypasses C0/K1–K5) → M1-FIXES (ex-INT agent), plus an offline→flush integration case. A new **WIRE** composition-root package is added to the DAG as the first M2 item. Codex milestone review still running.

- 2026-10-18 03:15: FLAKE merged (065aa9f; 5/5 serial green under load 270–390). Gate on the merge green (374 data + 83 + 29; lint). SPIKE Codex = REQUEST CHANGES (4 P2: debug gating, version-validation nil==nil, spike-proof gen, assert background state; 1 P3 doc scope); fixing.

- 2026-10-18 03:10: SPIKE done (49a90ac; spike-proof 3/3 on iOS 26.0 against the INT stack). A notification action logs from a killed app: background launch, entry committed in ~135 ms, total ~205 ms, server source ios.notification. Findings: F1 the NSE never runs for simctl push on the sim; F2 the sim delays real reminders ~10 s; F3 the async didReceive variant crashes, so HANDLER must use the completion-handler variant; F4 set the delegate in didFinishLaunching; F6 action counts need device D. Codex reviewing.

- 2026-10-18 02:45: WATCHDOG merged into ios/m1-data (c39e80a verified by the orchestrator; script tests green). Every xcodebuild and swift test now runs under the watchdog, and simulator boots go through the machine-wide cap lock. FLAKE root cause: at a 1 s budget the request deadline passed before the POST was sent → 16f now uses a 5 s budget and a #require; bounds measure the flush's own timestamps. Decision: tight real-time bounds stay strict, gates aren't trusted during load spikes, and `QUICKR_TIMING_SLACK` exists for knowingly loaded local runs (never CI).

- 2026-10-18 02:40: Load hit ~740: FLAKE's stress test spawned 32 `yes` processes (4 were asked for), plus SPIKE's Docker stack. The orchestrator killed the `yes` processes. WATCHDOG r2: all round-1 items resolved; one new Major (the final marker can be split across 3 chunks) → final fix, orchestrator verifies. SPIKE checkpoint b750a1c (handler, categories, payloads rendered by the server's own apns.render); its first sim proof run is in progress.

- 2026-10-18 02:05: SKEL merged into ios/m1-data (2891f06; **correction: the post-merge ios-core-test had 1 failure, OutboxUndoTests 16f "condition not met within 5 s". It passes 3/3 alone, so it's a load-sensitive flake while the MP suite runs concurrently; the fix is assigned.** Codex APPROVE WITH MINORS, all 4 fixed in 928f753; check-ios on 26.0 green, 440 unit). Remaining for M1: SPIKE (in progress), WATCHDOG rework, then the milestone checklist (widget-proof on 26.0 and 27, Intents plan on 27, check-ios, ios-integration), the M1 Codex+Claude review, and the PR.

- 2026-10-18 02:00: INT merged into ios/m1-data (0681189; stub conflict with MP resolved: OutboxMatrixStubs deleted, SyncMatrixStubs keeps only S10 → M3 REG). Gate on the merge: ios-core-test (367 data + 83 + 29 + 14 integration-target tests skipped without the harness), lint, backend and alembic all green. SKEL: APPROVE WITH MINORS, fixing 4. WATCHDOG: 5 majors, fixing. Next: SPIKE (the SYNC agent) once SKEL merges, then the M1 milestone review and PR.

- 2026-10-18 01:55: SKEL done (6e4c400; check-ios green on 26.0 and 27.0; widget proof green on both). Codex reviewing. CI-gap recommendation adopted: IntentMetadataTests in CI plus widget-proof on 26.0 as a milestone checklist item. Siri research and DAG amended (no AppIntentsPackage).

- 2026-10-18 01:50: MP merged into ios/m1-data (85ae3b0) after the orchestrator verified the r2 minors (9257754). ios-core-test and lint green on the merge. INT r2 and WATCHDOG Codex reviews running.

- 2026-10-18 01:40: MP r2: all 3 majors resolved, no new majors; 3 minors left (S16 sync gap, gate arrival-waiter cleanup, listener-startup cancellation) → final fix, orchestrator verifies. INT fixes committed 7bcf492 (retain cycle, revocable forwarding). WATCHDOG committed d367c64; check-ios result pending. SKEL is active (new xcodebuild run) but hasn't replied in ~2.5 h.

- 2026-10-18 01:40: Codex MP = REQUEST CHANGES: unbounded reply-timeout waiter; N4 lacks forced overlap and final-union checks; the surviving live-page mutation (epoch/rebuilding) isn't covered single-process; plus 3 minors. Codex INT = REQUEST CHANGES: a coordinator↔outbox retain cycle; the bridge can forward a stale flush after unbind; plus 2 minors. Both are fixing. WATCHDOG in progress; SKEL still pending.

- 2026-10-18 01:35: INT done (13 tests / 14 cases, 2×2 clean-stack runs green, 2 mutations killed, S21 backend test added, S10 → M3). Codex reviewing INT and MP.

- 2026-10-18 01:30: FORM DONE (tip 1f731f8; UI 2/2 incl. AX XXXL, 21 host tests; Codex r2 approved). It lands on ios/m2-ui after the M1 cut. The FORM agent is reassigned to WATCHDOG (xcodebuild timeout, sim-cap enforcement). MP merged-head gates green (fdb465b); in Codex review.

- 2026-10-18 01:20: MP done (24 real-process cases, 6 mutations, 3× serial green, ~3 s); merged m1-data as c51ce9b; Codex review running. FORM's AX XXXL test found a real label-wrap bug (fixed, rerunning). INT awaiting its clean-stack gate result. SKEL overdue on its final report (6 dirty files). Load ~300 with 2 sims.

- 2026-10-18 01:00: FORM Codex r2: all resolved, no new majors (awaiting the watchdog UI rerun). INT checkpoint ffbd1ab: 13/13 against live docker twice; clean-stack `make ios-integration` ×2 running. MP checkpoint d172f7d (sync MP cases, N4). SKEL 8b6895c (widget gallery stall fix); final report pending. Load ~36.

- 2026-10-18 00:45: Load ~275. The simulator cap was breached (SKEL booted iOS 26 and 27 together); the orchestrator shut down SKEL's idle iOS 26 clone. FORM's UI-plan xcodebuild has hung 41 min at 0% CPU after the tests (a recurring post-test hang) → the backlog item for an xcodebuild watchdog is promoted to next. FORM review fixes are in a845530 (21 host tests); Codex r2 is running. MP and INT have no new commits for 65 min; status requested.

- 2026-10-18 00:05: FORM Codex r1 = REQUEST CHANGES. Major: duplicate auto-save on rapid chip taps (needs an in-flight latch). Minors: the 400 ms initial focus can steal focus; Same-as-last leaves stale errors. An AX-size UI check was added to the scope. SKEL tree clean at d41e97e, awaiting its final report. MP checkpoint b3e793a (ProcessHelper agent, loopback server); INT checkpoint de4ff8c (OutboxSignal routed to the coordinator).

- 2026-10-17 23:50: **Merged into ios/m1-data:** testiso (07b489e) and SYNC+OUTBOX combined (b69bb6a, through 424e656). Gate on the merge: backend 684 passed + alembic check clean; ios-core-test green; ios-lint clean. OUTBOX r5 residual (mandatory DB transactions can wait out the busy timeout) is documented in outbox.md §10. SKEL findings: AppIntentsPackage on static QuickrData breaks iOS 26.0 (intents dropped); AppIntentsTesting can't load on the iOS 26 runtime → Intents plan runs only on iOS 27+ (CI gap to decide).

- 2026-10-17 23:40: INT started (ios/m1-int from 54f0eee, ex-BUILDER agent; BUILDER accepted at 22865b8, merges at the M6 cut). OUTBOX r5 resolves r4; last item: lease polling and post-deadline DB work. Final small fix requested; residual DB-busy time documented; the orchestrator verifies, with no more Codex rounds (diminishing returns). testiso r3: 4 of 5 resolved; `--all` namespace restriction plus a min-age floor requested, then done. FORM committed 74161b0 (form engine, UI test, screenshots). SKEL unresponsive for 53 min: its xcodebuild is idle at 0% CPU.

- 2026-10-17 23:35: MP started (ios/m1-mp from 99a5473, SYNC agent). OUTBOX r4: still a fresh grace per send (refetch after stale_revision) → one absolute shutdown deadline. testiso r2: worktree-name collisions (needs a path hash), prune can drop a live lazy peer, `ensure()` race on CREATE. FORM: UI test green, screenshots captured, check-ios running; xcodebuild sometimes hangs after tests (CI timeout watch → backlog). Load spiked again to ~350 (2 sims + Spotlight/photos + Docker VM).

- 2026-10-17 23:10: Load ~7. SYNC APPROVED (Codex r3 on the veto table 08b2bec). OUTBOX r3: unbounded wait resolved; new Major: grace runs past the extension budget, and a commit-before-grace reconciliation test is needed. BUILDER r2: both majors resolved; Major: gen-casefold isn't wired into `make vectors`, plus pinning the Unicode/Python version. Combined SYNC+OUTBOX head: ios/m1-outbox 99a5473. testiso fixes in progress; SKEL and FORM running.

- 2026-10-17 22:55: Load dropped to ~12; FORM resumed. Codex: SYNC r2 resolves 1,2,4,5; still Major: an overwriteable `reset_veto` (needs a monotonic veto set). OUTBOX r2 resolves all round-1 items; new Major: the shutdown wait is unbounded when the sender ignores cancellation (liveness). testiso: REQUEST CHANGES (no per-worktree default DB; unowned `_peer` DBs). BUILDER: REQUEST CHANGES (canonical-equivalence vs Python code-point equality for duplicates and compat). All four are fixing. Combined SYNC+OUTBOX head: ios/m1-outbox e29232c. SKEL committed the intents proof b4fc26b.

- 2026-10-17 22:40: OUTBOX Codex r1 = REQUEST CHANGES (no blockers; all 8 author spec resolutions agreed). Majors: a definitive answer is lost when cancellation races the timer; failed deletes are missing from the C0 guard. Minors: the coalescing test is weak; `source` is filled only when nil. Stubs major declined (MP/INT). Fixes in progress on top of 69bb903. SYNC merged OUTBOX and dropped its duplicate (39b64fb). SKEL committed 5ea1e46 (debug dylib off for intents metadata).

- 2026-10-17 22:45: BUILDER logic done (0d72c47 + vectors 171d5fd; 115 tests, 108+32+17 server-generated vectors); Codex review running. SYNC fixed Codex majors 1–5 (52e9b96 + Store veto 7a6d071) and is merging OUTBOX to remove the duplicate `OutboxResolution`; SYNC Codex round 2 follows. testiso `make check` green; 3× backend runs pending.

- 2026-10-17 22:30: OUTBOX done (8947602): all 61 matrix cases covered (17 MP/INT stubs disabled, each pointing to its simulation), 267 Data tests green, 4 mutation checks all caught. 8 spec ambiguities resolved by the author; Codex review running (`codex-m1-outbox.md`). Its OutboxSyncEffects contract was handed to SYNC. Flake noted: `DuePerformanceTests.widgetTimelinesComputeQuickly` under load → backlog.

- 2026-10-17 22:10: load ~340, mostly from simulator daemons (SKEL's iOS 27 clone) plus mediaanalysisd and other sessions' MCP servers; CPU itself isn't pegged. Mitigation: `IOS_JOBS=4` (ed91119); FORM paused at WIP 844f0bf; BUILDER asked to pause. Critical path still running: SYNC (Codex majors 1–4 in progress), OUTBOX (matrix), SKEL (intents/widget UI tests), testiso (1b157fe → Codex review next).

- 2026-10-17 17:04–21:00: every agent stopped at the account usage limit (reset 20:40). No work lost: uncommitted changes stayed in the worktrees, and all 6 agents were resumed at 21:00. B7 finished just before the limit; Codex round 1 → `open` (More…) action accepted into the spec; `fmt` simplified to shortest round-trip with no rounding.

- 2026-10-17: WP vectors done and gate green. Findings to carry into the Swift due port: DST gaps can merge slots, slots must be sorted by UTC instant, the early window can be tiny, `next_due_at` ignores `schedule_since`.
- 2026-10-17: Plan v3 finalised (PR #6). Notebook merged to `main` (PR #7).
  macOS upgraded to 27.0.1. MobileBuildMCP configured. M0 started with 3
  sub-agents.
