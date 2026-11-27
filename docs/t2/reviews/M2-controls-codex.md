1. **P2 — Primary labels no longer follow the specified Dynamic Type behavior** — [RunControls.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/App/Runs/RunControls.swift:27). The primary label omits the specified two-line limit, minimum scale factor and centered alignment. Long step or lap-type names, especially at accessibility sizes, can therefore produce an excessively tall or poorly aligned control instead of the prescribed two-line treatment.

2. **P2 — Typed lap rows lack their required badge** — [RunScreen.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/App/Runs/RunScreen.swift:334). `StepRow` renders only the row label, marker and duration; it never renders the neutral `QuickrBadge` for a typed lap required by §2.1. The table will not provide the specified visual distinction when typed laps arrive.

3. **P2 — Skip loses useful VoiceOver context** — [RunControls.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/App/Runs/RunControls.swift:130). The previous control announced the step position, such as “Skip Breakfast (step 3).” The new menu announces only the title. For timers with repeated step names, VoiceOver users can no longer distinguish which occurrence will be skipped. The changed UI test also removes the assertion that protected this behavior.

4. **P2 — The changed control layout has no UI coverage for its main acceptance criteria** — [RunUITests.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/UITests/RunUITests.swift:66). The existing flow is updated for the menu and new primary, but there is no test for a lap-primary run, the 72-point primary, duplicate controls, or stacked secondaries at accessibility text sizes. The model layout tests cannot verify the SwiftUI rendering. The plan assigns these view checks to the later I2-UITEST package, so they remain an integration requirement rather than evidence supplied by this diff.

The current M1 presentation model explicitly stubs alerts, typed lap data and reopen actions; I have not treated those absent upstream capabilities as standalone defects in this branch. I did not run simulator tests during this review.
---

## Resolution (i2-controls)

1. **Stands (no change needed).** The primary uses `.qr(.primary, size: .hero)`, and `QuickrButtonStyle` applies `lineLimit(2)`, `minimumScaleFactor(0.8)` and `multilineTextAlignment(.center)` for `.hero` at every size (`QuickrUI/Components/Buttons.swift`, `makeBody`). Repeating them on the label would duplicate the style.
2. **Stands (blocked on M1).** `RunSegment`/`RunOpenSegment` have no `lapType` in `t2/m2` (grep `lapType` in `QuickrCore/Runs`: no field). The badge needs that field (active-surfaces.md §8.2: `Segment.lapType` is M1's). It goes on the phase-2 remainder list for when M1's I1-CORE lands.
3. **Stands (spec).** active-surfaces.md §1.3 fixes the VoiceOver text for `skip(label)` as "Skip {label}". `RunAction.Kind.skip` carries only the label, so the position can't be derived without re-reading the steps (a per-kind lookup outside the §1.3 table). Step keys are unique and labels in practice are too; if that's not enough, it's a spec change for the lead.
4. **Stands (plan).** M2-plan assigns the view checks (lap primary, 72 pt, no duplication, XXXL stacking, screenshots) to I2-UITEST. This WP keeps R9 green with the minimal change the lead asked for. The layout model's no-duplication guarantee is covered by `RunControlsLayoutTests` ("Every action lands in exactly one slot").

---

# Round 2 (after the shared table move, f8d26bfb)

1. **P2 — A step named “Next” loses its label** — [RunActionLabel.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/QuickrKit/Sources/QuickrUI/Components/RunActionLabel.swift:13). The renderer treats every `.next(label: "Next")` as the steps-unknown fallback. A known step can also be named “Next”, in which case §1.3 requires “Next: Next”, visually and in VoiceOver. The action representation cannot distinguish those cases; carry the fallback explicitly rather than using a valid step label as a sentinel. The new test at [RunActionLabelTests.swift](/Users/richie/code/quickr-worktrees/t2-m2-controls/ios/QuickrKit/Tests/QuickrDesignTests/RunActionLabelTests.swift:16) covers the fallback but does not exercise this collision.

I did not run simulator or host tests during this review.
## Resolution (i2-controls), round 2

1. **Stands (M1-owned, proposed to the lead).** The collision is real, but only for a step literally labelled "Next". The sentinel is M1's: `RunPresentation.actions` encodes the steps-unknown fallback as `.next(label: "Next")` (timers2.md §10), and `RunAction.Kind` is M1's (`QuickrCore/Runs/*`), which this WP may not edit. A renderer-side fix can't tell the two cases apart. Rendering every `.next` as "Next: {label}" would put "Next: Next" on every steps-unknown run, the common case, which is worse than mis-titling a step named "Next". Proposed M1 change for the lead: make the label optional, `next(label: String?)`, with nil for the fallback; the table then drops the comparison.
