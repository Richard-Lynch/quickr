# M2 milestone review: Codex, round 2 (the review's own fixes)

**Scope.** `git diff bc7bbed8 cdb15760`: the fixes from round 1 and the Claude
review. Codex's output follows unchanged; the resolutions are below it.

---

1. **P2 — Reduce Motion does not disable the press scale.** [Button.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/ui/Button.tsx:12), [RunningBar.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunningBar.tsx:106) and the changed controls use `motion-reduce:transform-none` alongside `active:scale-*`. Tailwind 4’s scale utilities set the individual CSS `scale` property, so setting `transform: none` does not cancel them. Buttons still shrink on press with Reduce Motion enabled, contrary to §7. Reset the scale itself under the media query and verify the computed style while pressed.

2. **P2 — Reload fingerprints omit the new Auto value.** [WidgetReader.swift](/Users/richie/code/quickr-worktrees/t2-m2-review/ios/QuickrKit/Sources/QuickrData/Widgets/WidgetReader.swift:129) now makes `runAuto` part of what the small widget and Timer Control display, but [WidgetTimeline.swift](/Users/richie/code/quickr-worktrees/t2-m2-review/ios/QuickrKit/Sources/QuickrCore/Widgets/WidgetTimeline.swift:105) excludes it from both fingerprints. If the locally available pinned timer or folded state changes Auto without changing the exported activity state, the reload gates can retain the old label and icon while the intent performs the new action. Include the displayed Auto value in both fingerprints and test a change where the activity state remains equal.

3. **P3 — The regression test does not verify the Control or the resulting step.** [TimedWidgetTests.swift](/Users/richie/code/quickr-worktrees/t2-m2-review/ios/QuickrKit/Tests/QuickrDataTests/Widgets/TimedWidgetTests.swift:191) verifies the reader’s compact button, but never constructs `TimerControlValue`; its final assertion only establishes that the run remains open. An incorrect Control detail or icon, or an Auto tap that laps instead of advancing, would pass. Assert the Control’s “Next” detail and chevron, then assert that the pending step actually opened.

The card’s busy-state read is observable: `RunActions` is `@Observable`, and `actions(for:)` reads `busyTopics` through `isBusy`, so I did not find a busy-state observation regression there. The running-bar resuming guard also matches row 11. I reviewed the diff and related code statically; I did not run the test suites.

---

## Resolutions (M2-REVIEW)

1. **P2, Reduce Motion doesn't cancel the press scale.** **Fixed** in
   `6787c4c0`.
   - Cause: Tailwind 4 compiles `active:scale-[0.97]` to the CSS `scale`
     property (`.active\:scale-\[0\.97\]:active{scale:.97}`), so
     `transform:none` left it in place. That includes the active card and
     running bar classes that predate this review.
   - Fix: every M2 press scale now has `motion-reduce:active:scale-none`. The
     built CSS emits `.motion-reduce\:active\:scale-none:active{scale:none}`
     inside the reduced-motion media query, after the scale rule and at equal
     specificity.
2. **P2, reload fingerprints omit `runAuto`.** **Fixed** in `237f6797`.
   `WidgetFingerprint` and `ControlFingerprint` carry `runAuto`, and
   `TimedWidgetTests.aLapBeforeAPendingStepAutoIsNextAsThePressIs` asserts that
   both fingerprints differ when only `runAuto` does.
3. **P3, the regression test doesn't check the Control or the step it opens.**
   **Fixed** in `237f6797`.
   - The host test asserts the press opened `Breakfast` (`stepIndex == 1`).
   - New `WidgetControlTests.theTimerControlOfALapBeforeAPendingStepSaysNext`
     (Unit plan, simulator) asserts the Control's "Next" detail, its chevron
     icon and the Auto intent. It runs in phase 2's `make check-ios`.
