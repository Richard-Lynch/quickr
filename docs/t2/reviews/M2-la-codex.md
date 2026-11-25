1. **[P1] Lap button names the wrong next segment — [RunActivityDisplay.swift](/Users/richie/code/quickr-worktrees/t2-m2-la/ios/QuickrKit/Sources/QuickrCore/Runs/RunActivityDisplay.swift:129).** In the current content state, `nextLabel` is the next *step*, including while a lap is open. Tapping Lap opens another lap, but the activity now says, for example, “Lap → B” and VoiceOver says “Lap, then B.” The new test explicitly asserts that misleading result. Until I2-LA-FIELDS supplies a lap-type label with the new semantics, the Lap title should remain plain.

2. **[P2] Lock Screen controls do not meet the specified layout — [RunActivityWidget.swift](/Users/richie/code/quickr-worktrees/t2-m2-la/ios/Widgets/RunActivityWidget.swift:150).** Section 4.2 requires a full-width primary of at least 56 pt, with Pause and Stop in a second row. This puts all three in one row and gives the primary half the width. Besides departing from the acceptance design, it leaves long primary labels and the secondary labels competing for narrow space, especially at larger text sizes.

3. **[P2] Expanded Island does not reserve the specified width for the primary — [RunActivityWidget.swift](/Users/richie/code/quickr-worktrees/t2-m2-la/ios/Widgets/RunActivityWidget.swift:171).** Section 4.3 calls for a two-thirds/one-third split. Stop is instead fixed to its intrinsic width and the primary takes the remainder, so the proportions depend on the label and text size. Use an explicit proportional layout and verify it with a long primary label.

4. **[P2] The new single-row Lock Screen layout can truncate essential content at large text sizes — [RunActivityWidget.swift](/Users/richie/code/quickr-worktrees/t2-m2-la/ios/Widgets/RunActivityWidget.swift:80).** The large segment timer, single-line headline, total timer, and eventually alert line all share one horizontal row. On narrow screens or at the allowed `xxLarge` size, the headline and alert label have little space and can truncate. The spec places the headline and timer on separate lines; the branch adds no rendering coverage to establish that this compressed arrangement remains readable.

The work package explicitly defers populated lap counters and alerts to I2-LA-FIELDS, so their current nil fallbacks are not findings. I reviewed the diff and related code and specifications; I did not run the test suites or device rendering checks.

## Resolutions (i2-la)

1. **Fixed** (commit "plain Lap title until the state names the lap type"). The
   "Lap → {label}" title and the "Lap, then {label}" VoiceOver label now read a
   separate `RunActivityDisplay.lapNextLabel`, nil until I2-LA-FIELDS fills it
   from M1's `lap_type` / lap-time `next_label`; `nextLabel` keeps meaning the
   step Next would start. `lapWithAStepPendingIsLap` asserts the primary is
   `.lap` with the plain "Lap" title; `lapTitleNamesTheLapItOpens` pins the
   §1.3 titles once the label is present.
2. **Stands, justified.** Apple's ActivityKit documentation ("Displaying live
   data with Live Activities", Create the Lock Screen presentation): "The system
   may truncate a Live Activity if its height exceeds 160 points." The §4.2
   diagram is six rows: topic (≈22 pt), headline (≈20), segment timer at
   `largeTitle` (≈34), the alert line (≈16), a ≥ 56 pt primary and a ≥ 44 pt
   secondaries row, plus padding and spacing ≈ 200 pt without the alert; it
   cannot render untruncated, and what gets cut is the bottom row (Stop). The
   layout here keeps the spec's priorities inside the limit: the primary is
   first, `.borderedProminent`, accent, `controlSize(.large)`, ≥ 56 pt tall and
   half the width; Pause/Resume and Stop are `.bordered` (Stop in `danger`) in
   the same row, each ≥ 44 pt tall with a one-line, `minimumScaleFactor(0.8)`
   label; Dynamic Type is capped at the widgets' `xxLarge` (§7). The deviation
   and proposed spec wording are reported to the lead (spec changes are not made
   on WP branches). The widths are now explicit (`ProportionalRow`, finding 3).
3. **Fixed.** `ProportionalRow: Layout` gives the island row ⅔ / ⅓ and the Lock
   Screen row ½ / ¼ / ¼ regardless of the labels or text size.
4. **Stands, justified** by the same 160 pt limit: the headline cannot have its
   own line and keep two button rows, so it sits beside the segment timer and
   truncates with an ellipsis as the least essential item (the position badge
   stays on the top line and the headline is complete in the expanded island
   and the app). Type is capped at `xxLarge`; at that size "12:40" + "Get
   dressed" + the total fit a 361 pt activity. Rendering is device-only
   (M2-DEV checklist) and the widget gallery in I2-UITEST.
