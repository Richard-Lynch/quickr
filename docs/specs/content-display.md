# Spec: content display (entry summary line, entry list and detail, richer stats)

**Status:** draft (revision 1, 2026-11-25). **Applies to:** the backend
(`TopicSummary.last_entry`, the summary reference implementation, stats
vectors), the PWA (entries page, entry edit page, overview, tile summary) and
the iOS app (entries list, entry detail, stats, tile summary, widgets).
**Companion specs:** [timers2.md](timers2.md) (M1: `Segment.lap_type`,
`TopicTiming.lap_types`, `remove`/`reopen`),
[active-surfaces.md](active-surfaces.md) (M2 consumes `TopicSummaryLine`),
[appearance.md](appearance.md) (M3 owns the topic header's glyph and chips),
[timers.md](timers.md) §9, §11.2, §11.5 (v1 stats and entry surfaces, revised
here by reference). **Plan:** [t2-plan.md](t2-plan.md) (milestone M4).

## Purpose

The user's words (requirements.md, item 8 and its clarification):

> 8. I think we need better display for the actual content, it doesn't tell me
>    much!

> **#8, which views:** the topic detail / entry list (show the actual answers
> and timings), home tiles (a glanceable summary) and the stats screen (richer).
> Run results were not selected as a separate item. They are covered by the
> entry and detail display.

Today the entries list shows answers but no timing at all
(`frontend/src/pages/topic/EntriesPage.tsx:337-367`,
`ios/App/Entries/List/EntriesView.swift:285-322`), the tile shows "4 entries · 4
days ago" or a single quick-log answer
(`ios/App/Home/Tiles/TopicTile.swift:182-190`), and the stats lap tile is one
median over all laps
(`frontend/src/components/runs/TimingOverview.tsx:136-141`).

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]**, **[ios]** and **[pwa]** mark who implements a rule.

## Glossary

- **Summary line** — one line of ≤ 80 code points describing an entry: timing
  first, then answers (§1). Same text on every client, pinned by
  `entry-summary-vectors.json`.
- **Timing chip** — the badge "12:40 · 3 laps" on an entry row (the timing part
  of the summary line alone).
- **Lap type** — M1's `LapType {key, label}`; a segment's `lap_type` is its key
  or null (untyped lap, or a step).
- **Last entry** — `TopicSummary.last_entry`: the topic's latest counted entry
  by `captured_at` (§2).
- **Activity strip** — 84 cells (12 weeks × 7 days) of entries per day (§4.2).
- **Sparkline** — a small line of a numeric question's bucket means (§4.3).

## 1. The entry summary line

### 1.1 Reference and ports

Reference `backend/app/services/summary.py`:

```python
MAX_SUMMARY_LENGTH = 80
def entry_summary(answers: list[AnswerOut], timing: Timing | None, questions: list[Question], timer: Timer | None) -> str
def timing_summary(timing: Timing, timer: Timer | None) -> str          # "12:40 · Run 3 · Rest 3"
def answer_text(question: Question, answer: AnswerOut) -> str | None     # "72 kg", "Mild, Tired", "walked"
```

Ports: **[pwa]** `src/lib/entrySummary.ts` (`entrySummary`, `timingSummary`,
`answerText`; `answerText` replaces `formatAnswer` in
`lib/answerDisplay.ts:17-31` for display, which is then re-exported from it so
`AnswerGrid` and the record page keep working); **[ios]**
`QuickrCore/Entries/EntrySummary.swift`
(`EntrySummary.line(answers:timing:questions:timer:)`, `timingLine`,
`answerText`; `TopicText.answer` (`QuickrUI/Logic/TopicText.swift:38-57`)
delegates to it).

### 1.2 Algorithm

Inputs: the entry's answers (wire `AnswerOut` list), its `timing` or null, the
**entry's version's** questions in their order (labels come from there; a key
with no question is skipped), and the **current** timer (lap-type labels; null
for untimed topics — a stored entry whose version had lap types the current
timer no longer declares falls back to the key as the label).

```
parts = []
if timing:
    t = fmt_duration(timing.active_ms)                       # duration-format-vectors rule
    laps = [s for s in timing.segments if s.kind == "lap"]
    if laps:
        typed = [s.lap_type for s in laps if s.lap_type]
        if not typed:
            t += f" · {n} lap" if n == 1 else f" · {n} laps"           # n = len(laps)
        else:
            order = [lt.key for lt in timer.laps] if timer else []       # declared order first
            keys = order-then-first-seen unique keys of typed laps
            for k in keys: t += f" · {label(k)} {count(k)}"             # "Run 3 · Rest 3"
            untyped = len(laps) - len(typed)
            if untyped: t += f" · {untyped} lap(s)"
    parts.append(t)
for q in questions:
    a = answer with key q.key; text = answer_text(q, a)
    if text: parts.append(f"{q.label}: {text}")
line = " · ".join(parts)
return truncate(line)
```

`answer_text`:

- `int`: the integer with thousands separators off (`"72"`), then `" {unit}"` if
  the question has a unit;
- `double`: `decimals` fraction digits at most (default 3), trailing zeros
  dropped, `.` decimal point (en-US, as `formatNumber`), then the unit;
- `enum` single: the option's label, the raw value for an unknown option;
  `enum_list`: labels joined by `", "`; empty list → null (part skipped);
- `str`: whitespace runs collapsed to one space, trimmed; empty → null.

`truncate`: if the line has more than 80 code points, keep the first 79 and
append `…` (U+2026); back the cut off while the next code point is a ZWJ
(U+200D), VS16 (U+FE0F), a skin-tone modifier (U+1F3FB–1F3FF) or a combining
mark (category Mn/Me), so an emoji sequence is dropped whole rather than split.
Lengths are **code points** everywhere (Python `len`, Swift
`unicodeScalars.count`, TS `Array.from(s).length`).

Pauses, skipped steps and notes are not in the line. The empty line (`""`) means
"nothing to say": callers show their fallback (§5).

### 1.3 `entry-summary-vectors.json`

Generated by `backend/tests/test_entry_summary_vectors.py`
(`GENERATOR_VERSION = 1`, `check_or_write` / `dump_cases`), README row added.

```
{ "meta": { "generator", "generator_version": 1, "max_length": 80, "separator": " · ", "semantics": [prose of §1.2] },
  "question_sets": { "none": [], "weight": [...], "mood_multi": [...], "mixed": [...] },
  "timer_sets":    { "none": null, "plain": {"steps": [], "laps": [], ...}, "tiktok": {... laps: run/rest}, "renamed": {... laps: [cig]} },
  "cases": [ { "name", "questions": set, "timer": set, "answers": [AnswerOut], "timing": Timing | null, "expected": str } ] }
```

Cases (≥ 20): `timing_only_no_laps` ("12:40"), `timing_one_lap` ("12:40 · 1
lap"), `timing_three_laps` ("12:40 · 3 laps"), `timing_tiktok` ("12:40 · Run 3 ·
Rest 3"), `timing_renamed` ("4:05 · Cig 2"), `timing_mixed_typed_untyped` (typed
from a later version plus untyped), `timing_lap_type_not_in_timer` (key as
label), `timing_hour_plus` ("1:02:03 · 2 laps"), `timing_paused_ignored`,
`answers_int_unit` ("Weight: 72 kg"), `answers_double_decimals` ("Temp: 36.6
°C"), `answers_double_trailing_zeros` ("Dose: 2.5"), `answers_enum_single`,
`answers_enum_multi` ("Mood: Mild, Tired"), `answers_enum_unknown_option` (raw
value), `answers_str_collapsed_whitespace`, `answers_str_empty_skipped`,
`answers_missing_optional_skipped`, `both_timing_then_answers`,
`order_follows_questions_not_answers`, `question_without_answer_skipped`,
`long_truncated` (ends with `…`, 80 code points),
`long_truncation_keeps_emoji_whole`, `empty` (no timing, no answers → `""`),
`untimed_entry_of_timed_topic`.

Consumers: `backend/tests` (the reference itself), PWA
`entrySummary.vectors.test.ts`, iOS `EntrySummaryVectorTests` (+
`FixtureCoverageTests` learns the file).

## 2. `TopicSummary.last_entry` **[server]**

- `TopicSummary.last_entry: EntryOut | None` (`schemas/api.py:229-248` gains the
  field): the latest counted entry by `(captured_at DESC, id DESC)`.
  `_base_select` (`topics.py:167-183`) adds a `LATERAL` subquery (or
  `DISTINCT ON (topic_id)` over `entries`) selecting that entry's columns;
  `_summaries` (`:132-164`) collects the entry ids and loads their answers in
  **one** extra query (`Answer.entry_id IN (...)`, `_answer_out` from
  `services/entries.py:71-87`). `list_topics` cost: one extra statement per
  page, not per topic. `home-vectors.json` regenerates with the new field (its
  cases do not sort by it).
- **Feed note:** `FeedTopic` embeds `TopicDetail`, so `last_entry` rides along,
  but it is a **derived** field like `entry_count` and `last_captured_at`
  (`api.py:1217-1223` docstring): it is **not** re-sent when entries change.
  Rules: **[ios]** `TopicDetailDTO` decodes it
  (`@RequiredKey lastEntry: EntryDTO?`) and `StoreView` **ignores** it; the tile
  keeps `store.observeEntries(topicId:limit:1)` (`TopicTile.swift:206-211`) and
  widgets `latestEntry(topicId:)` (`WidgetReader.swift:55-59`), which are
  already offline-correct. **[pwa]** the tile reads `t.last_entry` and
  `t.timer`, and `outboxEffects.ts:117-139` patches `last_entry` on enqueue
  (optimistic, from the payload) and on ack (the server's `EntryOut`), as it
  bumps `entry_count` today.
- **PWA tile query reduction:** `TopicTile.tsx` drops `useTopicVersions` (`:71`)
  and `lastEntryOptions` (`:91-95`): `timed = Boolean(t.timer) || run` and
  `unknown` is gone (the summary carries the timer). The `getTopic` prefetch
  (`:79-83`) stays for quick-log questions. Three queries per tile become one.

## 3. Entry list and detail

### 3.1 List rows **[ios] [pwa]**

A row, top to bottom: the captured-at line as today (iOS
`EntriesView.swift:293-304`, PWA `EntriesPage.tsx:341-352`); the **summary
line** in `.qr(.callout)` / `text-[0.95rem] font-medium`, one line, truncated
(`entry.<id>.summary` / `data-testid="entry-summary"`); then the full
`AnswerGrid` (unchanged); for a timed entry a **timing chip** before the grid:
`QuickrBadge(timingLine, icon: .timer)` /
`<Badge tone="accent"><Icon name="timer"/>…</Badge>` (`entry.<id>.timing` /
`entry-timing`) with the segment count in its accessibility label ("12 minutes
40 seconds, 3 laps"). The desktop table (`EntriesPage.tsx:370-445`) gains a
"Timing" column after Captured. Pending timed entries (`:185-196`) use the same
chip. Untimed entries of a timed topic have no chip (timers.md §11.1).

### 3.2 Detail **[ios] [pwa]**

`EntryTimingSection` (`App/Entries/EntryTimingSection.swift`) and
`TimingSection.tsx` (`:103-170`):

- Segment rows show M1's label ("Run 2") with a neutral lap-type badge on typed
  laps; step rows unchanged. Pauses become rows in the same list ("Paused ·
  0:20" between the segments they fall in), keeping ids
  `entry.timing.segment.<i>` and `entry.timing.pause.<i>`.
- **One-tap Remove** (UI contract; the event is M1's `remove`): a trailing swipe
  action / an `IconButton` "Remove" on **lap** rows and **pause** rows only
  (never on a step; never on the first segment). It confirms ("Remove this lap?
  Its time joins the previous segment." / "Remove this pause? Its time becomes
  active."), then sends `remove(target:)` through
  `RunWrites.tap(.remove(target), …)` / `actions.tap(run.id, ctx, 'remove', …)`.
  Target resolution: `getRun(entry.id)` → `RunOut.events`; a lap row `i` maps to
  the applied `lap`/`next` event whose `at == segments[i].started_at`; a pause
  `j` to the applied `pause` event whose `at == pauses[j].start`. Online only:
  offline the buttons are disabled with "Connect to edit laps"; `Edit times`
  (the whole-timing editor) stays the offline path. The section reloads the
  entry on ack (`revision` bumped, `edited` stays false, timers2.md §1.3).
- **Resume run** (`entry.resume` / `entry-resume`): shown when
  `resumable(entry, now)` from the detail (within 7 days of `timing.started_at`,
  OQ-1 detail rule); sends `reopen(target: RunState.terminal_id)` from `getRun`;
  on success navigates to the run screen/panel. Hidden when `timing.edited`
  ("edited runs can't be resumed", timers2.md §1.3) or the entry is pending.
- `TimingEdit` editor (`TimingEditorSheet`, `TimingEditor.tsx`) keeps lap types:
  a lap row's type picker (none / declared types) via M1's `TimingEdit`
  additions; relabelling follows M1's rule after save.
- An entry whose id is a locally open or finishing run is **not shown as an
  entry** (OQ-14 default, timers2.md §1.4): the list filters it out and the
  detail route redirects to the run.

## 4. Stats

All stats additions are additive to `getTopicTiming` (M1 provides `lap_types`
and `SeriesPoint.lap_types`, timers2.md §1.5) and `getTopicStats` /
`getQuestionSeries` (unchanged). Chart models are PWA code pinned in
`stats-chart-vectors.json` (`src/components/charts/stats.vectors.test.ts`,
`GENERATOR_VERSION` 1 → 2) and ported to `QuickrCore/Charts/ChartModels.swift`.

### 4.1 Lap types

- **Cards:** when `timing.lap_types` is non-empty, the laps tile row
  (`TimingOverview.tsx:136-141`; iOS `TimingOverview.swift` lap tiles) becomes
  one card per lap type: label, `laps` count, median (big), best and mean
  (`data-testid="laptype-{key}"`, `overview.timing.laptype.<key>`), coloured by
  `optionColors(lapTypeKeys)` as steps are (`:25`). The v1 "Runs with laps / Lap
  time (median)" tiles remain for untyped laps.
- **Stacked chart:** `lapTypesByBucket(series, bucket)` in
  `charts/timingModels.ts` beside `stepsByBucket` (`timingModels.ts:63`): mean
  active ms per run per lap type per bucket; rendered with `StackedBars` under
  the cards ("Time per lap type, per {bucket}"). iOS `TimingOverviewText` gains
  `LapTypeBucket`/`LapTypeMean` mirroring `StepBucket`/`StepMean`
  (`TimingOverviewText.swift:36-46`) and `lapTypes: [LapType]` for the cards.
- Vectors: `stats-chart-vectors.json` gains `lap_types[]` cases (input: a
  `TopicTiming` from `timing-stats-vectors.json` v3; expected: the stacked model
  and card strings), and `timing_models[]` for `lapTypesByBucket` —
  `timingModels` was not pinned before (pwa.md §5.3); M4 pins the new function
  and `stepsByBucket` alongside.

### 4.2 Activity strip

Overview gains "Activity" under the summary tiles: 12 columns × 7 rows of cells
(weeks × weekdays, oldest left), cell intensity by count (0, 1, 2–3, 4+ →
`sunken`, `tint` at 35/65/100 %), today outlined; a caption "N entries in the
last 12 weeks". Data: **client-side from entries**, not a new endpoint:
**[ios]** `store.entries(topicId, from: now − 84 days)`; **[pwa]**
`listEntries(captured_from = now − 84 d, limit = 500, order = -captured_at)`;
with `total > 500` the caption says "last 500 entries". Model:

```ts
export function activityStrip(
  capturedAt: readonly number[],
  now: number,
  tz: string,
): { cells: { day: string; count: number }[]; max: number; total: number };
```

pinned in `stats-chart-vectors.json` `activity[]` (inputs incl. a DST week and
an empty list; `tz` set per case as the generator does for series). iOS
`ActivityStrip` in `QuickrCore/Charts/ChartModels.swift`; view in
`App/Stats/StatsCharts.swift` with `ChartAccessibility` ("Week of 3 Nov: 5
entries").

### 4.3 Sparklines

Numeric question cards (`OverviewPage.tsx` `NumericCard`, iOS `OverviewCards`)
gain a 48 px sparkline of
`getQuestionSeries(key, bucket = defaultBucket(range), tz)` means with the last
point marked and min/max as end labels. One query per numeric card, `staleTime`
5 min, only when the card is on screen (`IntersectionObserver` on the PWA; iOS
`StatsLoader` loads them after the stats). Model
`sparkline(points: SeriesPoint[], width)` → `{ path: [x, y][], last, min, max }`
pinned in `sparklines[]`.

## 5. `TopicSummaryLine`

The idle tile's second line, provided to M2. The brief names
`TopicSummaryLine(entry:timer:)`; labels need the questions too, so the
signature carries them (a completion, not a change of intent).

**[ios]** `QuickrUI/Components/TopicSummaryLine.swift`:

```swift
public struct TopicSummaryLine: View {
    /// `entry` nil or an empty line → `fallback` ("4 entries · 4 days ago" from the tile).
    public init(entry: Entry?, questions: [Question], timer: TopicTimer?, fallback: Text)
}
```

Renders `Text(summary)` in `.qr(.footnote)` `inkSoft`, one line, tail
truncation, `accessibilityLabel("Last entry: \(summary)")`; the tile composes
"{summary} · {ago}" by passing the summary through its existing `lastLine`
replacement. Widgets reuse it in `WidgetViews.lastLine`.

**[pwa]** `src/components/topics/TopicSummaryLine.tsx`:

```tsx
export function TopicSummaryLine({
  entry,
  questions,
  timer,
  fallback,
}: {
  entry: EntryOut | null;
  questions: readonly Question[] | null;
  timer: Timer | null;
  fallback: React.ReactNode;
}): JSX.Element; // <span class="truncate text-ink-soft" data-testid="topic-summary">
```

`questions` null (the `getTopic` prefetch not in yet) renders the timing part
only, then the fallback when that is empty.

Default rendering before M4 lands: M2 keeps `lastLine` / the "Last …" span
(active-surfaces.md §3.3).

## 6. Seams

**Consumes (from M1):** `Segment.lap_type` and `TimingSegment.lap_type`,
`LapType` labels in `Timer.laps`, `TopicTiming.lap_types`,
`SeriesPoint.lap_types` (`timing-stats-vectors.json` v3), `remove`/`reopen`
events with `RunState.terminal_id`, `resumable(entry, now)`, `TimingEdit` lap
types. Before M1-STATS lands, §4.1 renders nothing extra (`lap_types` absent ⇒
v1 tiles); before the reopen/remove server WPs land, §3.2's buttons are not
built (hard edge M1 server → M4-ENTRY-ACTIONS).

**Consumes (from M3):** the topic header's glyph and chips are M3's
(`TopicTabsView`, `TopicLayout.tsx:154-206`); M4 edits the tabs' content only.

**Provides:** `TopicSummaryLine` (§5) to M2; `entry_summary` / `entrySummary` /
`EntrySummary` to notifications later (brief §4); `TopicSummary.last_entry` to
the PWA tile; `activityStrip`, `sparkline`, `lapTypesByBucket` models to iOS
through the vectors.

**Not consumed from the server:** the activity strip (§4.2) is computed
client-side from the entries each client already has (iOS store, PWA
`listEntries`); it adds no server field or endpoint, so M4's backend scope stays
`last_entry` + `summary.py` + stats additions only.

## 7. Tests

| Where                                                                        | Runs on | What                                                                                                                                                                |
| ---------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend/tests/test_entry_summary_vectors.py`                                | pytest  | generator; every case; the ≤ 80 and emoji-whole truncation                                                                                                          |
| `test_api_topics.py`, `test_home_vectors.py`                                 | pytest  | `last_entry` is the latest counted entry, null without entries, one extra statement per page (query count assertion), present in the feed topic item                |
| PWA `entrySummary.vectors.test.ts`                                           | vitest  | the vectors; `answerText` ≡ `formatAnswer` for the old inputs                                                                                                       |
| PWA `EntriesPage.test.tsx`, `EntryEditPage.test.tsx`                         | vitest  | summary line and timing chip per row; Remove on a lap sends `remove` with the resolved target; Resume run sends `reopen`; both hidden when edited/offline           |
| PWA `TopicTile.test.tsx`                                                     | vitest  | the tile issues no `listTopicVersions`/`listEntries`; summary from `last_entry`                                                                                     |
| PWA `stats.vectors.test.ts`, `timingModels.test.ts`, `OverviewPage.test.tsx` | vitest  | `lap_types[]`, `activity[]`, `sparklines[]`; cards render per type                                                                                                  |
| iOS `EntrySummaryVectorTests`, `StatsChartVectorTests`                       | host    | the ports                                                                                                                                                           |
| iOS `EntriesModelTests`, `OverviewModelTests`                                | host    | row models carry the summary; `activityStrip` from store entries                                                                                                    |
| iOS `EntriesTests` (UI)                                                      | sim     | one flow: a timed entry shows its chip and summary; open it; Remove a lap → the segment count drops and `edited` badge stays absent (fake server from `UITestRuns`) |
| iOS `StatsUITests`                                                           | sim     | lap-type cards present for the tiktok topic; activity strip accessible labels                                                                                       |

## 8. Open questions

- **OQ-12** CSV timing columns: **out of scope**; followup issue to add
  `started_at, active_ms, paused_ms, laps` columns to `exportEntriesCsv`
  (`entries.py:407-477`). Default: not in T2.
- **OQ-14** (brief default) an entry that is a locally open run is hidden from
  the list (§3.2). Default yes.
- **OQ-M4-a** activity strip from entries, not a server field (§4.2). Default
  client-side; revisit if `listEntries` of 500 rows proves slow on the PWA.
- **OQ-M4-b** summary line length 80 code points. Default 80; tiles truncate
  further by width anyway.

## 9. Decisions

- D-1 One summary rule on the server, ported and pinned; timing first, answers
  in question order, `" · "` separators, 80 code points (§1).
- D-2 `last_entry` is additive and derived: iOS ignores it, the PWA uses it and
  drops two queries per tile (§2).
- D-3 Remove and Resume on an entry are online actions resolved through
  `getRun`; `Edit times` remains the offline editor (§3.2).
- D-4 Lap-type stats are cards + one stacked chart; untyped laps keep the v1
  tiles (§4.1).
- D-5 The activity strip and sparklines need no new endpoint (§4.2, §4.3).
- D-6 `TopicSummaryLine` takes the questions (§5).

## 10. Traceability

| User item                                      | Where                            |
| ---------------------------------------------- | -------------------------------- |
| 8 entry list: actual answers and timings       | §1, §3.1                         |
| 8 entry detail                                 | §3.2                             |
| 8 home tiles: glanceable summary               | §1, §2, §5                       |
| 8 stats screen: richer                         | §4                               |
| 2 delete a pause / a lap from a saved session  | §3.2 (events in timers2.md §1.3) |
| 2 resume a session from its entry              | §3.2 Resume run                  |
| 1, 4 renamed and tik-tok laps shown everywhere | §1.2, §3, §4.1                   |
