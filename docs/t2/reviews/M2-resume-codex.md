1. **[P1] The compact widget can display the wrong Auto action after a timer edit.** [WidgetTopic.swift:126](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/QuickrKit/Sources/QuickrCore/Widgets/WidgetTopic.swift:126) reads lap types from the topic’s current timer, while the write uses the open run’s pinned timer. If lap types are added or removed during a run, the widget can say “Stop” while tapping it records a lap, or say “Lap” while tapping it stops the run. The displayed action must use the same pinned configuration as the write; add coverage for both edit directions.

2. **[P2] The idle run screen can leave Resume visible after its window expires.** [RunScreen.swift:135](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunScreen.swift:135) schedules expiry using the current server offset, but the task is keyed only by `resumable`. If a later sync moves the offset backwards, the task wakes at the old deadline, finds Resume still eligible, and never schedules another wake-up. `clock` then stays fixed, so Resume can remain visible indefinitely. Reschedule when the offset changes, and test offset changes in both directions.

3. **[P2] The idle tile can show Resume for up to 30 seconds past the permitted window.** [TopicTile.swift:79](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Home/Tiles/TopicTile.swift:79) evaluates eligibility against Home’s periodically refreshed `now`, without scheduling an update at expiry. A tile left visible can therefore continue to offer an expired action until the next Home tick, contrary to the 15-minute limit. The new test jumps a full 16 minutes and does not exercise this boundary.

4. **[P2] Selecting the candidate by entry capture order can suppress a valid latest stop.** [LocalStore+Resume.swift:43](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/QuickrKit/Sources/QuickrData/Store/LocalStore+Resume.swift:43) takes the first timed entry from `StoreView.entries`, which sorts by `capturedAt`, then asks whether that entry is the latest stop. If an older timed entry has a later capture date, the eligibility check rejects it and the actual latest stop is never considered. Select the candidate by `timing.endedAt` and the same tie-break used by `RunOverlay.resumable`; cover entries whose capture and stop orders differ.

5. **[P2] The stop toast offers Resume without checking whether the stopped entry remains resumable.** [RunViews.swift:140](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:140) attaches the action to every saved outcome. The toast can outlive a subsequent start, an entry time edit, or a stop from another device, all of which invalidate the offer. Its closure also targets the run without rechecking eligibility. Observe or revalidate the entry’s resumable state before offering and executing the action, with a test for an intervening run or edit.

6. **[P3] The new resume UI tests rely on fixed sleeps and do not verify the screen’s expiry or revert flow.** [TileUITests+Resume.swift:49](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/UITests/TileUITests+Resume.swift:49) and [RunUITests+Resume.swift:82](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/UITests/RunUITests+Resume.swift:82) use fixed delays to get past cooldowns, which can race on a loaded simulator. The added tests also leave the idle run screen’s expiry and confirmed revert unexercised. Use an observable readiness condition or a controllable clock, and cover those flows.

Review was static; I did not run the simulator tests.
---

## Resolutions (round 1)

1. **Fixed.** `WidgetTopic.runLapTyped` (set by `WidgetReader.openRunLapTyped` from the open run's
   pinned timer, exactly as `RunWrites.autoTap` reads it: steps known and lap types present);
   `isLapTyped` uses it and falls back to the topic's current timer only without an open run (a
   Start pins that one). Test: `TimedWidgetTests.theOpenRunsPinnedTimerDecidesTheAutoButton`,
   both edit directions.
2. **Fixed.** The idle run screen no longer sleeps on a task keyed by `resumable`: `RunPanel`'s
   body is a `TimelineView(.explicit([resumable.closes(offsetMs:)]))`. The schedule is recomputed
   whenever the body is (the offset is observed through `RunTicker.offsetMs`), so an offset moving
   either way reschedules the re-read.
3. **Fixed.** The idle tile's Resume is inside the same kind of `TimelineView`, so it goes the
   moment the window closes, not at home's next 30 s tick.
4. **Fixed.** `ResumableRun.latest` takes the timed entry with the latest `timing.endedAt` (then
   id, `RunOverlay.resumable`'s order). Test: `RunLocalViewTests.resumableByTheStopNotTheCapture`
   (an older stop captured later than the latest one).
5. **Fixed.** The toast still offers Resume at once (a run stopped this moment is resumable), but
   the tap re-checks the store (`LocalStore.resumable(topicId:)`: still this run, still in the
   window) and otherwise does nothing.
6. **Partly fixed, partly stands.** Added `RunUITests.testUndoResumeKeepsTheStop` (Undo resume…
   from the menu, its confirmation, the stop kept, no gap pause). The 0.6 s sleeps stand: they
   wait out `RunActions.cooldown`, a fixed 450 ms of device time that load doesn't stretch, and
   they are the suites' existing idiom (`pastCooldown`, `afterCooldown`). The idle run screen's
   expiry is the same `ResumableRun.isOffered` + `closes` pair the tile's UI test drives
   (`testIdleTileOffersResumeWithin15Min`) and is host-tested in `ResumableRunTests`; a second
   simulator flow for it was not added.
