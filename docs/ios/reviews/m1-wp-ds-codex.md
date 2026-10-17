# Codex review: M1 WP ds (round 1)

**REQUEST CHANGES**

1. **Major — integer stepping can crash.** `ios/QuickrKit/Sources/QuickrUI/Logic/NumberStepRule.swift:74`: parsing accepts finite values outside `Int` range, then formatting performs a trapping conversion. For an unbounded integer question, paste `1e30` and tap either step button. **Fix:** validate representability before conversion or use nontrapping numeric formatting; handle arithmetic overflow too. Add regression tests for large positive/negative values and boundary values.

2. **Major — quick-chip confirmation has a cancellation race.** `ios/QuickrKit/Sources/QuickrUI/Components/Chips.swift:249`: changing `confirmed` cancels the previous `.task`, but `try?` swallows cancellation and the old task still writes `confirmed = nil`, potentially clearing the new confirmation immediately. Logging the same option again also leaves the task ID unchanged, so its 1.6-second interval does not restart. **Fix:** use a unique confirmation generation per successful log and return on cancellation; test consecutive same/different-option logs.

3. **Major — small controls violate the 44-point target requirement.** `ios/QuickrKit/Sources/QuickrUI/Components/Buttons.swift:22,65,155`: small text buttons have a 36-point minimum height; small icon buttons have a 36×36 frame with no expanded interaction area. **Fix:** retain the small visual treatment inside an explicit ≥44×44 hit area. Verify adjacent controls do not overlap.

4. **Major — chip accessibility does not implement the advertised selection semantics.** `ios/QuickrKit/Sources/QuickrUI/Components/Chips.swift:89,118,164`: radio and checkbox roles largely collapse to ordinary buttons; limit-blocked chips remain announced as enabled, despite silently ignoring activation. `ChipGrid` provides neither an accessible question/group label nor selection-count/limit announcements. **Fix:** expose appropriate native toggle/selection semantics, announce unavailable state while preserving discoverability, and provide group context plus count/limit values. Verify with VoiceOver, including reaching and leaving the limit.

5. **Major — new tests are not registered.** `ios/QuickrKit/Package.swift:18`: `QuickrDesignTests` is absent from `targets`, so ordinary `swift test` never executes any of the added DS tests. This is separate from the intentionally deferred resources entry. **Fix:** register the test target with its required dependencies and demonstrate discovery/execution.

6. **Minor — fixed stepper height undermines Dynamic Type.** `ios/QuickrKit/Sources/QuickrUI/Components/NumberStepper.swift:49,118`: fonts scale correctly through `.custom(...relativeTo:)`, but the field and buttons remain fixed at 44/52 points. Large accessibility sizes can clip enlarged content. **Fix:** use scalable/minimum dimensions and verify accessibility text sizes.

All 26 light/dark color pairs match `index.css`. Comma decimals and negative input are explicitly supported; toast defaults correctly encode 6s/3.5s and a three-item maximum. Font registration uses process scope and thread-safe static initialization, appropriately covering separate app/extension processes. Bundled OFL headers declare no Reserved Font Names; retaining family names for these instances raises no evident RFN issue.

Tile slots suit later TILES/FORM work. Widgets can reuse tokens/fonts, but interactive logging needs separate App Intent-backed controls; these closure-based buttons and editable steppers are not directly reusable widget interactions.

Review was static; tests were not run in the read-only environment.