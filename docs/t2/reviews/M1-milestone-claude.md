# M1 milestone review: Claude (Opus) reviewer

Base: t2/m1 at 4eac3ef6, reviewed as the diff against origin/feat/t2.

## P1: blocks merge

**P1-1. PWA reports a running run as `stopped` after reopen → revert → reopen.**

- Where: `frontend/src/lib/runs/localView.ts:205` (`statusOf`).
- Violates: timers2 §3.4, §4.1 and §5.3, and parity with iOS.
- Input: `start, next, stop s1, reopen o1→s1, discard (revert), reopen o2→s1`.
  That is the vector `reopen-revert-then-reopen-again`. Both the fold and the
  server say `running`.
- Cause: `reverted(state, events)` is still true, because `o1` remains voided
  `reverted`. The function returns `'stopped'` before it looks at the open
  status. iOS guards against this with `!state.status.isOpen`
  (`RunOverlay.swift:243`).
- Effect, even with nothing queued and even when the reopen happened on another
  device:
  - the topic shows idle;
  - the entry is not hidden;
  - Start is offered;
  - the reopen open-run guard is skipped.
- Fix: put `state.status !== 'running' && state.status !== 'paused' &&` in front
  of the check, and add a localView test for this sequence.

**P1-2. Lock-screen (Live Activity) and intent taps don't reschedule alerts on
iOS.**

- Where:
  - `ios/App/LiveActivity/AppEnvironment+LiveActivity.swift:45-47`
    (`handleActivityTap`);
  - `ios/App/Intents/RunIntentHandler.swift:53-54`;
  - `ios/App/Runs/RunAlertPresence.swift:72-98`.
- Violates: timers2 §9.1 (one trigger is "this device's taps") and the user's
  requirement "fire on iOS even when the phone is locked".
- Cause: the scheduler only runs from `RootView`'s `.task(id:)` and from the
  became-active observer.
  - If the app was killed, the tap runs in a background process with no
    `RootView`.
  - If the app was suspended, the store hold is released and the process
    suspends again as soon as `perform` returns.
  - Both handlers explicitly call `liveActivities.reconcile()`. They do nothing
    for alerts.
- Example: start a 60 s rest lap with a t/2 alert, lock the phone, and press
  Pause on the Live Activity. The half-way request still fires. Lap leaves the
  old lap's alerts pending and never schedules the new ones.
- Fix: in both handlers, after the write and while the hold is still held, run
  `await runAlertScheduler(session).reconcile(try await store.runAlertInput())`.
  Add a test that drives the tap handler with no `RootView` and a fake
  notification centre.

## P2: should fix

**P2-1. A reopen can overtake a queued finish, which then fails with 409
`run_open` (both clients).**

- Where: `frontend/src/lib/outbox/kinds.ts:188` and
  `ios/QuickrKit/Sources/QuickrData/Outbox/OutboxFlush.swift:75`. This is a gap
  in timers2 §5.5.
- Input: a version with a required question.
  1. Start, then stop (the run goes to finishing).
  2. Finish with answers. The finish gets a 5xx and backs off (or is left
     `uncertain` on iOS).
  3. Resume.
- Result: the reopen waits only for its target stop and for the start, so it
  applies first. The finish then hits `runs.py:437` and gets 409 `run_open`,
  which is terminal. The answers are stranded in a failed item.
- Fix: on both clients, a reopen also waits for the run's earlier pending
  finish. Add a §5.5 sentence and a test per platform.

**P2-2. An iOS alert can be delivered twice if it fires during a reconcile.**

- Where:
  `ios/QuickrKit/Sources/QuickrData/Notifications/RunAlertScheduler.swift:85,120-126`
  and `SystemNotificationCenter.swift:80`.
- Sequence:
  1. `desired()` takes `now`.
  2. `apply` awaits `pendingNotificationRequests()`.
  3. If the alert is delivered in between, it is no longer pending, so it gets
     re-added with `max(1, fireAt − now)` and fires again about 1 s later.
- Reconciles run on every sync page and every offset re-estimate, so this is not
  a rare window.
- Fix: after fetching the pending set, drop desired requests whose `fireAt` is
  within about 1 s of `Date()` unless they are already pending.

**P2-3. The PWA RunAction model is still a stub beyond `resumable`.**

- Where: `frontend/src/components/runs/model.ts`:
  - `:147`: `nextTypeLabel` is always null;
  - `:156`: it always returns `discard`, never `revert`;
  - `headline`: no counter, no "· lap n", no "n of m";
  - `alertLine`: always null.
- Violates: timers2 §10, R18, and active-surfaces §1.1/§1.2.
- iOS `RunPresentation.swift:128-190` and `:147` implement all of these.
- `model.test.ts:395-431` asserts the stubs.
- Fix: port the iOS logic (I1-CORE #160 lists the formats) and flip the tests to
  the §1.2 table.

**P2-4. Test evidence: the PWA builder is never checked against the server's
builder verdicts.**

- No file under `frontend/` reads `shared/fixtures/builder-vectors.json`
  (`timers[]` / `questions[]`). `builderUi.vectors.test.ts` is the generator of
  `builder-ui-vectors.json`, so it can't check the PWA against the server.
- Fix: add `builder.vectors.test.ts`.

## P3: minor

1. **A removed gap pause that absorbed a user pause is projected wrong until the
   ack.**
   - Where: `localView.ts:732` (`removeFromTiming`) and
     `RunOverlay+Reopen.swift:205` (`removing`); §3.4.
   - Input: the vector `reopen-while-paused-ends-pause`, then remove `002`. Both
     clients drop the whole 0:30–1:30 pause. The server keeps it under id `001`.
   - Fix: keep the part before the stop, or don't project a gap-pause remove at
     all.
2. **The PWA no-steps overlay never voids a tap `too_long`; iOS does**
   (`RunFold.overlay` `inRange`). The ack corrects it.
3. **PWA label trimming uses JS `trim()`; the server uses Python
   `str.strip()`.**
   - Where: `builder.ts:938,1051,1089` and `draftTimer` (~1349); §1.3.
   - `"\u0085"` is accepted by the PWA and gets a 422 from the server. `"﻿"` is
     "Required" on the PWA and accepted by the server.
   - Fix: use `serverStrip` from `frontend/src/lib/text.ts`.
4. **Run states stored before fold v4 have no `lap_count`.**
   - Pushes send `lap_count: null` (`push/live_activity.py:186`), and the API
     reports 0 (`schemas/api.py:1279` default) until the next event re-folds.
   - Fix: `state.get("lap_count", <count of lap segments>)`.
5. **MCP `run_action reopen` with no target fails on a run stopped before the
   deploy** (`mcp_server.py:440-443`). `terminal_id` is null, so it raises "the
   run isn't stopped: it is stopped". REST falls back via `_terminal_stop`.
   - Fix: pass `target=None` through to the server.
6. **Local Live Activity updates use the v1 overload**
   (`RunActivityCenter.swift:106-110`) and blank the server's `alert_at` and
   `next_label`. This is M2's to fix; it has been handed to t2-m2-lead.
7. **Two open PWA tabs both play the same alert** (`RunAlerts.tsx:49,63`),
   because the record of fired alerts is in `sessionStorage`.
   - Fix: use `localStorage` or `BroadcastChannel`.
8. **A 0 s alert (`0s` or `t-t`) fires on the PWA (within the 30 s late window)
   but never on iOS**, which only schedules future instants. Make the two
   clients agree.

## Test evidence gaps

- No test covers reopen → revert → reopen in either client's local view.
- No test covers an alert reschedule from a tap handler.
- No test covers a reopen queued behind a retrying finish.
- No test covers delivery during a reconcile.
- No test covers removing a gap pause that absorbed a user pause.
- No test covers whitespace handling in timer labels.
- iOS `RunWire.State` and `WireTiming` are Decodable without a key-set assert on
  the raw JSON.
- `LiveActivityVectorTests` uses the timer overload, not the v1 overload that
  `RunActivityCenter` calls.

## Codex milestone review, part 2 (added by the lead)

**P2-5. iOS loses a queued remove in the resuming projection.**
- Where: `RunOverlay+Reopen.swift:108`. Spec: §5.3, R26.
- Repro: offline, remove a pause or lap boundary from a stopped entry. Then reopen that entry before the remove is acked.
- What goes wrong: `resuming` builds the run from the original stored timing and never applies the queued remove. Once the resuming run exists, `entryProjection` also skips removes for that run.
- Fix: apply any queued removes that came before the reopen to the stored timing before building the resuming state. Cover remove → reopen while offline. Check that the PWA (`localView.ts`) handles the same case, and fix it there too.

## Resolution (added by t2-m1-evidence)

Fixes landed on `t2/m1` in two PRs: [#262](https://github.com/Richard-Lynch/quickr/pull/262)
(PWA, merge `355ad4c9`) and [#263](https://github.com/Richard-Lynch/quickr/pull/263)
(iOS and backend, merge `26be76af`). The spec sentences came in the docs commit
`da126790`. The mapping comes from the two PR bodies. Each commit was checked
with `git log` on `origin/t2/m1`. Every test listed failed first, before its fix.

| Finding | Fixing PR and commit | Test |
| --- | --- | --- |
| P1-1 PWA `statusOf` after reopen → revert → reopen | #262 `5c769b83` | `localView.test.ts` "reopen → revert → reopen again is running (vector reopen-revert-then-reopen-again)" |
| P1-2 Live Activity and intent taps don't reschedule alerts | #263 `cc132444` | `QuickRTests/RunAlertTapTests` `activityTapsReschedule()`, `intentTapsReschedule()` (AppTests, no `RootView`, a recording notification centre) |
| P2-1 a reopen overtakes a queued finish (both clients) | #262 `c617dd08` (PWA); #263 `9324f351` (iOS); spec §5.5 in `da126790` | `runEvent.test.ts` "reopen-waits-for-pending-finish"; `RunOutboxTests` "M1-REVIEW P2-1 · §5.5: a reopen waits for its run's earlier uncertain finish…" |
| P2-2 iOS double delivery during a reconcile | #263 `288f0ac9`, `0629bf5a` | `RunAlertSchedulerTests` `deliveredDuringAPassIsNotRescheduled`, `dueNowStillPendingIsKept`, `addSuspendingPastTheNextAlert`, `replacementPastDuringThePass` |
| P2-3 PWA `RunAction` model stubbed beyond `resumable` | #262 `6ff0b34b` | `model.test.ts`: §1.2 rows 5, 6 and 10 typed (running, paused, timer null), the reverted reopen, "revert from the local view", the `headline` and `alertLine` suites |
| P2-4 PWA builder never checked against `builder-vectors.json` | #262 `1515a6e6` | `builder.vectors.test.ts`: 68 `timers[]` and 124 `questions[]` cases plus casefold. 16 failed before the fix |
| P2-5 (Codex part 2) queued remove lost in the resuming projection | #262 `dd8bf410` (PWA); #263 `8375ea32` (iOS) | `localView.test.ts` "remove → reopen offline: the resuming run has the queued remove applied (P2-5)"; `RunLocalViewTests/removeThenReopenOfAnEntryOffline` |
| P3-1 removed gap pause that absorbed a user pause | #262 `c15f0b19` (PWA, exact from the local view); #263 `5040286d` (iOS, pinned, not changed) | `localView.test.ts` "a removed gap pause that absorbed a user pause keeps it… (P3-1)", `actions.test.ts` "a remove of a gap pause says whether it absorbed a user pause (P3-1)"; `RunLocalViewTests/removeAGapPauseThatAbsorbedAUserPause`. The residue is deferred: #260 (iOS entry projection) and #261 (PWA remove from an entry) |
| P3-2 PWA no-steps overlay never voids `too_long` | #262 `915d84f3` | `localView.test.ts` "a pause or lap more than 7 days after the start is void too_long, as the fold (P3-2)" |
| P3-3 PWA label trimming differs from the server | #262 `1515a6e6` (`builderStrip`, Unicode `White_Space`, matching pydantic and iOS `BuilderText.strip`; not `serverStrip`, see #262 decision 1) | `builder.test.ts` "trims labels and keys as the server does… (P3-3)"; `builder.vectors.test.ts` `ws/*` |
| P3-4 pre-v4 run states have no `lap_count` | #263 `047558f3` | `test_runs_reopen.py::test_lap_count_falls_back_…` (RunOut), `test_live_activity_vectors.py::test_lap_count_falls_back_…` (push) |
| P3-5 MCP `reopen` with no target on a pre-v4 run | #263 `596d5686` | `test_mcp.py::test_run_action_reopen_without_a_target_on_a_state_stored_before_fold_v4` |
| P3-6 local Live Activity updates use the v1 overload | Not fixed in M1: `RunActivityCenter` is M2's (I2-LA-FIELDS). Handed to t2-m2-lead. No issue is filed | none in M1 |
| P3-7 two PWA tabs both play an alert | #262 `73bb8a08`, `98f74683` | `RunAlerts.test.tsx` "two tabs: an alert another tab fired (localStorage) does not fire here (P3-7)", "fires from memory when storage throws", "claims an alert under the cross-tab lock where Web Locks exist (P3-7)" |
| P3-8 a 0 s alert fires on the PWA but never on iOS | #262 `904d6ed0`; spec §9.1 in `da126790` (never fired, on either client) | `alerts.test.ts` "never plans an alert at the segment start (at_ms <= 0)… (P3-8)" |

The "Test evidence gaps" list is closed by the tests above:

- reopen → revert → reopen: P1-1.
- tap-handler reschedule: P1-2.
- reopen behind a retrying finish: P2-1.
- delivery during a reconcile: P2-2.
- absorbed gap-pause remove: P3-1.
- label whitespace: P3-3.
- `RunWire.State`/`WireTiming` key-set assert: #263 `587b17c5`, `RunFoldVectorTests/wireShapesCoverEveryKeyOfTheRawJSON`.

One gap stays open: `LiveActivityVectorTests` on the v1 overload. It goes with P3-6 to M2.
