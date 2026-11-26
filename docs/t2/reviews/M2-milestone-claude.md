# M2 milestone review: fresh Claude (Opus) reviewer

**Scope.** M2's own changes on `t2/m2` at `bc7bbed8`:
`git diff c938cae9 bc7bbed8 -- . ':!docs/t2'` (73 files). `c938cae9` is a
synthetic base: `feat/t2` at `f8d8a8ef` (M1 included) merged with the
`t2/m3a-tokens` shared branch at `eb9607b3`, so the diff leaves out the work of
other milestones. The reviewer was given the code, the spec
(`docs/specs/active-surfaces.md`), the plan and the user's requirements, and not
the lead's or M2-REVIEW's conclusions. It ran no tests, and its findings come
from reading the code.

The PWA half of M2-RESUME (`t2/m2-fresume`, PR still open at review time) is not
in this diff. Findings it already fixes are marked as such. Its own delta is
reviewed in phase 2.

## Findings (verbatim summary) and outcomes

| #   | Sev    | Finding                                                                                                                                                                                                                           | Outcome                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | high   | PWA "Undo resume…" does nothing: `RunPanel.tsx:103-110` drops `revert` ("pending T2-M1"), and M1's `actions` returns it in place of `discard`, so a resumed run can be neither undone nor discarded.                              | **Covered by M2-RESUME (PWA)**, `t2/m2-fresume` commit `8fa56d5f` (RunPanel: Undo resume… with its confirmation, sent as the run's discard). Re-checked in phase 2 after that PR merges.                                                                                                                                                                                                                                                                                           |
| 2   | high   | The PWA never offers Resume (`RecordPage.tsx:168-181` `reopenOf` and `reopenOfStop` return null; no idle tile Resume; no Resume in the active card's stop toast).                                                                 | **Covered by M2-RESUME (PWA)**, `8fa56d5f` (`reopen.ts`: `useReopenOffer`/`useReopenAfterStop`; RecordPage, TopicTile, the card's toast) and `b7d16b62` (tests pin the 15-minute window). Phase 2.                                                                                                                                                                                                                                                                                 |
| 3   | high   | A PWA run resuming from its entry shows live controls: `ActiveTopicCard.isResuming = () => false`; `RunPanel` infers resuming from `list.length === 0`; the running bar has no resuming check.                                    | Card and panel: **covered by M2-RESUME (PWA)** `8fa56d5f` (`run.resuming`). **Running bar: fixed here**, `4d5d076b` (`useOpenRunPrimary` returns null for `run.resuming`): the PWA RESUME branch doesn't touch `RunningBar.tsx`. Its test needs that branch's resume fixtures (`test/resume.ts`), so it lands in phase 2.                                                                                                                                                          |
| 4   | medium | The Timer Control and the small widget can say "Stop" while the press does Next: `WidgetTopic.autoButton` reads `nextLabel` during a lap, which M1 never sets to a pending step; `TimedWidgetTests` proved an impossible fixture. | **Fixed**, `bd0476d1`: `WidgetReader` stores `RunWrites.autoTap(run)` as `WidgetTopic.runAuto`, and the one-button surfaces show it, so M2 renders what M1's Auto decides (§5.3, §8.2). The impossible fixtures are gone. New `TimedWidgetTests.aLapBeforeAPendingStepAutoIsNextAsThePressIs` is red without the fix (mutation-checked). Round 2 (`237f6797`) adds the fingerprints, the press's outcome and `WidgetControlTests.theTimerControlOfALapBeforeAPendingStepSaysNext`. |
| 5   | medium | No PWA test covers revert, resume or resuming.                                                                                                                                                                                    | **Covered by M2-RESUME (PWA)**: `Resume.test.tsx` (new), `TopicTile.test.tsx`, `ActiveTopicCard.test.tsx`, `RunControls.test.tsx` in `8fa56d5f`. Re-checked in phase 2.                                                                                                                                                                                                                                                                                                            |
| 6   | low    | Stale `TimedWidgetTests` ("once I2-LA lands") that hand-set `display.buttons`.                                                                                                                                                    | **Fixed**, `bd0476d1`: the overrides are gone and the tests assert the real `RunActivityDisplay` primary.                                                                                                                                                                                                                                                                                                                                                                          |
| 7   | low    | The iOS active card keeps its own copy of rows 11 and 14 (`isResuming`, `busy`) where M1's `RunActions.actions(for:)` already handles them.                                                                                       | **Fixed**, `0a19817c`: the card takes `RunActions.actions(for:)`, as the run screen does. Codex round 2 checked that the busy state stays observable (`RunActions` is `@Observable`).                                                                                                                                                                                                                                                                                              |
| 8   | low    | The run screen's hero primary, the iOS card's primary and the PWA `run-primary` use the accent, not the topic tint (§2.2, §6.1).                                                                                                  | **Out of scope, filed #286**: theming M2's surfaces is T2-WIRE item 3 (`docs/specs/t2-plan.md`). The iOS card and the PWA card are already themed. The rest is colour only.                                                                                                                                                                                                                                                                                                        |
| 9   | low    | The spec contradicts itself: §2.2 lists "Resume run (`run.reopen`, idle screen only)" in the overflow menu, while §2.4 makes it the secondary under Start.                                                                        | **Spec text proposed to the lead** (specs aren't edited on WP branches). The code follows the role (secondary) and the no-duplication rule. Proposed §2.2 wording: "lists, in order, Skip (`run.skip`, disabled when M1 gives none), Undo resume… (`run.revert`), Discard run… (`run.discard`). Resume run (`run.reopen`) is the idle screen's secondary under Start (§2.4), never a menu item."                                                                                   |
| 10  | low    | PWA reduced motion: `Button` base, More and the sheet items scale on press without `motion-reduce`.                                                                                                                               | **Fixed**, `4d5d076b`, then corrected in `6787c4c0`: Codex round 2 showed that Tailwind 4's `scale-*` isn't cancelled by `transform-none`, so all M2 press scales now use `motion-reduce:active:scale-none`. That covers the active card and running bar classes that predate this review. The compiled CSS was checked: the reduced-motion rule comes later at equal specificity.                                                                                                 |
| 11  | low    | The "Resuming…" badge differs: the PWA card shows "Resuming… · {headline}", iOS "Resuming…" alone.                                                                                                                                | **Stands.** Both match §3.3 ("the 'Resuming…' badge in place of 'Running'"). On iOS the headline before the ack is the projected one, and the screenshots and UI tests of #275 pin "Resuming…". The PWA text is in the open PWA RESUME PR. Aligning the two is cosmetic and left as is.                                                                                                                                                                                            |
| 12  | low    | Live Activity button heights (≥ 56/≥ 44 pt, §4.2) are unproven: labels with `minHeight` 44/32 inside system bordered styles.                                                                                                      | **Device-only**, and stands: the extension's `ActivityViewContext` can't be rendered in the app gallery (#202). The Lock Screen item of `docs/t2/device-checklist.md` (M2) checks that the button row is fully visible and every label legible at the capped text size.                                                                                                                                                                                                            |

## Checked and fine (the reviewer's list)

- The layout model on both platforms places actions by role only and drops
  nothing. The table tests cover all 14 rows, plus the out-of-window case and
  reopen/revert placement.
- The iOS run screen:
  - order is header → controls → table, with no buttons in the table;
  - hero ≥ 72 pt, secondaries 56 pt, stacking at accessibility sizes;
  - the overflow menu is destructive-last;
  - revert confirms, and Stop/Lap haptics match §2.5;
  - "Resuming…" with no controls comes from `RunActions.actions(for:)`.
- The iOS Resume target is `entry.timing.terminalId` through
  `ResumableRun.latest` and `RunOverlay.resumable`. The window is re-checked on
  the run clock, and the toast re-checks the store and closes itself when the
  offer ends.
- The iOS "Active now" split is UI-level and ordered by start time; "Due now"
  and the badge are unchanged. The section pulse uses `withQRAnimation` behind a
  reduce-motion guard, and no bare `withAnimation` was added.
- The iOS active card:
  - VoiceOver order is summary, then primary, Stop, Pause;
  - targets are 44 pt;
  - the controls stack at accessibility sizes.
- Live Activity:
  - the §4.1 primary rule, including the step check;
  - `[primary, pause|resume, stop]`, and `[primary, stop]` in the island;
  - the compact "L4" or step number;
  - the alert hidden while paused;
  - the countdown range guarded with `min(Date(), at)`.
- Widget timelines add entries at each alert, and the change-detection
  fingerprints ignore the alert.
- The PWA running bar hides runs whose controls are already on screen and never
  shows Stop.
- There are no duplicated controls on any surface.
- Debug code (`UITestClockControl`, the fake-server holds) is behind `#if DEBUG`
  and the UI-test flag. No `console.log` or `print` was added.
