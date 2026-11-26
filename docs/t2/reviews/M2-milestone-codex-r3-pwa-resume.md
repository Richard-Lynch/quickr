# M2 milestone review: Codex, round 3 (the PWA half of M2-RESUME, #295)

**Scope.** `git diff 4f701725 e8fb11b1 -- frontend`: #295, squash-merged into
`t2/m2`. Codex's output follows unchanged; the resolutions are below it. The
fresh Claude review of the same delta is in
[`M2-milestone-claude-pwa-resume.md`](M2-milestone-claude-pwa-resume.md).

---

1. **Medium — A queued reopen can show controls before acknowledgment.** [RunPanel.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/RunPanel.tsx:69) and [ActiveTopicCard.tsx](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/topics/ActiveTopicCard.tsx:71) rely on `run.resuming`, but M1 sets that flag only for a projection created from an entry with no local run row. If the stopped run is still in the local view—for example, its stop is queued offline—a queued reopen instead displays normal controls before the reopen is acknowledged. This violates row 11 and allows subsequent actions during the pending reopen. The existing pending-ack tests exercise the entry-only projection, leaving this path uncovered.

2. **Medium — Resume can target a different stop from the one checked or displayed.** [reopen.ts](/Users/richie/code/quickr-worktrees/t2-m2-review/frontend/src/components/runs/reopen.ts:144) passes no expected terminal to `tap`, and M1’s `tapRun` rebuilds the local view and prefers the run row’s current `terminal_id`. If the run is resumed and stopped again between the toast’s check and the serialized tap, the old toast can reopen the new stop instead of refusing; the same issue applies to a stale idle offer. Preserve and validate the selected terminal through enqueueing, and test a re-stop in that interval.

The reviewed tests cover expiry, ordinary terminal targeting, toast refresh, and undo confirmation. I did not find a remaining pending-M1 seam or duplicated control in the changed surfaces. I did not run the test suite; this was a read-only review.

---

## Resolutions (M2-REVIEW)

1. **Medium, a queued reopen on a local run row shows controls.** **Stands, by
   design.**
   - "Resuming…" (§1.2 row 11, timers2.md §5.3) is the projection of a reopen
     sent *from an entry*, when no run row is local. When the row is local, M1's
     fold applies the queued reopen to it optimistically, as it applies every
     queued tap. The run is then Running, and later taps queue behind the
     reopen in order.
   - iOS has the same rule (`run.resuming`, #275).
   - Hiding the controls on an optimistic reopen would freeze the run screen
     after every offline Resume.
2. **Medium, a stale offer can re-target a re-stop.** **Filed as #297.** The
   offer can retarget only if the run is resumed and stopped again between the
   check and the serialised tap. The server then voids or applies the reopen
   with a notice, and no entry is lost. The fix is an expected terminal on
   reopen taps, which belongs in M1's `lib/runs/actions.ts`.
