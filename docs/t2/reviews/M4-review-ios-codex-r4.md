The r3 race is addressed in HEAD: `holdsEditTimes` becomes true while Remove is being enqueued, and the screen passes that state to the edit model.

- **[P2] Missing regression test for the full race.** [EntriesModelTests+Actions.swift](/Users/richie/code/quickr-worktrees/t2-m4-review-ios/ios/QuickrKit/Tests/QuickrDataTests/Entries/EntriesModelTests+Actions.swift:180) checks the action model’s hold during the tap, but does not suspend enqueueing, attempt to open Edit times, and attempt a save. It therefore does not verify that the hold reaches the screen and prevents a save during that window.

I found no other new correctness bugs, spec drift against §1.2 or §3.2, or `t2-plan.md` ownership violations in the branch diff. This was a static review; I did not run the tests.