1. **P1 — [RunViews.swift:110](/Users/richie/code/quickr-worktrees/t2-m2-lastate/ios/App/Runs/RunViews.swift:110): The reconstructed timer drops lap types and their alerts.** `TopicTimer(steps:)` defaults `laps` and `variables` to empty arrays. Consequently, the run screen and active card cannot show alerts configured for a typed lap, and presentation actions cannot resolve the next lap type’s label from the pinned timer. Step alerts remain available because they are carried by each `Step`. The presentation needs the full pinned-version timer; `LocalRun` currently exposes only its steps.

The **14 open cases are correct**: the vector file has 11 running and 3 paused cases. I found no weakened assertions in the diff; the existing per-case assertions remain in place.
---

## Resolution (i2-la-fields)

Reviewed diff: `git diff 1388e8a4..HEAD` (commit d670e6b0).

1. **P1, RunViews.swift:110 — stands for this PR, filed as #206.** The finding is right that `LocalRun.timer`
   rebuilds the timer from `steps` alone, so `laps` (and lap-type alerts) are empty. This is not a regression
   of this PR: before the merge `TopicTimer` had no lap types at all, and the line's behaviour is unchanged
   (only `init(steps:)` as a function reference had to become a closure). The real fix is for `LocalRun`
   to carry `VersionBook.Info.timer`, which lives in `QuickrData/Store/RunOverlay.swift`, an M1 file
   (I1-CORE/I1-SYNC); M2 can't land it. The proposed diff is in #206 and in the lead's note. The Live
   Activity path (I2-LA-FIELDS) resolves the pinned timer itself and doesn't depend on it.

The 14 open cases and the unchanged per-case assertions were confirmed by Codex.
