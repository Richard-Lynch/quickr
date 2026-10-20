/**
 * Generator + drift check for shared/fixtures/stats-chart-vectors.json: what the Overview's
 * charts and summaries make of the server's stats and series (the inputs are the real
 * responses in shared/fixtures/stats-vectors.json), for the iOS port. It runs the PWA's own
 * code: the chart models (`chartModels.ts`), `niceTicks`, `formatBucket`, `formatTick`,
 * `formatNumber`, `formatPercent`, `plural` and `optionColors`.
 *
 * Text is en-US (the generator checks the locale), and bucket labels are in each series'
 * `tz`, which the generator sets as the process zone before labelling it. Label positions
 * depend on the chart's width, so `labelled` is given for each of `meta.widths`.
 *
 * With QUICKR_UPDATE_VECTORS=1 (`make vectors`) this writes the file; otherwise it fails when
 * the committed file differs, like backend/tests/vectors.py.
 */
import { afterAll, describe, expect, it } from 'vitest';

import type { EnumStats, NumericStats, QuestionSeries, StrStats, TopicStats } from '../../client';
import { RANGE_PRESETS, formatDate } from '../../lib/dates';
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
import { formatBucket, formatTick, niceTicks, pickLabels } from './chartUtils';

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
const FILE = `${DIR}/stats-chart-vectors.json`;
const FILE_LABEL = 'shared/fixtures/stats-chart-vectors.json';
const GENERATOR_VERSION = 1;
const WIDTHS = [320, 600];
/** The zone the summaries' dates are shown in. */
const SUMMARY_TZ = 'Europe/London';

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
const PICK_CASES: { xs: number[]; gap: number }[] = [
  { xs: [], gap: 52 },
  { xs: [10], gap: 52 },
  { xs: [0, 10, 20, 100, 105], gap: 50 },
  { xs: [0, 60, 120], gap: 50 },
  { xs: [0, 52, 104], gap: 52 },
  { xs: [0, 51.999, 104], gap: 52 },
];

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
    first: first ? inZone(SUMMARY_TZ, () => formatDate(first)) : '—',
    sources: stats.sources.slice(0, 4).map((s) => [s.value, s.count]),
    empty: stats.entry_count === 0,
    questions: stats.questions.map((q) => ({
      answered: `${q.count}/${q.count + q.missing}`,
      label: q.label,
      ...(q.type === 'enum' ? enumCard(q) : q.type === 'str' ? strCard(q) : numericCard(q)),
    })),
  };
}

function build(input: { cases: InputCase[] }) {
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
        'stats[i] is the Overview for the stats case of the same name (dates in meta.summary_tz).',
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
    stats: input.cases.filter((c) => c.kind === 'stats').map(statsCase),
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
    const content = dumpCases(build(input));
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS === '1') {
      fs.writeFileSync(FILE, content);
      return;
    }
    const stale = `${FILE_LABEL} is stale - run 'make vectors'`;
    expect(fs.existsSync(FILE), stale).toBe(true);
    expect(fs.readFileSync(FILE, 'utf8') === content, stale).toBe(true);
  });
});
