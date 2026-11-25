# Spec: content display (entry summary line, entry list and detail, richer stats)

**Status:** draft (revision 3, 2026-11-25, after review round 2). **Applies
to:** the backend (`TopicSummary.last_entry`, the summary reference
implementation, stats vectors), the PWA (entries page, entry edit page,
overview, tile summary) and the iOS app (entries list, entry detail, stats, tile
summary, widgets). **Companion specs:** [timers2.md](timers2.md) (M1:
`Segment.lap_type`, `TopicTiming.lap_types`, `remove`/`reopen`),
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

`truncate`: lengths are **extended grapheme clusters** (UAX #29) everywhere:
Python `regex.findall(r"\X", s)` (the `regex` package appearance.md §2 already
adds), Swift `String.count` (`Character` = one cluster), TS
`[...new Intl.Segmenter('en', {granularity: 'grapheme'}).segment(s)]`. If the
line has more than **80 clusters**, keep the first 79 clusters and append `…`
(U+2026). A flag pair, a keycap sequence, a skin-toned or ZWJ-joined emoji and a
base with combining marks are each one cluster, so nothing is split; the three
implementations agree as long as they share a Unicode version within one major
(the vectors avoid clusters whose segmentation changed across Unicode 15–16).

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
`long_truncated` (ends with `…`, 80 clusters), `long_truncation_flag_pair` (a 🇬🇧
straddling the cut is dropped whole), `long_truncation_keycap` (1️⃣),
`long_truncation_zwj_family` (👨‍👩‍👧‍👦, one cluster of 7 code points),
`long_truncation_combining_marks` (e + U+0301), `empty` (no timing, no answers →
`""`), `untimed_entry_of_timed_topic`.

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
  page, not per topic. `home-vectors.json` is **unchanged** (M4-LASTENTRY): its
  cases pin ordering and due state, not the summary's shape.
- **Feed note:** `FeedTopic` embeds `TopicDetail`, so `last_entry` rides along,
  but it is a **derived** field like `entry_count` and `last_captured_at`
  (`api.py:1217-1223` docstring): it is **not** re-sent when entries change.
  Rules: **[ios]** **no Swift change at all**: `TopicDetailDTO` gets no field —
  `Codable` ignores the unknown `last_entry` key (B6), so a fixture with or
  without it decodes; the tile keeps `store.observeEntries(topicId:limit:1)`
  (`TopicTile.swift:206-211`) and widgets `latestEntry(topicId:)`
  (`WidgetReader.swift:55-59`), which are already offline-correct. **[pwa]** the
  tile reads `t.last_entry` and `t.timer`. **Staleness bound ≤ 60 s:**
  `listTopics` already refetches every 60 s and on window focus
  (`TopicsPage.tsx:76-84`); in addition every entry create/update/delete
  mutation and every `entry.create` / `run.event` outbox ack **invalidates** the
  topic's `listTopics` pages and `getTopic` (`outboxEffects.ts:117-139`,
  `mutations.ts`), and the enqueue path patches `last_entry` optimistically from
  the payload as it bumps `entry_count` today. An entry created, edited or
  deleted on **another device** therefore shows on the tile within 60 s or at
  the next focus, never later (review C-S2); the iOS tile is exact because it
  reads the store.
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
  (never on a step; never on the first segment; **disabled on a lap row whose
  opening event is a `next`** — the lap that follows the last step — because
  `remove` of a `next` is `no_target`, timers2.md §3.4). It confirms ("Remove
  this lap? Its time joins the previous segment." / "Remove this pause? Its time
  becomes active."), then sends `remove(target:)` through
  `RunWrites.tap(.remove(target), …)` / `actions.tap(run.id, ctx, 'remove', …)`.
  **Target resolution from the entry itself** (timers2.md §3.3, A7): a lap row
  `i` targets `timing.segments[i].event_id` (the event that opened the segment);
  a pause `j` targets `timing.pauses[j].id`; a gap pause carries the reopened
  stop's id and removing it is the "remove the gap" of timers2.md §3.4. The
  `next`-opened case is recognised by `timing.segments[i].opened_by == "next"`
  (M1 carries `opened_by` beside `event_id`, A12). These ids are **null only on
  pre-v2 stored timings** (A12): a row whose `event_id`/`id` is null has no
  Remove (the `Edit times` editor still works). Ids: `entry.timing.remove.<i>`
  on segment rows and `entry.timing.pause.remove.<j>` on pause rows (B3). Works
  **offline**: the item queues like any run event. **Projection while queued
  (A14):** no run is projected; the entry **stays visible** with its timing
  re-projected locally (the boundary merged into the previous segment, or the
  pause's time made active), `revision` unchanged, and a pending mark on the
  section until the ack, when the server's entry (revision bumped, `edited`
  still false, timers2.md §3.4) replaces the projection. `Edit times` (the
  whole-timing editor) remains for everything else.
- **Resume run** (`entry.resume` / `entry-resume`): shown when
  `resumable(entry, now)` from the detail (within 7 days of `timing.started_at`,
  OQ-1 detail rule); sends `reopen(target: timing.terminal_id)` — from the
  entry, no `getRun`; on a pre-v2 timing (`terminal_id` null, A12) it sends
  `target: null` and the server resolves the current terminal — and navigates to
  the run screen/panel, which shows the **"Resuming…"** projection without
  controls until the ack (timers2.md §5.3). **Hidden** when `timing.edited`
  ("edited runs can't be resumed", timers2.md §3.6), when the entry is pending,
  and **while the topic has a locally open or finishing run** (A15: the server
  would answer 409 `conflict`, terminal on both outboxes, and the intent would
  be lost without a notice).
- `TimingEdit` editor (`TimingEditorSheet`, `TimingEditor.tsx`) keeps lap types:
  a lap row's type picker (none / declared types) via M1's `TimingEdit`
  additions; relabelling follows M1's rule after save.
- An entry whose id is a locally open or finishing run is **not shown as an
  entry** (OQ-14 default, timers2.md §5.3): the list filters it out and the
  detail route redirects to the run.

## 4. Stats

All stats additions are additive to `getTopicTiming` (M1 provides `lap_types`
and `SeriesPoint.lap_types`, timers2.md §7.4; `lap_types[]` and `steps[]`
buckets are keyed separately, so a lap-type key equal to a historic step key
never joins) and `getTopicStats` / `getQuestionSeries` (unchanged). Chart models
are PWA code pinned in `stats-chart-vectors.json`
(`src/components/charts/stats.vectors.test.ts`, `GENERATOR_VERSION` 1 → 2) and
ported to `QuickrCore/Charts/ChartModels.swift`.

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
last 12 weeks". **Cells are local calendar days**, in the device's zone (`tz`):
the first cell is the **Monday 11 weeks before this week's Monday** (calendar
arithmetic on dates, never `now − 84 × 86 400 s`), the last cell is **today**;
the trailing cells of the current week after today are blank. An entry falls in
the cell of its `captured_at` converted to `tz` and truncated to the date. Data:
**client-side from entries**, not a new endpoint: **[ios]**
`store.entries(topicId, from: firstCell.localMidnight(tz))`; **[pwa]**
`listEntries(captured_from = <first cell's local midnight as an instant>, limit = 500, order = -captured_at)`;
with `total > 500` the caption says "last 500 entries". The query bound and the
cells derive from the same date, so no entry of a shown day is excluded and
nothing outside the grid is counted; DST shifts change a day's length, not its
membership. Model:

```ts
export function activityStrip(
  capturedAt: readonly number[], // epoch ms
  today: string, // local date "YYYY-MM-DD" in `tz`
  tz: string,
): {
  firstDay: string;
  cells: { day: string; count: number }[];
  max: number;
  total: number;
};
```

pinned in `stats-chart-vectors.json` `activity[]` — cases: empty; one entry per
cell edge (first cell 00:00 local, today 23:59 local); an entry at 23:30 UTC
that is the next local day in `Pacific/Auckland` and the previous one in
`America/Los_Angeles`; a spring-forward and a fall-back week in `Europe/London`;
`today` on a Monday and on a Sunday (week transitions). iOS `ActivityStrip` in
`QuickrCore/Charts/ChartModels.swift`; view in `App/Stats/StatsCharts.swift`
with `ChartAccessibility` ("Week of 3 Nov: 5 entries").

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
`SeriesPoint.lap_types` (`timing-stats-vectors.json` v3); the ids on `Timing`
(timers2.md §3.3, A12): `terminal_id`, `TimingSegment.event_id`,
`TimingSegment.opened_by`, `TimingPause.id` (all null only on pre-v2 stored
timings; vector `timing-pre-v2-null-ids`; `target: null` on a reopen from such
an entry); the A14 remove projection (entry re-projected, no run);
`remove`/`reopen` events, the "Resuming…" projection (timers2.md §5.3) and the
K6 exemption for reverts (§5.5); `resumable(entry, now)`; `TimingEdit` lap
types. Before M1-STATS lands, §4.1 renders nothing extra (`lap_types` absent ⇒
v1 tiles); before the reopen/remove server WPs and the `Timing` ids land, §3.2's
buttons are not built (hard edge M1 server → M4-ENTRY-ACTIONS).

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

| Where                                                                        | Runs on | What                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend/tests/test_entry_summary_vectors.py`                                | pytest  | generator; every case; the ≤ 80 and emoji-whole truncation                                                                                                                                                                                                                                                  |
| `test_api_topics.py`, `test_home_vectors.py`                                 | pytest  | `last_entry` is the latest counted entry, null without entries, one extra statement per page (query count assertion), present in the feed topic item                                                                                                                                                        |
| PWA `entrySummary.vectors.test.ts`                                           | vitest  | the vectors; `answerText` ≡ `formatAnswer` for the old inputs                                                                                                                                                                                                                                               |
| PWA `EntriesPage.test.tsx`, `EntryEditPage.test.tsx`                         | vitest  | summary line and timing chip per row; Remove on a lap sends `remove` with `segments[i].event_id`, on a pause with `pauses[j].id`; disabled on a `next`-opened lap; Resume run sends `reopen` with `timing.terminal_id` and the panel shows "Resuming…"; both hidden when edited; both work offline (queued) |
| PWA `TopicTile.test.tsx`                                                     | vitest  | the tile issues no `listTopicVersions`/`listEntries`; summary from `last_entry`                                                                                                                                                                                                                             |
| PWA `stats.vectors.test.ts`, `timingModels.test.ts`, `OverviewPage.test.tsx` | vitest  | `lap_types[]`, `activity[]`, `sparklines[]`; cards render per type                                                                                                                                                                                                                                          |
| iOS `EntrySummaryVectorTests`, `StatsChartVectorTests`                       | host    | the ports                                                                                                                                                                                                                                                                                                   |
| iOS `EntriesModelTests`, `OverviewModelTests`                                | host    | row models carry the summary; `activityStrip` from store entries                                                                                                                                                                                                                                            |
| iOS `EntriesTests` (UI)                                                      | sim     | one flow: a timed entry shows its chip and summary; open it; Remove a lap → the segment count drops and `edited` badge stays absent (fake server from `UITestRuns`)                                                                                                                                         |
| iOS `StatsUITests`                                                           | sim     | lap-type cards present for the tiktok topic; activity strip accessible labels                                                                                                                                                                                                                               |

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
- D-3 Remove and Resume on an entry take their targets from the entry's own
  `timing` ids (`event_id`, `pauses[].id`, `terminal_id`), so they queue offline
  like any run event; `Edit times` remains the whole-timing editor (§3.2).
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
| 2 delete a pause / a lap from a saved session  | §3.2 (events in timers2.md §3.4) |
| 2 resume a session from its entry              | §3.2 Resume run                  |
| 1, 4 renamed and tik-tok laps shown everywhere | §1.2, §3, §4.1                   |

## 11. Review log (round 1)

| Finding                                                                              | Outcome                                                                                                                                                                    |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C-S2 PWA `last_entry` stale after remote changes                                     | Fixed in §2 (D4): 60 s refetch + focus refetch + invalidation on entry mutations and outbox acks; staleness bound ≤ 60 s stated                                            |
| C-S2 12-week strip window vs calendar cells                                          | Fixed in §4.2 (D5): cells are local calendar days from the Monday 11 weeks before this week's Monday to today; query from that local midnight; DST/week-transition vectors |
| C-S2 truncation can still split emoji                                                | Fixed in §1.2, §1.3 (D6): extended grapheme clusters everywhere, 80-cluster cap, flag/keycap/ZWJ/combining vectors                                                         |
| K-S1 no target source for Remove/Resume                                              | Fixed in §3.2, §6, D-3 (A7): targets from `timing.segments[].event_id`, `pauses[].id`, `terminal_id`; offline-capable; "Resuming…" projection                              |
| K-S3 a `next`-opened lap row maps to a `next` event                                  | Fixed in §3.2 (D8): Remove disabled on that row; `opened_by` requested from M1 as a seam                                                                                   |
| K-S3 `home-vectors.json` "regenerates" vs plan "unchanged"; `@RequiredKey lastEntry` | Fixed in §2 (D8): unchanged; plain optional on iOS, no Swift change                                                                                                        |
| K-S2 wrong timers2 section references                                                | Fixed in §3.2, §4, §10 (D8): §3.4, §3.6, §5.3, §7.4                                                                                                                        |
| K-S3 lap-type key equal to a historic step key                                       | Noted in §4 (A10): `lap_types[]` and `steps[]` are keyed separately                                                                                                        |
| K-S2 `topics.py` `_summaries`/`_base_select` edited by M3a and M4                    | Ownership rule lives in t2-plan.md (E3, delimited blocks); §2 unchanged                                                                                                    |

### Round 2

| Finding                                                        | Outcome                                                                                                                      |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| K-S2 three behaviours for a `remove` queued from an entry       | Fixed in §3.2, §6 (A14): no run projected; the entry stays visible with its timing re-projected, `revision` unchanged, pending mark |
| K-S1 `terminal_id` and ids null on pre-v2 timings               | Fixed in §3.2, §6 (A12): ids null only on pre-v2 timings; Resume sends `target: null`; Remove absent on a null-id row         |
| K-S3 Resume from the entry while the topic has an open run      | Fixed in §3.2 (A15): hidden while the topic has a locally open or finishing run                                              |
| K-S3 iOS DTO field for `last_entry`                             | Fixed in §2 (B6): no DTO field; `Codable` ignores the key                                                                    |
| K-S2 accessibility-id drift                                     | Fixed in §3.2 (B3): `entry.resume`, `entry.timing.remove.<i>`, `entry.timing.pause.remove.<j>`; ids live here only           |
| K-S3 "timers2.md §7.1" for the Resuming projection              | Fixed in §3.2, §6: §5.3                                                                                                      |
| K-S2 M4-plan interfaces differ (`entry_summary`, `TopicSummaryLine`, strip window) | No spec change: §1.1, §4.2, §5 are canonical; the plan copies them                                         |
