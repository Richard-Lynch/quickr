# M4 milestone review findings (triaged by t2-m4-lead)
Sources: Codex review (`M4-milestone-codex.md`) and an independent Claude review (Opus sub-agent; see M4-milestone-claude.md).

## Fix in PWA fix WP (t2/m4-review-fe)
- R2 (P2): EntriesPage list ignores the A14 projection. Map each listed entry through `projectedEntryTiming(…, outbox.items)` before SummaryLine/TimingChip, and show "Waiting to sync" when pending. Test: a queued remove changes the row's chip.
- C3 (P2): EntriesPage.tsx:62 falls back to the current questions while the versions query is pending or has failed. Render only the timing part until the entry's version questions are known. Test both the delayed and the failed versions lookup, plus a renamed question.
- R6 (P3): the OverviewPage Activity strip gives screen readers only the caption. Give each week column a visually hidden label, "Week of 3 Nov: 5 entries" (the iOS wording).
- R7 (P3): TimingSection's disabled Remove explains itself only in a `title` tooltip. Add aria-describedby with a hidden reason, or a muted note.

## Fix in iOS fix WP (t2/m4-review-ios)
- R1 (P1): EditModel.swift:298-306 timingEditUnavailable and EditScreen.swift:183-184. Edit times stays enabled while a Remove is queued, and that voids the Remove (run_edited). Gate it on actions.isPending with the message "Edit times once the removal has synced.". Host test: queue a remove, then openTimingEditor() doesn't open.
- C3 (P2): EntriesModel.swift:208 has the same fallback to the current questions. Show only the timing part until the version is known. Host test.
- R5 (P3): EntryTimingSection removeButton has the label "Remove" on every button. Change it to "Remove \(segment.label)" / "Remove pause, \(spoken)", and use a hint that covers both causes: "Starts at a step boundary: change it with Edit times".
- R8 (P3): Remove and Resume show nothing when the action isn't enqueued. Use the Bool result and an EntryToasts message on false, matching the PWA: "That can't be removed now" / "This run can't be resumed now".
- C4 (P3): ios/App/Debug/FakeTiming.swift:49 changes M1's seedFeed control flow outside the T2-M4 blocks. Move the change into one delimited block, or minimise it to a hook call.

## Docs (lead)
- R4: §4.1 amendment. Cards replace the v1 lap tiles when lap types exist; untyped-lap figures on mixed topics are #204.
- R9: §2 dated note. The tile wiring is T2-WIRE-F/I and the optimistic last_entry is #169, so neither is in M4.
- R10: TopicDTO.swift blocks. M3a agreed (t2-m3a-lead, 2026-11-25); record this in evidence.

## Decision pending (orchestrator)
- R3: list rows triple-state their content. Recommendation: drop the summary line on list rows that show the full AnswerGrid.

## Out of scope (stated in milestone PR)
- C1: tiles don't render TopicSummaryLine (T2-WIRE-I/F). C2: #169 optimistic last_entry (M1 outboxEffects). #197 stays open for the remainder.
