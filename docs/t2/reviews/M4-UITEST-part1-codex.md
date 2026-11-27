I found three issues in the added tests and seed.

1. **[P2] Activity assertions can run before the five entries have synced.** [StatsUITests.swift:139](/Users/richie/code/quickr-worktrees/t2-m4-uitest/ios/UITests/StatsUITests.swift:139) waits for the caption to exist, but the activity strip observes the local store and can render an initial count before the feed has finished applying. The immediate equality and week-label assertions can therefore fail depending on sync timing. Wait for the caption’s label to become `"5 entries in the last 12 weeks"` before checking the columns.

2. **[P2] The week-label expectation can disagree across a local date boundary.** [StatsUITests.swift:141](/Users/richie/code/quickr-worktrees/t2-m4-uitest/ios/UITests/StatsUITests.swift:141) calculates expectations from the test runner’s `Date()` after launch, while the fake calculates each entry’s date when it serves it and the app calculates its own current day. A run spanning midnight can use different seed and expectation dates; a Sunday-to-Monday transition also shifts every column. The helper otherwise uses calendar-day arithmetic rather than fixed 24-hour intervals, so an ordinary DST transition alone does not invalidate the calculation. Pin a shared clock and time zone for the fake, app and test, and cover a DST transition and Sunday/Monday boundary with fixed dates.

3. **[P2] The required entry-detail flow is still untested.** [EntriesTests.swift:39](/Users/richie/code/quickr-worktrees/t2-m4-uitest/ios/UITests/EntriesTests.swift:39) stops at the row. Content-display §7 calls for opening the timed entry, removing a lap, checking that the segment count drops and confirming that the edited badge stays absent. This is part 1, so that may be planned for the follow-up, but the branch does not yet meet that UI-test requirement. Add the flow using a fake run that accepts the remove event and returns the updated entry.

The requested cross-checks otherwise line up:

- The row’s `"5:00 · Run 3 · Rest 2 · Effort: 7"` and `"5 minutes, 5 laps"` match the summary and spoken-chip implementations. The lap-card counts and duration expectations also match the seeded laps and `TimingOverviewText`.
- The feed sequence is contiguous: the typed seed starts after any `FakeTiming` entry, and its version, topic and entries advance from there. The serialized timing fields match `TimingDTO`, including `step`, pause IDs and the optional v2 fields.
- I found no violation of the listed shared-file or ownership rules in this diff. The explicitly listed shared files are untouched; the new fake file belongs to the creating milestone, and the two UI-test files are M4-owned.

This was a static review; I did not run the XCUITests.