# M2 milestone review: fresh Claude (Opus) reviewer, PWA half of M2-RESUME (#295)

**Scope.** `git diff 4f701725 e8fb11b1 -- frontend`, read against
active-surfaces.md §1.2, §1.3, §3.3, §6.1, §6.3 and timers2.md §3.3, §5.3, §5.5.
The reviewer had the code and the specs, not M2-REVIEW's conclusions. It ran
`Resume.test.tsx` (13/13) and no other tests.

**Verdict.** No high-severity bug:

- every Resume path aims at the right stop;
- stale toast taps are refused;
- the revert is not K6-coalesced;
- the panel, the card and the bar hide their controls while resuming;
- no `pending M1` seam is left.

## Findings and outcomes

| #   | Sev                 | Finding                                                                                                                                                          | Outcome                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | medium              | The stop toast, pinned for 15 minutes, covers Start in the phone's bottom bar (Start over Resume, 144 px; the toast at 92 px, z-50).                             | **Fixed**: the toast keeps its default action lifetime of 6 s, as on iOS, where `showStopOutcome` uses the default and dismisses early when the offer lapses. The lasting 15-minute offer is the Resume under Start and on the idle tile. It also removed a second Resume shown beside the page's own (§2.2, no duplication).                                                                                                        |
| 2   | medium              | The toast outlives its offer: after a Resume from the page or the tile, tapping it says "That run can't be resumed now".                                         | **Fixed** by the same change.                                                                                                                                                                                                                                                                                                                                                                                                        |
| 3   | medium-low          | The tile and record-page Resume don't refresh the latest entry first, and show nothing when refused. They have their own busy state.                             | **Filed as #297**, together with Codex r3 finding 2: no data loss, since the server voids a stale reopen with a notice.                                                                                                                                                                                                                                                                                                              |
| 4   | low-medium          | Idle timed tiles tick every second whenever the topic has any timed entry, not only inside the window.                                                           | **Filed as #298** (performance only).                                                                                                                                                                                                                                                                                                                                                                                                |
| 5   | low                 | Offline just after the stop's ack, the toast's check uses only the server cache.                                                                                 | **Filed in #297.**                                                                                                                                                                                                                                                                                                                                                                                                                   |
| 6   | low                 | Icon `restore`, not §1.3's `undo` (`Icon` has no `undo`); the `aria-label` drops the visible total; the toast action is named "Resume".                          | **Stands.** `restore` is the nearest existing icon. The name starts with the visible word (WCAG 2.5.3 holds), and the label is §1.3's text for `reopen`.                                                                                                                                                                                                                                                                             |
| 7   | low                 | Spec gap: a topic with questions can't be resumed from the answers form after an accidental Stop (row 12 is `addDetails` and `discard` only).                    | **Filed as a spec question, #299.** It is consistent with the spec on both clients.                                                                                                                                                                                                                                                                                                                                                  |
| 8   | medium (as a group) | Test gaps: the total continues and the gap shows as a pause after Resume; K6 offline through the UI; A15 at the surfaces; toast expiry; refused-Resume feedback. | **Partly stands:** <ul><li>Total and gap: proven on iOS by `RunUITests.testStopToastOffersResume`, which asserts the gap pause row and is in the GIF. On the PWA, M1's fold and `runEvent.test.ts` pin the state the panel renders.</li><li>K6 on a revert: M1's `runEvent.test.ts:843`.</li><li>A15: M1's `tapRun` refuses the reopen.</li><li>Toast expiry: moot after finding 1.</li><li>Refused-Resume feedback: #297.</li></ul> |

## Checked and fine (the reviewer's list)

- **Reopen target:**
  - from the run row's `state.terminal_id` while the row is local;
  - from the entry's `timing.terminal_id` (with revision) when it isn't, giving
    "Resuming…";
  - the toast's `stopId` is the stop's outbox item id, which is the
    `terminal_id`.
- **Stale toasts are refused:** a re-stop (queued or acked), another run's later
  stop, a later untimed entry, and an edited entry. Slow refresh and
  stale-offline cases are tested.
- **Window:** read against server time; the offer goes at expiry; archived
  topics are excluded.
- **Races:** start and reopen are serialised, and `tapRun` refuses a reopen
  while another run is open.
- **Undo resume:** a confirmation sheet, then the reopened run's `discard`
  (exempt from K6), shown in place of "Discard run…" (row 10).
