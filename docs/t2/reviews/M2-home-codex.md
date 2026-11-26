1. **[P2] The active card can truncate its total clock at accessibility sizes — [ActiveTopicCard.swift:94](/Users/richie/code/quickr-worktrees/t2-m2-home/ios/App/Home/Tiles/ActiveTopicCard.swift:94).** The segment clock and the single-line total remain in an `HStack` at every Dynamic Type size. At accessibility sizes, or for long durations, they can exceed the available width; the total has no wrapping or scaling fallback. Stack the clocks when they no longer fit and verify both values at XXXL.

2. **[P2] VoiceOver focus order does not reliably put Pause after Stop — [ActiveTopicCard.swift:127](/Users/richie/code/quickr-worktrees/t2-m2-home/ios/App/Home/Tiles/ActiveTopicCard.swift:127).** The summary, primary, and Stop receive sort priorities of 3, 2, and 1, but Pause/Resume has the default priority and sits in a different branch of the view hierarchy. The spec requires summary → primary → Stop → Pause. Give Pause an explicit position in the accessibility order and verify it with VoiceOver, including the stacked layout.

3. **[P2] The card’s clocks and badge are combined into one accessibility element, hiding the specified individual identifiers — [ActiveTopicCard.swift:118](/Users/richie/code/quickr-worktrees/t2-m2-home/ios/App/Home/Tiles/ActiveTopicCard.swift:118).** Combining the summary’s children makes the segment, total, and status unavailable as individually addressable accessibility elements despite assigning them `tile.<slug>.segment`, `tile.<slug>.total`, and `run.status`. This conflicts with the identifiers required by §3.2 and prevents UI tests from asserting those values. The combined VoiceOver presentation and the automation identifiers need to be reconciled and tested on the rendered accessibility tree.

4. **[P2] Active-card interactions and accessibility have no tests in this branch — [ActiveTopicCard.swift:26](/Users/richie/code/quickr-worktrees/t2-m2-home/ios/App/Home/Tiles/ActiveTopicCard.swift:26).** The added tests cover the model partition, but none exercise the new card: opening it, dispatching Lap/Next, Pause/Resume and Stop, avoiding duplicate controls, or the XXXL and VoiceOver layouts. The plan assigns `HomeTests` and `TileUITests` to the subsequent I2-UITEST package, so this is an outstanding integration requirement rather than evidence that those tests were omitted from this package.

The Resume and “Resuming…” implementations are currently stubs, but §8.2 explicitly permits those fallbacks until their M1 providers land. I did not treat them as standalone defects in this review.

---

## Resolutions (i2-home)

1. **Fixed.** The clocks sit in a `ViewThatFits`: segment and total side by side, or the total
   under the segment when they don't fit (accessibility sizes, long runs); the total is
   `fixedSize`, never truncated. Visual check at XXXL is I2-UITEST's screenshot.
2. **Fixed (made explicit).** Every focusable child of the card's `.contain` container has a sort
   priority: summary 3, primary 2, Stop 1, Pause/Resume 0. The title-row `HStack` is not an
   accessibility container, so all four are siblings of the card whichever layout is used.
   VoiceOver verification on the simulator belongs to I2-UITEST.
3. **Stands, raised with the lead.** §7 requires title + headline + clock as one combined
   VoiceOver element; §3.2 lists child ids on it. A combined element exposes one id, so the
   children's ids are kept as written but UI tests should read the combined summary's label.
   Proposed spec wording sent to the lead (no spec edit on this branch).
4. **Stands (plan).** The card's view tests are `HomeTests` / `TileUITests` in I2-UITEST per
   M2-plan.md; this WP's host test is `HomeModelTests.activePartition`.
