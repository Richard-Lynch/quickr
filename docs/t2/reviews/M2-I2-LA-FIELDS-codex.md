1. **[P1] A typed lap can announce the wrong action — [RunActivityDisplay.swift:169](/Users/richie/code/quickr-worktrees/t2-m2-lafields/ios/QuickrKit/Sources/QuickrCore/Runs/RunActivityDisplay.swift:169).** `lapType != nil` does not establish that `nextLabel` names the next lap type. The shared content-state producer gives a pending step priority over the next lap type. If a typed lap is open while a step remains pending, the Live Activity therefore shows and speaks “Lap → {step}” even though tapping Lap opens another lap. The content state alone does not disambiguate those two meanings; this needs a contract-level resolution or a conservative title. The added pending-step test covers only an **untyped** lap, so it misses this case.

2. **[P2] Reconciliation can change the alert solely because time passed — [RunActivityCenter.swift:193](/Users/richie/code/quickr-worktrees/t2-m2-lafields/ios/QuickrKit/Sources/QuickrData/LiveActivity/RunActivityCenter.swift:193).** Before an alert fires, its computed `alertAt` is stable across reconciles: it is anchored to the segment start and pauses. Once the clock crosses it, however, a reconcile with no run-state change selects the next alert or clears the field, producing an ActivityKit update. That is consistent with the timer spec’s selection at send time, but the new test’s fixed `now` does not establish stability across real reconciles or document this boundary. Add coverage for advancing time both before and past an alert, including multiple alerts, so the intended behavior and update frequency are explicit.

The primary-button decision matches §4.1, and the display suppresses alerts while paused even if the incoming state contains one. The snapshot reads the timer by the run’s pinned topic version within the same database read; I found no pinned-version correctness issue there. The diff does not change the listed M1-owned files. I did not run tests in this read-only review.
---

## Resolution (i2-la-fields)

Reviewed diff: `git diff 0ef5535d..fbdd1aa9` (base = t2/m2 + the M1 fold stack, PR #207).

1. **P1, typed lap with a step pending shows "Lap → {step}": stands, tracked in #208 (M1 contract).** That's right:
   the content state can't tell the two meanings of `next_label` apart in a typed lap. A conservative title
   (for example `step_count == 0` only) would drop "Lap → Rest" in the common timer2 shape (one warm-up step,
   then typed laps: `next_step` is nil after the warm-up and `next_label` really is the lap type), and every
   lap of a timer with steps would lose its title to cover a rarer case. The cause is the producer:
   timers2.md §8.1 says `next_label` in a lap is the next lap type, but `live_activity.py` and
   `RunActivityContent.state` (both M1's) put a pending step first. #208 proposes the contract fix plus a
   vector. Once it lands, M2's rule (`lap_type != nil` → `lapNextLabel = next_label`) is exactly right with
   no change. The untyped case (where `next_label` can only be a step) is handled and tested
   (`lapWithAStepPendingIsLap`).
2. **P2, time-only updates at alert boundaries: fixed with tests.** These are added in
   `LiveActivityReconcileTests`:
   - `alertBoundaries`: with a fixed snapshot, the plan is empty at 600, 700 and 959 s (before "Go" at 960 s).
     At 961 s it is exactly one update, which clears `alert_at` and `alert_label` and keeps the lap fields.
   - `severalAlertsInOrder`: two alerts listed out of `at_ms` order. The next one by `at_ms` is shown, then
     the later one, then none.

   This is the intended behaviour: one update per alert passed, which matches what the server's push does
   at send time (timers2.md §8.1).
