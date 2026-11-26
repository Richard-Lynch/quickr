# M2 #209 (wfields): Codex review

## Round 1 (on 431a7715)

1. **P1 — Alert changes depend on an opportunistic reload.** [TopicWidget.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/Widgets/TopicWidget.swift:49) creates every future entry with the same `topic` snapshot, including its current alert. The `.after(alert)` policy only asks WidgetKit to rebuild the timeline; it does not guarantee a reload at that instant. If WidgetKit delays it, the expired alert remains at `0:00`, and later scheduled entries keep showing it instead of the next alert or no alert. Generate entries with alert state appropriate to their dates, including alert transitions, and retain the reload as a refresh mechanism.

2. **P2 — The medium layout can compress the clocks and alert at large text sizes.** [WidgetViews.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/QuickrKit/Sources/QuickrUI/Widgets/WidgetViews.swift:276) places the segment timer, two minimum 8-point gaps, and an unconstrained alert label in the same 332-point content width. Long alert labels, long elapsed times, and xxLarge text compete for that width; neither clock has protected layout priority, and the alert label is the only text explicitly limited to one line. This can truncate or compress timing information even though the alert label is the expendable content. Give the clocks and countdown priority, constrain the label, and verify the result at xxLarge.

3. **P2 — The requested widget rendering coverage is missing.** [WidgetGalleryView.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/App/Debug/WidgetGalleryView.swift:130) adds an alert fixture, but [WidgetViewsUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/UITests/WidgetViewsUITests.swift:43) never locates or asserts it; its screenshots also do not navigate to that fixture. The new host tests check the display model, not whether the headline, alert, clocks, and controls fit or are accessible in the rendered widget. Section 9 calls for timed small and medium screenshots with a lap primary and alert, including light, dark, and tinted appearances. Add those checks, including xxLarge and a long alert label, so the layout regression above is detectable.

The review is based on the diff and source inspection; I did not run simulator rendering or tests.
### Resolution

1. Fixed: `WidgetReader.topicByAlert` reads the topic again from each pending alert (up to the horizon and 8 alerts) and `WidgetTimeline.entries` gives each entry the value current at its date; the reload at an alert stays for one no entry follows. Tests: `TimedWidgetTests.theTopicIsReadAgainFromEachPendingAlert`, `WidgetDataTests.entriesTakeTheValueCurrentAtTheirDate`.
2. Fixed: the segment timer and the countdown get `layoutPriority`, the alert line is `lineLimit(1)`, so a long label truncates first.
3. Stands: UI tests and gallery screenshots are I2-UITEST's (this WP has no simulator). The new fixture `widget.medium.timed.alert` is handed to I2-UITEST via the lead, to assert and photograph in light, dark, tinted and at the capped size.

## Round 2 (on b967e3e6)

1. **[P2] Timeline truncation can leave an expired alert visible** — [WidgetTimeline.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/QuickrKit/Sources/QuickrCore/Widgets/WidgetTimeline.swift:56), [TopicWidget.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/Widgets/TopicWidget.swift:51). The merged dates are truncated to 48, but the reload policy uses the alert from the *last read topic*, even if the entry that switches to that topic was truncated. For example, if the retained final entry shows alert A and A’s transition falls beyond the cap, `shown.last` may have no pending alert, so the timeline is not explicitly rebuilt at A. The widget can remain at `0:00` past A until WidgetKit reloads it. Derive the fallback alert from the value of the last retained entry, and cover a full timeline with an alert transition beyond the cap.

2. **[P2] Alert passage now causes unnecessary widget and Control reloads** — [WidgetReader.swift](/Users/richie/code/quickr-worktrees/t2-m2-wfields/ios/QuickrKit/Sources/QuickrData/Widgets/WidgetReader.swift:47). `dueList(now:)` now puts the time-dependent next alert in each run state, while both `WidgetFingerprint` and `ControlFingerprint` compare that entire state. On the next store observation after an alert passes, both fingerprints change even though the topic widget already has a timeline entry for that boundary and the Control does not show the alert. This spends reload budget and departs from the surrounding reload-gate idiom. Exclude time-derived alert fields from the fingerprints, with a test across an alert boundary.

The requested gallery UI assertion remains deferred to I2-UITEST as stated. I could not verify the widget layouts visually in this review; no simulator was available.
### Resolution

1. Fixed: the reload's alert is the last retained entry's (`entries.last?.value`), not the last read topic's. Test: the capped case in `WidgetDataTests.entriesTakeTheValueCurrentAtTheirDate`.
2. Fixed: `WidgetFingerprint` and `ControlFingerprint` compare the run state without `alert_at`/`alert_label`. Test: `TimedWidgetTests.anAlertPassingSpendsNoReload`.

## Round 3 (on 3288930d)

No remaining or new findings identified.

The prior timeline-cap and reload-gate fixes are present, and their regression tests cover the reported cases. The widget rendering checks remain deferred to I2-UITEST as recorded in the review history.

I could not access GitHub issue #209 from this environment or verify layouts in a simulator. The review is based on the branch diff, checked-in spec, review history, and source inspection; I did not run the tests.