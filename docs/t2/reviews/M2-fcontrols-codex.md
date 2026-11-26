1. **[P2] Control labels are cut off at enlarged text sizes** — [RunControls.tsx:127](/Users/richie/code/quickr-worktrees/t2-m2-fcontrols/frontend/src/components/runs/RunControls.tsx:127). The secondary controls remain in two columns beside the fixed-width More button, use fixed-height, non-wrapping `lg` buttons, and truncate their labels. At narrow widths or enlarged text sizes, Pause/Resume can become unreadable; the primary and overflow labels are also clamped or truncated. The accessible names help screen-reader users, but sighted users who enlarge text still need complete labels and controls that can grow or reflow. There is no test or evidence for this case.

2. **[P2] The future Resume offer uses a frozen eligibility time** — [RecordPage.tsx:228](/Users/richie/code/quickr-worktrees/t2-m2-fcontrols/frontend/src/pages/topic/RecordPage.tsx:228). `useServerNow(false)` captures the time when `TimedRecord` mounts and never advances. Once the M1 reopen implementation is connected, an idle page left open past the 15-minute window can continue offering Resume, and a page mounted long before a stop can evaluate eligibility using an older time. Use a clock that advances or arrange a refresh at expiry, and test the window boundary.

3. **[P2] The M1 integration seams silently leave required actions nonfunctional** — [RecordPage.tsx:168](/Users/richie/code/quickr-worktrees/t2-m2-fcontrols/frontend/src/pages/topic/RecordPage.tsx:168), [RunPanel.tsx:98](/Users/richie/code/quickr-worktrees/t2-m2-fcontrols/frontend/src/components/runs/RunPanel.tsx:98). The spec permits hiding Resume until the M1 provider exists, so its absence on this branch is expected. However, `reopenOf` and `reopenOfStop` unconditionally return `null`, and the panel silently ignores `revert`. Merely merging the provider will therefore not deliver the specified idle/toast Resume or Undo resume behavior. These need explicit integration work and end-to-end coverage when M1 lands; the current control tests only exercise their presentation with synthetic actions.

I found no duplicated active-run controls in the changed panel. This was a static review; I did not run the test suite.
---

## Resolutions (f2-controls, round 1)

1. **Fixed.** The secondaries row is now `flex flex-wrap` with each button `min-w-[7.5rem] flex-1`:
   on a narrow or zoomed viewport Pause/Resume and More wrap to a second line instead of
   truncating (checked at 300 px CSS width, the 390 px layout at ~130 % zoom). The primary's
   `line-clamp-2` is gone: the `hero` size is `min-h`, so a long "Next: {step}" wraps and the
   button grows. The "More" sheet items stay one line (`truncate`) because `Button size="lg"`
   fixes `h-14 whitespace-nowrap` and `cn` cannot override it; each keeps its full `aria-label`,
   and the only long overflow title is "Skip {step}", whose step name is also the headline.
2. **Fixed.** `TimedRecord` now uses `useServerNow(idle && Boolean(lastEntry?.timing))`: the
   clock ticks while a timed last entry could be resumable, so the offer is re-evaluated every
   second and disappears when `resumable` says the window has passed. The boundary itself is
   M1's `resumable` (stubbed false on this branch), so a window test belongs with its
   implementation; listed in the PR as pending M1.
3. **Stands (by design, recorded as pending M1).** The brief says: "If something you need from
   M1 (terminal_id, the resuming projection) doesn't exist yet, leave a named seam and list it
   as pending M1. Don't invent it." `reopenOf`/`reopenOfStop` (RecordPage) and the `revert`
   case (RunPanel) are those named seams; each doc comment says exactly what M1 must provide
   and what the body becomes. `revert` is unreachable today (`actions` never returns it). The
   PR lists the integration as follow-up work for the M1 merge, with end-to-end tests then.
