1. **[P2] Cross-process changes do not invalidate the toast.** [RunViews.swift:169](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:169) omits `session.refresh.stream()`. The store observation sees writes from this process, but needs that refresh stream to see another process’s commits and re-read on activation. A widget or App Intent can therefore start a run or change the eligible entry while the toast continues to offer Resume; its tap then silently does nothing. Pass the refresh stream and test an external change.

2. **[P2] The toast’s expiry is calculated from display time, not the stop.** [RunViews.swift:179](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:179) adds 15 minutes to the clock when the watcher starts. If stop processing is delayed, or the run clock offset changes between the stop and the watcher starting, the toast can remain after the actual stop window closes or disappear before it closes. Use the observed candidate’s `endedAt` and `isOffered(at:)`, and test delayed display and offset changes.

3. **[P2] An observation error leaves a stale action visible.** [RunViews.swift:173](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:173) ends the watcher without dismissing the toast. In particular, an actionable toast held by VoiceOver can remain visible until the separate expiry task runs, even though the store can no longer establish eligibility. Dismiss it on observation failure and cover that path.

4. **[P2] The dismissal wiring remains untested.** [RunViews.swift:156](/Users/richie/code/quickr-worktrees/t2-m2-resume/ios/App/Runs/RunViews.swift:156) introduces two unstructured tasks, but the added UI test waits for the toast to disappear normally before changing the clock. The store tests establish candidate selection, not that this toast is dismissed on a start, edit, expiry, or observation failure, nor that its watcher ends after dismissal. Add focused coverage with a held action toast and controllable clock/store events.

The round 2 resolution for the run screen adds forward-offset coverage, but its backward-offset case remains untested as the resolution acknowledges. The round 2 toast finding is only partially resolved because of findings 1–3. I found no main-actor isolation violation in the new watcher. Review was static; I did not run simulator or host tests.
---

## Resolutions (round 3)

The toast's watcher is now `ResumableRun.watchOffer` in QuickrData (host-testable); the App's
`watchResume` only wires the store, the run clock and the toast stack into it.

1. **Fixed.** `watchResume` observes with `session.refresh.stream()`, so another process's start,
   stop or edit (a widget, an App Intent) re-reads the offer.
2. **Fixed.** The window is the observed offer's own: `offer.isOffered(at: now())`, from its stop's
   `endedAt`, on the run clock read at each tick (so an offset change counts at once).
3. **Fixed.** An observation that fails or ends marks the offer lapsed and dismisses the toast.
4. **Fixed.** `ResumeOfferWatchTests` (5 tests, host): another run becomes the latest stop, no
   offer (a start or an edit), a failed and an ended observation, the window closing exactly after
   15 minutes on a moved clock, and a toast that went by itself (no dismissal; the watch ends).
   The backward-offset case on the run screen stands as in round 2.
