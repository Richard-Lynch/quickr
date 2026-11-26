1. **[P2] The stop toast can still display a Resume action that does nothing.** [RunViews.swift:144](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:144) rechecks eligibility on tap, so the round 1 change prevents an invalid reopen. It does not resolve the stale offer: if another run starts or the entry is edited while the toast is visible, Resume remains displayed and silently does nothing. The spec calls for the action while the entry is resumable. Update or dismiss the action when eligibility changes, and test an intervening start or edit.

2. **[P2] The run screen’s expiry and offset rescheduling remain untested.** [RunScreen.swift:95](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunScreen.swift:95) now uses a separate `TimelineView` schedule, but the tile test advances the offset past expiry; it does not exercise the screen’s schedule or an offset moving backward before the original deadline. The pure `ResumableRun` tests cannot establish that SwiftUI redraws and reschedules correctly. Add screen coverage for expiry and offset changes in both directions.

The other round 1 resolutions appear correct on static review: the widget uses the pinned timer, candidate selection matches the overlay’s ordering, tile expiry has its own schedule, and the confirmed revert flow has coverage. The fixed cooldown sleeps remain a test reliability concern, although the cooldown itself is time-based.

Review was static; I did not run the simulator or host tests.
---

## Resolutions (round 2)

1. **Fixed.** `showStopOutcome` keeps the toast's id and `watchResume` observes
   `LocalStore.observeResumable` for the topic: the toast is dismissed as soon as the store's
   latest stop is no longer this run (a later start, an edit, another device's stop), or when
   OQ-1's window closes (polled on the run clock while the toast is up, which matters under
   VoiceOver, where action toasts stay until dismissed). The tap's re-check stays for the race.
   The rule it relies on (what the store offers after a start or a newer stop) is host-tested in
   `ResumableRunTests`; the dismissal wiring itself has no dedicated simulator test.
2. **Fixed (forward), stands (backward).** `TileUITests.testIdleTileOffersResumeWithin15Min` now
   opens the idle run screen (`quickr://t/tiktok/run`), checks its `run.reopen` under Start and
   not in the menu, then moves the run clock 16 minutes ahead and asserts the screen's Resume
   goes, then the tile's. An offset moving backward needs a real wait of the remaining window on
   the simulator; it is covered by construction (the `TimelineView` schedule is recomputed from
   `RunTicker.offsetMs`, which the body observes) and by `ResumableRun.closes(offsetMs:)` /
   `isOffered(at:)` on the host.

Cooldown sleeps: as round 1 (#6).
