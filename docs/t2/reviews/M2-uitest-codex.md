# M2 I2-UITEST: Codex review

`codex exec -s read-only` over `git diff origin/t2/m2...HEAD` (prompt per wp-common.md).

## Round 1 (on 81208f1e)

1. **[P1] The required accessibility-size layouts have no automated coverage** — [TileUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/TileUITests.swift:108), [RunUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/RunUITests.swift:53). The new tests run only at the default text size and assert horizontal control rows. The spec requires the active card’s controls and the run screen’s secondary controls to stack at accessibility sizes, and explicitly calls for an XXXL home test. The committed screenshots document one rendering but cannot catch a future clipping, overlap, ordering, or reachability regression. Add an accessibility-size variant that asserts the stacked frames and that each control remains hittable.

2. **[P1] The run-screen test does not establish that the table contains no controls** — [RunUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/RunUITests.swift:84). Counting buttons whose labels begin with “Lap” and checking whether the *row itself* is a button still passes if the row contains an independently accessible child button, or if the old `run.lap` control has a different label. The spec explicitly requires the table to have no buttons and `run.lap` to be absent. Assert both against the table and its descendants, including after recording a lap.
3. **[P2] The specified lap → pause → resume flow is missing** — [RunUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/RunUITests.swift:92). The new stopwatch flow goes straight from Lap to Stop. The existing pause/resume flow uses a stepped timer, so it cannot detect a regression where a paused lap loses its primary, Pause fails to become Resume, or Lap behaves incorrectly while paused. Exercise pause and resume on this lap run before stopping it.
4. **[P2] Timed accessory widgets and alert-line evidence are absent** — [WidgetViewsUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/WidgetViewsUITests.swift:93). The added gallery coverage captures only small and medium timed widgets, and none of its assertions checks an alert line. The spec calls for timed small, medium, and accessory gallery screenshots with a lap primary and an alert line in light, dark, and tinted appearances. The existing Lock Screen test covers unrelated idle fixtures, so it does not close this gap.
5. **[P2] The Active now test can pass without proving the partition or ordering** — [HomeTests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/HomeTests.swift:210). `morning.count` only counts currently materialized accessibility elements in a lazy list, and the comparisons for the other tiles are skipped when they do not exist. A duplicate Morning farther down the list, or an incorrectly ordered section whose tiles have not materialized, can therefore pass. Scroll through the list to check the topic appears once, and assert the relevant section ordering without conditional skips.
6. **[P2] The evidence does not demonstrate the work package’s required test run** — [README.md](/Users/richie/code/quickr-worktrees/t2-m2-uitest/docs/t2/evidence/M2/after/README.md:60). The documented result bundle is for an uncommitted screenshot test, while the flow bundle names only the lap test. The work package requires the listed UI tests and the Unit plan, including `WidgetControlTests`, `RunIntentHandlerTests`, and `LiveActivityTapTests`, to pass on the clone, with result paths and non-zero test counts. Provide those results and counts; the screenshots alone do not establish acceptance.
I reviewed the diff and specifications; I did not run the simulator tests.

### Resolution

1. Fixed (b49f4c22): `RunUITests.testRunControlsStackAtAnAccessibilitySize` (XXXL: primary ≥ 72 pt,
   Stop over Pause, all full width and hittable, the stacked Pause works) and
   `TileUITests.testActiveCardStacksAtAnAccessibilitySize` (XXXL: Next over a full-width Stop). They
   use Morning, as the stacking doesn't depend on the primary's kind and publishing through the
   builder at XXXL needs corner taps on the Timed switch.
2. Fixed: `assertNoControlsInTable` runs before and after a lap: no `run.lap`, and (round 2) no
   button overlapping any `run.step.*` row.
3. Fixed: pause and resume on the stopwatch; Resume replaces Pause, Lap stays the primary, enabled
   and once (§1.2 row 8).
4. Stands. The gallery has no timed accessory fixtures (its Lock Screen page is I2-WIDGETS' scope,
   unchanged since), and `alertLine` / `alert_at` are M1's (I1-CORE, M1-LA-STATE), nil today, so
   there is no alert line to assert. The WP's scope names the gallery's light/dark/tinted/a11y
   screenshots, which the new test takes for every timed fixture. Live Activity rendering: #202.
5. Fixed in part: the ordering checks no longer skip a missing tile. The fake server has three
   topics, all on the first screen at the default size, so nothing is lazily unmaterialised and
   the count of `tile.morning` covers every section.
6. Answered in the PR, not the README: the PR lists every result bundle with its counts (the
   targeted tests, the Unit plan with `WidgetControlTests` 10, `RunIntentHandlerTests` 3,
   `LiveActivityTapTests` 3, the full UI plan, the e2e run). The README names the bundles its
   images came from, as M2-BEFORE's does.

## Round 2 (on b49f4c22)

1. **[P2] The Active now test still cannot prove that the topic appears only once** — [HomeTests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/HomeTests.swift:210). The count covers only accessibility elements currently materialized by the lazy list. Requiring Workout and Mood to exist fixes the conditional ordering checks, but a duplicate Morning farther down can remain unmaterialized and escape the count. Scroll through the full list and check the inactive sections for Morning as well.

2. **[P2] Timed accessory-widget and alert-line coverage remains absent** — [WidgetViewsUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/WidgetViewsUITests.swift:93). The new test captures timed small and medium fixtures only, with no assertion for an alert line. The existing accessory test uses idle fixtures. Spec §9 calls for timed small, medium, and accessory screenshots with a lap primary and alert line in light, dark, and tinted appearances.

3. **[P2] The documented results do not establish work-package acceptance** — [README.md](/Users/richie/code/quickr-worktrees/t2-m2-uitest/docs/t2/evidence/M2/after/README.md:59). The cited screenshot bundle ran an uncommitted test, and the flow bundle identifies only the lap test. There is no recorded result path and non-zero count for the required UI tests or the Unit plan’s `WidgetControlTests`, `RunIntentHandlerTests`, and `LiveActivityTapTests`. The last commit also changes tests after the documented captures. Record passing results for the final tests and named Unit suites.

4. **[P2] The table-control assertion can miss a control inside a row** — [RunUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/RunUITests.swift:159). Filtering buttons by whether their *top edge* is below the secondary controls is not a table-descendant assertion: a button overlapping that boundary, or a table element not materialized in the current viewport, is excluded. The explicit `run.lap` check closes one part of the original finding, but another accessible button in the table could still pass. Query the table or row descendants, including after a lap, and account for rows beyond the viewport.

5. **[P2] The accessibility-size card test does not verify Pause is reachable or below the headline** — [TileUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-uitest/ios/UITests/TileUITests.swift:174). It checks only that Pause is above the primary; that also passes if Pause stays in the title row, contrary to the specified accessibility layout. It never checks Pause’s hittability or 44-point target. Assert its position relative to the headline, its target size, and reachability after scrolling.

The last commit adds the missing stopwatch pause/resume flow and accessibility-size stacking checks. I reviewed the diff and specifications; I did not run the simulator tests.
### Resolution

1. Stands, as round 1 #5: three topics, all on screen; a duplicate Morning would be counted.
2. Stands, as round 1 #4.
3. Answered in the PR: the final tests' result bundles and the Unit plan's named suites with
   counts. The screenshot test is throwaway by design (as M2-BEFORE's), so it is cited by bundle.
4. Fixed: the check now takes the table's rows (`run.step.*`, one accessibility element each,
   `children: .ignore`, so no row can hold a child control), asserts each is on screen under the
   secondaries, and fails for any button whose frame intersects a row.
5. Fixed: Pause is under the headline, above the controls row, at least 44 pt tall, scrolled to
   and tapped (it becomes Resume).
