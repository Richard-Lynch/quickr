1. **[P2] Watcher tests do not verify that observation resources are released.** [ResumeOfferWatchTests.swift:82](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/QuickrKit/Tests/QuickrDataTests/Runs/ResumeOfferWatchTests.swift:82) checks that the outer `watchOffer` call returns after the toast disappears, but it never checks the stream’s `onTermination` or that the observing task and store observation stop. The same gap applies when an offer lapses or the caller is cancelled. Those are the lifetime guarantees most likely to regress in this two-task implementation.

2. **[P2] The expiry test can pass without checking the boundary.** [ResumeOfferWatchTests.swift:74](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/QuickrKit/Tests/QuickrDataTests/Runs/ResumeOfferWatchTests.swift:74) relies on 50 calls to `Task.yield()` to let the watcher consume the offer and check the clock. Yielding provides no readiness guarantee, so the assertion at exactly 15 minutes can run before the watcher has inspected the offer. Use a synchronization point that confirms the offer was consumed and the clock was checked before advancing time. The 20 yields in the toast-disappearance test have the same readiness weakness.

3. **[P2] Round 3’s dismissal-wiring coverage remains incomplete.** [RunViews.swift:167](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:167) now passes the refresh stream and the toast callbacks, but the new tests call `watchOffer` directly with a synthetic stream. They do not exercise `watchResume`, a held action toast, or an external store change. Thus the round 3 resolution correctly describes the helper coverage, but “fixed” overstates coverage of the app wiring and cross-process refresh path.

The implementation addresses round 3’s three identified behavior defects: it supplies the refresh stream, checks expiry against the observed stop, and dismisses after observation failure or completion. I found no definite main-actor isolation violation, production busy loop, or task-lifetime leak in the changed code. The review was static; I did not run the tests.
---

## Resolutions (round 4)

1. **Fixed, and it found a real gap.** The tests now watch the stream's `onTermination`. Breaking out
   of the `for await` on a lapsed offer did **not** terminate a stream something else still held;
   the observer now keeps iterating (`where !watch.lapsed`) until the watch cancels it, so every
   exit (lapse, toast gone, caller cancelled) ends the observation. New test `cancelledEnds`; the
   lapse, expiry and gone cases assert termination too.
2. **Fixed.** No yield counts: the rig counts clock reads (the watch reads the clock only once it
   holds an offer), and the tests wait (bounded) for a read before asserting the 15-minute
   boundary or removing the toast. Five consecutive runs green.
3. **Stands, reworded.** Round 3's resolution now says the helper is fixed and tested and the App's
   `watchResume` wiring (refresh stream, toast stack callbacks) has no dedicated test: it is three
   closures over `ResumableRun.watchOffer`, and the stop toast's Resume path itself is driven on the
   simulator by `RunUITests.testStopToastOffersResume` and `testUndoResumeKeepsTheStop`.
