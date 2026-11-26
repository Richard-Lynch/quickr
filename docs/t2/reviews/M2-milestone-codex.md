# M2 milestone review: Codex, round 1

**Scope.** `git diff c938cae9 bc7bbed8` over M2's 73 code files. `c938cae9` is
a synthetic base, `feat/t2` `f8d8a8ef` plus `t2/m3a-tokens` `eb9607b3`, so the
work of other milestones is left out. Command:
`codex exec -s read-only -C <worktree> -o docs/t2/reviews/M2-milestone-codex.md "<prompt>" < /dev/null`.
The prompt asked for correctness, spec deviations, duplicated controls,
accessibility and Dynamic Type, test gaps, dead seams and stale markers. Codex's
output follows unchanged; the resolutions are below it.

---

1. **High — PWA stopped runs cannot be resumed from the requested surfaces.** [RecordPage.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/pages/topic/RecordPage.tsx:168) returns `null` even for a resumable entry, and `reopenOfStop()` also always returns `null`. The idle home tile likewise only renders Start or Add details in [RunTile.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunTile.tsx:73), and the active-card Stop toast has no Resume action in [useActiveCardControls.ts](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/topics/useActiveCardControls.ts:49). Consequently, the PWA offers no way to resume from the idle tile, record page or stop toast, contrary to active-surfaces.md §§3.3 and 6.3. The “pending T2-M1” comments describe a seam that is now resolvable.

2. **High — Queued reopens expose controls before acknowledgement.** [ActiveTopicCard.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/topics/ActiveTopicCard.tsx:72) hard-codes `isResuming` to false despite `LocalRun.resuming` now existing. The panel similarly infers resuming from an empty action list in [RunPanel.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunPanel.tsx:73), while the running bar also calls the action model without checking `run.resuming` in [RunningBar.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunningBar.tsx:139). That model cannot express the queued-reopen projection, so a reopen initiated elsewhere can show Running and actionable controls while still unacknowledged. Active-surfaces.md §§1.2 and 6.3 require “Resuming…” and no controls until the ack. The test asserting that no run can be resuming preserves the obsolete stub rather than testing the real projection.

3. **Medium — Undo resume is displayed but does nothing.** [RunPanel.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunPanel.tsx:103) ignores `revert`, based on a stale comment that M1 will never return it. The landed action model does return `revert` for a reopened run, so its overflow item appears but selecting it neither confirms nor sends the revert. This violates active-surfaces.md §§1.2 and 6.1 and leaves the user unable to undo a resume from the panel.

4. **Medium — The PWA resume and bar acceptance criteria lack the required integration proof.** [RunTile.test.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunTile.test.tsx:201) exercises the bar’s Next and untyped Lap cases, but does not prove that its primary matches the panel **in every state**, as M2-plan.md’s F2-BAR acceptance requires. It also has no idle-tile Resume-within-15-minutes and expiry test required by active-surfaces.md §9; the actual Resume paths are absent as described in finding 1. Add tests that drive the real surfaces and queued-reopen projection, rather than only supplying a synthetic `resuming` prop to the card.

This was a static review of the specified M2 diff and its surrounding action model. I did not run the test suites or simulator checks.

---

## Resolutions (M2-REVIEW)

The PWA half of M2-RESUME (`t2/m2-fresume`) was still open at review time. It
covers findings 1–3, and its delta is reviewed again in phase 2.

1. **High, PWA Resume missing.** **Covered by M2-RESUME (PWA)**: `8fa56d5f`
   (Resume on the record page, the idle tile and both stop toasts, aimed at
   `entry.timing.terminal_id`) and `b7d16b62`. Phase 2 checks it after the
   merge.
2. **High, queued reopens show controls.**
   - Card and panel: **covered by** `8fa56d5f` (`LocalRun.resuming`).
   - **Running bar: fixed here** in `4d5d076b`: no primary for a resuming run.
     That branch doesn't touch `RunningBar.tsx`. The bar's resuming test needs
     the branch's resume fixtures, so it lands in phase 2.
3. **Medium, Undo resume does nothing.** **Covered by** `8fa56d5f`.
4. **Medium, bar "in every state" and the idle-tile Resume test.**
   - The bar ↔ panel test (`RunTile.test.tsx`, "the running bar's primary is the
     run panel's") covers §1.2 rows 4–9: title, icon, enabled state and the
     tap's event.
   - Row 14 (cooldown) has its own test ("is off while the topic's tap cooldown
     runs").
   - Missing: the typed lap ("Lap → Rest", #173) and row 11 (resuming: no bar
     primary). The fixture can't express lap types until the PWA RESUME branch's
     `LocalRun` fixtures land, so both cases are added in phase 2.
   - The idle-tile Resume within and after 15 minutes is in that branch's
     `TopicTile.test.tsx`.

Stale markers. A grep of M2's files for `pending M1`, `phase 2`, `Seam`,
`I2-…`, `TODO`, `console.log` and `print(` found:

- PWA `RunPanel.tsx:103`, `ActiveTopicCard.tsx:70` and its test `:244`, and
  `RecordPage.tsx:164,175`: all removed by `8fa56d5f`.
- iOS `WidgetGalleryView.swift:59` ("once I2-LA lands"): fixed in `6d979db9`.
  The gallery's typed states now carry lap types, so they show "Lap → Rest".

There is no debug code: `UITestClockControl` is `#if DEBUG` and UI-test only.
