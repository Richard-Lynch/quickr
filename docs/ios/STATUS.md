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

- M1 review backlog: one pool per (server, gen) per process (StorePartitions.swift:221 opens a new pool on every open); write façade (enqueue plus requestFlush); dead StoreLink probes and empty service protocols removed by WIRE; widget intents on placeholder topics until M4; coalesce per-call Tasks in `handle(_:)`/`requestFlush` bursts. All are folded into WIRE where they apply.
- STORE test: `LeaseTimeSamplingTests` sleeps 50 ms assuming a writer is already waiting; under load it passes but proves less. Replace the sleep with a barrier (found by FLAKE).
- **Milestone checklist item (from SKEL):** before every milestone PR that touches intents or widgets, run `ios/scripts/widget-proof.sh` on an iOS 26.0 clone first, then on 27; and run the Intents plan locally on 27 via check-ios. CI (iOS 26.x, Unit plan) only covers the `IntentMetadataTests` guard. Add the same requirement to the WIDGETS and INTENTS done-criteria.
- App composition root (SKEL follow-up / M2 SYNC-UX): wire `Outbox(onSignal: coordinator.handle)` and `OutboxFlushBridge.bind(scheduler)` on every store open, reset and server switch (nil when there's no store), per INT.
- S10 (APNs register vs a rotated epoch) is deferred to M3 REG; the stub carries an owner note.
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
| W3   | **B7 merged** (bb4729a, 2 Codex rounds: `open` More… action, no-rounding `fmt` with bit-exact vectors, batched scheduler prep). OUTBOX, SYNC, SKEL building; test isolation in progress; **FORM** (M2) started on `ios/m2-form`         | —              | [~] running                                                                                                                                                                                                                           |
| W4   | MP · INT · SPIKE · FORM (M2)                                                                                                                                                                                                            | —              | [ ]                                                                                                                                                                                                                                   |

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
