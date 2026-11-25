1. **[P2] Lock Screen Live Activity stops scaling at accessibility text sizes — [RunActivityWidget.swift:99](/Users/richie/code/quickr-worktrees/t2-m2-la/ios/Widgets/RunActivityWidget.swift:99).** The new `dynamicTypeSize(...WidgetStyle.largestTypeSize)` caps the entire activity at `xxLarge`. Previously, its text could follow the user’s larger accessibility setting. The spec calls for that cap on widgets, but does not specify it for the Live Activity. This affects the timers, segment name and controls for users who rely on larger text. Please preserve accessibility-size scaling and verify the constrained layout on a device.

I treated the first review’s findings 2 and 4 as justified by the stated 160 pt constraint, and did not repeat them. The lap fields and alert data are deferred to I2-LA-FIELDS. I reviewed the diff and related code but did not run tests or device rendering checks.

## Resolutions (i2-la)

1. **Stands, justified.** The Lock Screen activity is a fixed canvas: iOS
   truncates it above 160 pt (round 1, finding 2), so its text cannot grow the
   way the run screen's does. Uncapped accessibility sizes would push the
   control row (Lap, Pause, Stop) below the cut, which is a worse outcome for
   the same users than text held at `xxLarge`; the cap is the one
   active-surfaces.md §7 already gives the widgets (`WidgetStyle.largestTypeSize`),
   which share the constraint. VoiceOver labels are unaffected, and the app's
   run screen and active card keep full scaling. Proposed §7 wording (for the
   lead; specs are not edited on WP branches): "Widgets and the Live Activity
   cap at `xxLarge`". The device checklist (M2-DEV) verifies the rendering at
   the largest text size.
