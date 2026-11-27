# M4 milestone review: Claude reviewer (independent, Opus)

Range: `origin/feat/t2...origin/t2/m4` at baefb230 (216 files, 31 commits). Read-only review against content-display.md (with its amendments), t2-plan.md ownership, M4-plan.md and the user's item 8. The reviewer was given the diff and the spec, not the lead's conclusions. Resolutions are in [M4-milestone-findings.md](M4-milestone-findings.md) and evidence/M4.md §10.

**Verdict:** ready to merge after fixes. There are no P0 findings. #1 must be fixed. #2 and #3 must be fixed or tracked.

**Checked and found sound:** the summary ports agree (Python/TS/Swift) on lap-type ordering, last-label-wins, empty lap types as untyped, decimal rounding including -0, White_Space collapsing and grapheme truncation. The vector and model tests are real. `last_entry` uses a LATERAL join with one extra statement per page. The activity strip and sparkline arithmetic match across platforms. The entry-action rules match across platforms: Remove never on a step, the first segment, an edited timing or a null id; Remove disabled on a lap not opened by `lap`; Resume follows A15 and waits for local runs; OQ-14 on list and detail.

## In scope
1. **P1.** iOS offers Edit times while a Remove is queued, and that voids the Remove (`run_edited`). `EditModel.swift:298-306`, `EditScreen.swift:183-184`. The PWA already blocks this. **Fixed in #301.**
2. **P2.** The PWA entries list doesn't apply the A14 projection; iOS does (`EntriesPage.tsx`). **Fixed in #296.**
3. **P2.** List rows say the same thing three times: the summary line, then the chip, then the full AnswerGrid (`EntriesPage.tsx`, `EntriesView.swift:308-310`). This works against the user's "doesn't tell me much". It needs a spec §3.1 change. **Open: the decision is pending, tracked as a t2-followup.**
4. **P2.** A topic with mixed typed and untyped laps loses its v1 lap tiles once any lap type exists. That contradicts §4.1 as originally written. **Resolved by the §4.1 amendment (86b13719) and #204.**
5. **P3.** Every iOS Remove button is labelled just "Remove". The disabled hint is wrong for `skip`-opened laps. **Fixed in #301.**
6. **P3.** The PWA activity strip exposes only its caption to screen readers. **Fixed in #296.**
7. **P3.** The PWA's disabled Remove gives its reason only in a tooltip. **Fixed in #296.**
8. **P3.** iOS gives no feedback when a Remove or Resume isn't enqueued. **Fixed in #301.**
9. **P3.** §2 describes PWA behaviour that isn't on the branch: tile reads and the optimistic `last_entry`. **Resolved by the §2 delivery note (86b13719).**
10. **P3.** TopicDTO.swift is M3a's file, and M4 added `// T2-M4` blocks to it. **Agreed by t2-m3a-lead (2026-11-25) and recorded in the evidence.**

## Out of scope
- Home tiles don't render `TopicSummaryLine` yet. That is T2-WIRE-I/F, on M2's surfaces.
- The optimistic `last_entry` patch belongs in `outboxEffects.ts` (M1), tracked as #169.
- #197 stays open for the list's A14 projection (since fixed in #296) and the tile's `lastEntry` hiding.
