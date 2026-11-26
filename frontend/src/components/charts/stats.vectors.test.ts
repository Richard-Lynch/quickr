/**
 * Generator + drift check for shared/fixtures/stats-chart-vectors.json: what the Overview's
 * charts and summaries make of the server's stats and series (the inputs are the real
 * responses in shared/fixtures/stats-vectors.json), for the iOS port. It runs the PWA's own
 * code: the chart models (`chartModels.ts`), `niceTicks`, `formatBucket`, `formatTick`,
 * `formatNumber`, `formatPercent`, `plural` and `optionColors`; and (v2, content-display.md
 * §4.2, §4.3) the activity strip, the numeric sparklines and the timing chart models
 * (`timingModels.ts`), the last over shared/fixtures/timing-stats-vectors.json; and (v3,
 * content-display.md §4.1) the lap-type cards and their stacked chart over the same file.
 *
 * Text is en-US (the generator checks the locale), and bucket labels are in each series'
 * `tz`, which the generator sets as the process zone before labelling it. Label positions
 * depend on the chart's width, so `labelled` is given for each of `meta.widths`.
 *
 * With QUICKR_UPDATE_VECTORS=1 (`make vectors`) this writes the file; otherwise it fails when
 * the committed file differs, like backend/tests/vectors.py.
 */
import { afterAll, describe, expect, it } from 'vitest';

import type {
  EnumStats,
  NumericStats,
  QuestionSeries,
  SeriesPoint,
  StrStats,
  TopicStats,
  TopicTiming,
} from '../../client';
import { RANGE_PRESETS } from '../../lib/dates';
import { formatNumber, formatPercent, plural } from '../../lib/format';
import { optionColors } from './EnumBars';
import {
  defaultBucket,
  enumView,
  lineModel,
  stackSegments,
  stackedModel,
  seriesTotal,
} from './chartModels';
import { formatBucket, formatTick, niceTicks, pickLabels, type Bucket } from './chartUtils';
import {
  activityLevel,
  activityStrip,
  lapTypeCards,
  lapTypesByBucket,
  localMidnight,
  sparkline,
  stepsByBucket,
} from './timingModels';

// No @types/node in the app's tsconfig: reach Node through narrow local types.
interface NodeProcess {
  env: Record<string, string | undefined>;
}
interface NodeFs {
  existsSync(p: string): boolean;
  readFileSync(p: string, enc: 'utf8'): string;
  writeFileSync(p: string, data: string): void;
}
const nodeProcess = (globalThis as unknown as { process: NodeProcess }).process;

// Each series is labelled in its own zone (Node re-reads TZ when it is assigned). Vitest reuses
// its worker processes across test files, so put the previous value back after.
const previousTz = nodeProcess.env.TZ;
afterAll(() => {
  if (previousTz === undefined) delete nodeProcess.env.TZ;
  else nodeProcess.env.TZ = previousTz;
});
function inZone<T>(tz: string, body: () => T): T {
  nodeProcess.env.TZ = tz;
  return body();
}

const DIR = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/../../../../shared/fixtures`;
const INPUT = `${DIR}/stats-vectors.json`;
const TIMING_INPUT = `${DIR}/timing-stats-vectors.json`;
const FILE = `${DIR}/stats-chart-vectors.json`;
const FILE_LABEL = 'shared/fixtures/stats-chart-vectors.json';
const GENERATOR_VERSION = 3;
const WIDTHS = [320, 600];
/** The zone the summaries' dates are shown in. */
const SUMMARY_TZ = 'Europe/London';
const summaryDate = new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium',
  timeZone: SUMMARY_TZ,
});

interface InputCase {
  name: string;
  kind: 'stats' | 'series';
  topic: string;
  question?: string;
  query: Record<string, string>;
  response: TopicStats | QuestionSeries;
}

// ---------------------------------------------------------------------------
// Standalone cases
// ---------------------------------------------------------------------------

const TICK_CASES: [number, number][] = [
  [0, 24],
  [3, 8],
  [5, 5],
  [0, 0],
  [-3, -3],
  [0.001, 0.0042],
  [-2469135.6, 2456789.9],
  [1e9, 1e9 + 1],
  [7.25, 7.25],
  [0, 1],
  [-0.5, 0.5],
  [1, 1000000],
  [12, 13],
];

const NUMBERS: (number | null)[] = [
  0,
  1,
  -1,
  7,
  7.5,
  0.125,
  0.5,
  1.005,
  2.675,
  1.5,
  2.5,
  -0.05,
  1234.5,
  1234567.891,
  1e15,
  1e21,
  -2469135.6,
  0.333333,
  2 / 3,
  NaN,
  null,
];

const PERCENTS = [0, 0.004, 0.005, 0.015, 0.125, 0.5, 2 / 3, 0.335, 0.995, 1, 1.5];

// pickLabels on plain positions: the rule alone, without a chart's layout.
// Shapes the server doesn't send today, for the models' guards: buckets without a mean, a bucket
// without answers, and a value no option has (an option renamed away). Keys are in sorted order,
// as the iOS model reads them (a JSON object's order doesn't survive decoding there).
function point(start: string, patch: Partial<SeriesPoint>): SeriesPoint {
  return { start, count: 0, mean: null, min: null, max: null, option_counts: {}, ...patch };
}
const SYNTHETIC_OPTIONS = [
  { value: 'a', label: 'A' },
  { value: 'b', label: 'B' },
];
const SYNTHETIC: {
  name: string;
  bucket: Bucket;
  points: SeriesPoint[];
  chart: 'line' | 'stacked';
}[] = [
  {
    name: 'line: buckets without a mean are skipped',
    bucket: 'day',
    chart: 'line',
    points: [
      point('2025-01-01T00:00:00Z', { count: 1 }),
      point('2025-01-02T00:00:00Z', { count: 2, mean: 4, min: 3, max: 5 }),
      point('2025-01-03T00:00:00Z', { count: 1 }),
      point('2025-01-05T00:00:00Z', { count: 1, mean: 6.5 }),
    ],
  },
  {
    name: 'line: no bucket has a mean',
    bucket: 'week',
    chart: 'line',
    points: [point('2025-01-06T00:00:00Z', { count: 3 })],
  },
  {
    name: 'line: one bucket',
    bucket: 'month',
    chart: 'line',
    points: [point('2025-02-01T00:00:00Z', { count: 1, mean: 7, min: 7, max: 7 })],
  },
  {
    name: 'stacked: a bucket without answers, and values no option has',
    bucket: 'day',
    chart: 'stacked',
    points: [
      point('2025-01-01T00:00:00Z', { count: 2, option_counts: { b: 1, zz: 1 } }),
      point('2025-01-02T00:00:00Z', { count: 0 }),
      point('2025-01-03T00:00:00Z', { count: 3, option_counts: { a: 2, b: 1, c: 1 } }),
    ],
  },
];

function syntheticCase(c: (typeof SYNTHETIC)[number]) {
  const labels = (points: { start: string }[]) =>
    inZone('UTC', () => ({
      short: points.map((p) => formatBucket(p.start, c.bucket)),
      long: points.map((p) => formatBucket(p.start, c.bucket, 'long')),
    }));
  if (c.chart === 'line') {
    const models = WIDTHS.map((w) => lineModel(c.points, w));
    const model = models[0];
    if (!model)
      return { name: c.name, chart: c.chart, bucket: c.bucket, points: c.points, empty: true };
    return {
      name: c.name,
      chart: c.chart,
      bucket: c.bucket,
      points: c.points,
      kept: model.data.map((p) => c.points.indexOf(p)),
      ticks: model.ticks,
      labelled: labelledByWidth(models),
      labels: labels(model.data),
    };
  }
  const models = WIDTHS.map((w) => stackedModel(c.points, SYNTHETIC_OPTIONS, w));
  const model = models[0];
  if (!model)
    return { name: c.name, chart: c.chart, bucket: c.bucket, points: c.points, empty: true };
  return {
    name: c.name,
    chart: c.chart,
    bucket: c.bucket,
    points: c.points,
    options: SYNTHETIC_OPTIONS.map((o) => [o.value, o.label]),
    kept: model.data.map((p) => c.points.indexOf(p)),
    max: model.max,
    legend: model.legend.map((o) => [o.value, o.label]),
    segments: model.data.map((p) => stackSegments(p, model.legend).map((s) => [s.value, s.n])),
    labelled: labelledByWidth(models),
  };
}

const PICK_CASES: { xs: number[]; gap: number }[] = [
  { xs: [], gap: 52 },
  { xs: [10], gap: 52 },
  { xs: [0, 10, 20, 100, 105], gap: 50 },
  { xs: [0, 60, 120], gap: 50 },
  { xs: [0, 52, 104], gap: 52 },
  { xs: [0, 51.999, 104], gap: 52 },
];

// Activity strip cases (content-display.md §4.2). `today` is the local date in `tz`.
const ms = (iso: string) => Date.parse(iso);
const ACTIVITY: { name: string; tz: string; today: string; captured_at: number[] }[] = [
  { name: 'empty', tz: 'UTC', today: '2026-11-25', captured_at: [] },
  {
    // 2026-11-25 is a Wednesday: first cell Monday 2026-09-07 (BST), today in GMT.
    name: 'cell edges: first cell 00:00 local, today 23:59 local, and just outside',
    tz: 'Europe/London',
    today: '2026-11-25',
    captured_at: [
      ms('2026-09-06T22:59:59.999Z'),
      ms('2026-09-06T23:00:00Z'),
      ms('2026-11-25T23:59:00Z'),
      ms('2026-11-26T00:00:00Z'),
    ],
  },
  {
    name: '23:30 UTC is the next local day in Pacific/Auckland',
    tz: 'Pacific/Auckland',
    today: '2026-11-01',
    captured_at: [ms('2026-10-25T23:30:00Z')],
  },
  {
    name: '23:30 UTC is the same local day in America/Los_Angeles',
    tz: 'America/Los_Angeles',
    today: '2026-11-01',
    captured_at: [ms('2026-10-25T23:30:00Z')],
  },
  {
    // Sunday 2026-03-29 has 23 hours: 01:00 GMT -> 02:00 BST.
    name: 'Europe/London spring-forward week',
    tz: 'Europe/London',
    today: '2026-04-01',
    captured_at: [
      ms('2026-03-28T23:30:00Z'),
      ms('2026-03-29T00:30:00Z'),
      ms('2026-03-29T01:30:00Z'),
      ms('2026-03-29T22:59:00Z'),
      ms('2026-03-29T23:00:00Z'),
    ],
  },
  {
    // Sunday 2026-10-25 has 25 hours: 01:00-02:00 happens twice (BST, then GMT).
    name: 'Europe/London fall-back week',
    tz: 'Europe/London',
    today: '2026-10-28',
    captured_at: [
      ms('2026-10-24T22:59:00Z'),
      ms('2026-10-24T23:00:00Z'),
      ms('2026-10-25T00:30:00Z'),
      ms('2026-10-25T01:30:00Z'),
      ms('2026-10-25T23:59:00Z'),
      ms('2026-10-26T00:00:00Z'),
    ],
  },
  {
    // The last column has one cell; counts reach every intensity step.
    name: 'today on a Monday',
    tz: 'Europe/London',
    today: '2026-11-23',
    captured_at: [
      ms('2026-11-22T10:00:00Z'),
      ms('2026-11-22T11:00:00Z'),
      ms('2026-11-23T08:00:00Z'),
      ms('2026-11-23T09:00:00Z'),
      ms('2026-11-23T10:00:00Z'),
      ms('2026-11-23T11:00:00Z'),
      ms('2026-11-21T12:00:00Z'),
    ],
  },
  {
    // The grid is full; tomorrow (Monday) would start a new column and drop a week.
    name: 'today on a Sunday',
    tz: 'Europe/London',
    today: '2026-11-29',
    captured_at: [ms('2026-09-07T00:00:00Z'), ms('2026-11-29T12:00:00Z')],
  },
];

function activityCase(c: (typeof ACTIVITY)[number]) {
  const strip = activityStrip(c.captured_at, c.today, c.tz);
  return {
    ...c,
    first_day: strip.firstDay,
    from: new Date(localMidnight(strip.firstDay, c.tz)).toISOString(),
    cells: strip.cells.map((cell) => [cell.day, cell.count, activityLevel(cell.count)]),
    max: strip.max,
    total: strip.total,
  };
}

// Sparklines (content-display.md §4.3): every int/double series of stats-vectors.json at
// SPARK_WIDTH, and shapes the server doesn't send.
const SPARK_WIDTH = 160;
const SPARK_SYNTHETIC: { name: string; width: number; points: SeriesPoint[] }[] = [
  { name: 'sparkline: no points', width: SPARK_WIDTH, points: [] },
  {
    name: 'sparkline: no bucket has a mean',
    width: SPARK_WIDTH,
    points: [point('2025-01-06T00:00:00Z', { count: 3 })],
  },
  {
    name: 'sparkline: one point sits at the right edge, mid height',
    width: SPARK_WIDTH,
    points: [point('2025-01-06T00:00:00Z', { count: 1, mean: 3, min: 3, max: 3 })],
  },
  {
    name: 'sparkline: one value is a flat line',
    width: 100,
    points: [
      point('2025-01-06T00:00:00Z', { count: 1, mean: 3, min: 3, max: 3 }),
      point('2025-01-13T00:00:00Z', { count: 1, mean: 3, min: 3, max: 3 }),
    ],
  },
  {
    name: 'sparkline: x by time, buckets without a mean skipped, negatives',
    width: 108,
    points: [
      point('2025-01-01T00:00:00Z', { count: 1, mean: -2 }),
      point('2025-01-02T00:00:00Z', { count: 1 }),
      point('2025-01-03T00:00:00Z', { count: 2, mean: 6.25 }),
      point('2025-01-05T00:00:00Z', { count: 1, mean: 1 / 3 }),
    ],
  },
];

function sparkCase(name: string, points: readonly SeriesPoint[], width: number, inline: boolean) {
  const model = sparkline(points, width);
  return {
    name,
    width,
    ...(inline ? { points } : {}),
    ...(model ? { ...model, empty: false } : { empty: true }),
  };
}

// The timing models over each timing-stats-vectors.json case, bucketed in TIMING_TZ.
const TIMING_TZ = 'Europe/London';
const TIMING_BUCKETS: Bucket[] = ['day', 'week', 'month'];

// The lap-type cards and chart (content-display.md §4.1) over the timing-stats-vectors.json
// cases with lap types, and `laps` (untyped laps only: no cards, the v1 tiles).
const isLapTypeCase = (c: { name: string; expected: TopicTiming }) =>
  c.expected.lap_types.length > 0 || c.name === 'laps';

function lapTypesCase(c: { name: string; expected: TopicTiming }) {
  const timing = c.expected;
  const options = timing.lap_types.map((t) => ({ value: t.key, label: t.label }));
  const colorFor = optionColors(timing.lap_types.map((t) => t.key));
  return {
    name: c.name,
    tz: TIMING_TZ,
    cards: lapTypeCards(timing.lap_types).map((card) => ({ ...card, color: colorFor(card.key) })),
    charts: TIMING_BUCKETS.map((bucket) =>
      inZone(TIMING_TZ, () => {
        const points = lapTypesByBucket(timing.series, bucket);
        const models = WIDTHS.map((w) => stackedModel(points, options, w));
        const model = models[0];
        if (!model || options.length === 0) return { bucket, empty: true };
        return {
          bucket,
          empty: false,
          max: model.max,
          totals: model.data.map(seriesTotal),
          legend: model.legend.map((o) => [o.value, o.label]),
          segments: model.data.map((p) =>
            stackSegments(p, model.legend).map((s) => [s.value, s.n]),
          ),
          labelled: labelledByWidth(models),
          labels: {
            short: model.data.map((p) => formatBucket(p.start, bucket)),
            long: model.data.map((p) => formatBucket(p.start, bucket, 'long')),
          },
        };
      }),
    ),
  };
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

/** Each width's labelled indices, ascending. */
function labelledByWidth(
  models: readonly ({ labelled: Set<number> } | null)[],
): Record<string, number[]> {
  const out: Record<string, number[]> = {};
  models.forEach((m, i) => {
    out[String(WIDTHS[i])] = [...(m?.labelled ?? [])].sort((a, b) => a - b);
  });
  return out;
}

function seriesCase(c: InputCase, statsByTopic: Map<string, TopicStats>) {
  const series = c.response as QuestionSeries;
  const bucket = series.bucket;
  const tz = c.query.tz ?? 'UTC';
  const base = { name: c.name, tz, bucket, type: series.type };
  if (series.type === 'str') return { ...base, chart: 'none' };
  const labels = (points: { start: string }[]) =>
    inZone(tz, () => ({
      short: points.map((p) => formatBucket(p.start, bucket)),
      long: points.map((p) => formatBucket(p.start, bucket, 'long')),
    }));
  if (series.type === 'int' || series.type === 'double') {
    const models = WIDTHS.map((w) => lineModel(series.points, w));
    const model = models[0];
    if (!model) return { ...base, chart: 'line', empty: true };
    return {
      ...base,
      chart: 'line',
      kept: model.data.map((p) => series.points.indexOf(p)),
      ticks: model.ticks,
      tick_labels: model.ticks.map(formatTick),
      labelled: labelledByWidth(models),
      labels: labels(model.data),
      tooltips: model.data.map((p) => [
        formatNumber(p.mean),
        `${formatNumber(p.min)}–${formatNumber(p.max)} · n=${p.count}`,
      ]),
    };
  }
  // enum: the options (config order) come from the topic's stats, as on the page.
  const stats = statsByTopic.get(c.topic);
  const question = stats?.questions.find((q) => q.key === series.key) as EnumStats | undefined;
  const options = question?.options ?? [];
  const models = WIDTHS.map((w) => stackedModel(series.points, options, w));
  const model = models[0];
  if (!model) return { ...base, chart: 'stacked', empty: true };
  return {
    ...base,
    chart: 'stacked',
    options: options.map((o) => o.value),
    kept: model.data.map((p) => series.points.indexOf(p)),
    max: model.max,
    totals: model.data.map(seriesTotal),
    legend: model.legend.map((o) => [o.value, o.label]),
    segments: model.data.map((p) => stackSegments(p, model.legend).map((s) => [s.value, s.n])),
    labelled: labelledByWidth(models),
    labels: labels(model.data),
  };
}

function numericCard(q: NumericStats) {
  const dec = q.type === 'int' ? 1 : 2;
  const first = q.histogram[0];
  const last = q.histogram[q.histogram.length - 1];
  return {
    key: q.key,
    kind: 'numeric',
    mean: formatNumber(q.mean, dec),
    rows: [q.median, q.min, q.max, q.stddev, q.sum].map((v) => formatNumber(v, dec)),
    histogram: q.histogram.map(
      (b) => `${formatNumber(b.lower)}–${formatNumber(b.upper)}: ${b.count}`,
    ),
    histogram_ends: first && last ? [formatTick(first.lower), formatTick(last.upper)] : null,
  };
}

function enumCard(q: EnumStats) {
  const view = enumView(q);
  const colorFor = optionColors(q.options.map((o) => o.value));
  return {
    key: q.key,
    kind: 'enum',
    visible: view.visible.map((o) => o.value),
    top: view.top ? [view.top.value, formatPercent(view.top.share)] : null,
    shares: q.options.map((o) => [o.value, o.count.toLocaleString(), formatPercent(o.share)]),
    colors: q.options.map((o) => colorFor(o.value)),
  };
}

function strCard(q: StrStats) {
  return {
    key: q.key,
    kind: 'str',
    distinct: plural(q.distinct, 'distinct answer'),
    most_common: q.top.some((t) => t.count > 1)
      ? q.top.slice(0, 5).map((t) => [t.value, t.count])
      : null,
    recent: q.recent.slice(0, 5).map((r) => r.entry_id),
  };
}

function statsCase(c: InputCase) {
  const stats = c.response as TopicStats;
  const first = stats.first_captured_at;
  return {
    name: c.name,
    entries: stats.entry_count.toLocaleString(),
    // formatDate's options in the summary zone: its formatter is built at import, in whatever
    // zone the machine running this has, so TZ can't reach it.
    first: first ? summaryDate.format(new Date(first)) : '—',
    sources: stats.sources.slice(0, 4).map((s) => [s.value, s.count]),
    empty: stats.entry_count === 0,
    questions: stats.questions.map((q) => ({
      answered: `${q.count}/${q.count + q.missing}`,
      label: q.label,
      ...(q.type === 'enum' ? enumCard(q) : q.type === 'str' ? strCard(q) : numericCard(q)),
    })),
  };
}

function build(
  input: { cases: InputCase[] },
  timing: { cases: { name: string; expected: TopicTiming }[] },
) {
  const statsByTopic = new Map<string, TopicStats>();
  for (const c of input.cases) {
    if (c.kind === 'stats' && Object.keys(c.query).length === 0)
      statsByTopic.set(c.topic, c.response as TopicStats);
  }
  return {
    meta: {
      generator_version: GENERATOR_VERSION,
      locale: 'en-US',
      widths: WIDTHS,
      summary_tz: SUMMARY_TZ,
      semantics:
        'series[i] is the chart for the stats-vectors.json series case of the same name: ' +
        "'kept' indexes its response points (line: those with a mean; stacked: those with answers); " +
        "'labelled' indexes 'kept' per chart width; labels are formatBucket(start) in 'tz'. " +
        'stats[i] is the Overview for the stats case of the same name (dates in meta.summary_tz). ' +
        'activity[i] is activityStrip(captured_at, today, tz): cells [day, count, level] from ' +
        "first_day to today, 'from' the listEntries bound (first_day's local midnight, UTC). " +
        'sparklines[i] is sparkline(points, width) for the stats-vectors.json series case of the ' +
        "same name, or its inline 'points'. timing_models[i] is stepsByBucket(series, bucket) " +
        'and lapTypesByBucket(series, bucket) for the timing-stats-vectors.json case of the same ' +
        "name, bucketed in 'tz'. lap_types[i] is the Overview's lap-type cards (cards: " +
        'lapTypeCards(lap_types) plus optionColors over the lap-type keys) and the stacked ' +
        "'Time per lap type' chart per bucket (charts: stackedModel(lapTypesByBucket(series, " +
        'bucket), lap types as options) for the timing-stats-vectors.json case of the same name; ' +
        "no cards means the v1 lap tiles, and a chart is 'empty' when there are no lap types or " +
        'no runs.',
      spark_width: SPARK_WIDTH,
    },
    default_bucket: RANGE_PRESETS.map((r) => [r.value, defaultBucket(r.value)]),
    ticks: TICK_CASES.map(([min, max]) => {
      const ticks = niceTicks(min, max, 4);
      return { min, max, ticks, labels: ticks.map(formatTick) };
    }),
    numbers: NUMBERS.flatMap((n) =>
      [1, 2].map((dec) => ({
        value: n === null || Number.isNaN(n) ? String(n) : n,
        dec,
        text: formatNumber(n, dec),
      })),
    ),
    percents: PERCENTS.map((share) => ({ share, text: formatPercent(share) })),
    pick: PICK_CASES.map((c) => ({
      ...c,
      labelled: [...pickLabels(c.xs, c.gap)].sort((a, b) => a - b),
    })),
    series: input.cases.filter((c) => c.kind === 'series').map((c) => seriesCase(c, statsByTopic)),
    synthetic: SYNTHETIC.map(syntheticCase),
    stats: input.cases.filter((c) => c.kind === 'stats').map(statsCase),
    activity: ACTIVITY.map(activityCase),
    sparklines: [
      ...input.cases
        .filter(
          (c) =>
            c.kind === 'series' &&
            ((c.response as QuestionSeries).type === 'int' ||
              (c.response as QuestionSeries).type === 'double'),
        )
        .map((c) => sparkCase(c.name, (c.response as QuestionSeries).points, SPARK_WIDTH, false)),
      ...SPARK_SYNTHETIC.map((c) => sparkCase(c.name, c.points, c.width, true)),
    ],
    timing_models: timing.cases.flatMap((c) =>
      TIMING_BUCKETS.map((bucket) => ({
        name: c.name,
        tz: TIMING_TZ,
        bucket,
        steps_by_bucket: inZone(TIMING_TZ, () => stepsByBucket(c.expected.series, bucket)),
        lap_types_by_bucket: inZone(TIMING_TZ, () => lapTypesByBucket(c.expected.series, bucket)),
      })),
    ),
    lap_types: timing.cases.filter(isLapTypeCase).map(lapTypesCase),
  };
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/** Recursively sort object keys (Python's `sort_keys=True`). */
function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v !== null && typeof v === 'object')
    return Object.fromEntries(
      Object.keys(v)
        .sort()
        .map((k) => [k, sortKeys((v as Record<string, unknown>)[k])]),
    );
  return v;
}

/** Same layout as `dump_cases` in backend/tests/vectors.py: one compact case per line. */
function dumpCases(doc: Record<string, unknown>): string {
  const parts = Object.keys(doc)
    .sort()
    .map((key) => {
      const value = doc[key];
      const rendered =
        Array.isArray(value) && value.length > 0
          ? `[\n${value.map((item) => `    ${JSON.stringify(sortKeys(item))}`).join(',\n')}\n  ]`
          : JSON.stringify(sortKeys(value), null, 2).replaceAll('\n', '\n  ');
      return `  ${JSON.stringify(key)}: ${rendered}`;
    });
  return `{\n${parts.join(',\n')}\n}\n`;
}

describe('stats chart vectors (shared with iOS)', () => {
  it('runs in en-US, and the zone follows TZ', () => {
    expect(new Intl.NumberFormat().resolvedOptions().locale).toBe('en-US');
    expect(inZone('America/Santiago', () => new Date('2025-09-07T04:00:00Z').getDate())).toBe(7);
    expect(inZone('UTC', () => new Date('2025-09-07T03:00:00Z').getDate())).toBe(7);
    expect(inZone('America/Santiago', () => new Date('2025-09-07T03:00:00Z').getDate())).toBe(6);
  });

  it(`${FILE_LABEL} is up to date`, async () => {
    const fsName = 'node:fs';
    const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
    const input = JSON.parse(fs.readFileSync(INPUT, 'utf8')) as { cases: InputCase[] };
    const timing = JSON.parse(fs.readFileSync(TIMING_INPUT, 'utf8')) as {
      cases: { name: string; expected: TopicTiming }[];
    };
    const content = dumpCases(build(input, timing));
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS === '1') {
      fs.writeFileSync(FILE, content);
      return;
    }
    const stale = `${FILE_LABEL} is stale - run 'make vectors'`;
    expect(fs.existsSync(FILE), stale).toBe(true);
    expect(fs.readFileSync(FILE, 'utf8') === content, stale).toBe(true);
  });
});
