import type {
  SeriesPoint,
  TimingLapTypeStats,
  TimingSeriesPoint,
  TimingStepStats,
} from '../../client';
import { toOffsetIso } from '../../lib/dates';
import { plural } from '../../lib/format';
import { fmtDuration } from '../../lib/runs/format';
import type { Bucket } from './chartUtils';

/**
 * The Overview's Timing charts as pure functions (timers.md §9, §11.5): the run totals and
 * the per-step and per-lap-type times bucketed by when each run ended, in the shapes `LineChart` and
 * `StackedBars` draw (`SeriesPoint`), duration axis ticks, and the per-step bars. Every
 * value is active time in milliseconds. And the lap-type cards' text (content-display.md §4.1).
 *
 * Also the Overview's activity strip and numeric sparklines (content-display.md §4.2, §4.3).
 * All of these are pinned in shared/fixtures/stats-chart-vectors.json for the iOS port.
 */

/** The start of `ms`'s bucket in the browser's zone: local midnight, Monday, or the 1st. */
export function bucketStart(ms: number, bucket: Bucket): Date {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  if (bucket === 'week') d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  if (bucket === 'month') d.setDate(1);
  return d;
}

const floorMean = (xs: readonly number[]): number =>
  Math.floor(xs.reduce((a, b) => a + b, 0) / xs.length);

function groupByBucket(
  series: readonly TimingSeriesPoint[],
  bucket: Bucket,
): [string, TimingSeriesPoint[]][] {
  const groups = new Map<number, TimingSeriesPoint[]>();
  for (const p of series) {
    const start = bucketStart(new Date(p.captured_at).getTime(), bucket).getTime();
    const list = groups.get(start);
    if (list) list.push(p);
    else groups.set(start, [p]);
  }
  return [...groups.entries()]
    .sort(([a], [b]) => a - b)
    .map(([start, points]) => [toOffsetIso(new Date(start)), points]);
}

/** Run totals per bucket: the mean (floored), min and max of `active_ms`, every run counted. */
export function totalsByBucket(
  series: readonly TimingSeriesPoint[],
  bucket: Bucket,
): SeriesPoint[] {
  return groupByBucket(series, bucket).map(([start, points]) => {
    const ms = points.map((p) => p.active_ms);
    return {
      start,
      count: points.length,
      mean: floorMean(ms),
      min: Math.min(...ms),
      max: Math.max(...ms),
      option_counts: {},
    };
  });
}

/** Each key's floored mean per run in each bucket, a run without the key counting 0. */
function meanPerRunByBucket(
  series: readonly TimingSeriesPoint[],
  bucket: Bucket,
  times: (p: TimingSeriesPoint) => Record<string, number>,
): SeriesPoint[] {
  return groupByBucket(series, bucket).map(([start, points]) => {
    const keys = new Set(points.flatMap((p) => Object.keys(times(p))));
    const option_counts: Record<string, number> = {};
    for (const key of keys) option_counts[key] = floorMean(points.map((p) => times(p)[key] ?? 0));
    return { start, count: points.length, mean: null, min: null, max: null, option_counts };
  });
}

/**
 * Each step's mean time per run in a bucket, stacked (`option_counts` keyed by step key): a
 * run that didn't time the step counts as 0, so a bar's height is the mean time per run spent
 * in steps. Laps aren't steps and aren't in the stack.
 */
export function stepsByBucket(series: readonly TimingSeriesPoint[], bucket: Bucket): SeriesPoint[] {
  return meanPerRunByBucket(series, bucket, (p) => p.steps);
}

/**
 * Each lap type's mean time per run in a bucket, stacked (`option_counts` keyed by lap-type
 * key), as `stepsByBucket` does for steps (content-display.md §4.1): a run's time in a type is
 * the sum of its laps of that type, a run without one counts as 0. Untyped laps and steps
 * aren't in the stack, and a lap-type key equal to a step key stays its own (timers2.md §7.4).
 */
export function lapTypesByBucket(
  series: readonly TimingSeriesPoint[],
  bucket: Bucket,
): SeriesPoint[] {
  return meanPerRunByBucket(series, bucket, (p) => p.lap_types);
}

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const STEPS = [
  SECOND,
  2 * SECOND,
  5 * SECOND,
  10 * SECOND,
  15 * SECOND,
  30 * SECOND,
  MINUTE,
  2 * MINUTE,
  5 * MINUTE,
  10 * MINUTE,
  15 * MINUTE,
  30 * MINUTE,
  HOUR,
  2 * HOUR,
  6 * HOUR,
  12 * HOUR,
  24 * HOUR,
];

/** Axis ticks for durations on whole seconds, minutes or hours (so `fmtDuration` reads well). */
export function durationTicks(min: number, max: number, count = 4): number[] {
  let lo = Math.max(0, min);
  let hi = Math.max(lo, max);
  if (lo === hi) {
    lo = Math.max(0, lo - MINUTE);
    hi += MINUTE;
  }
  const step =
    STEPS.find((s) => (hi - lo) / s <= count) ??
    24 * HOUR * Math.ceil((hi - lo) / (count * 24 * HOUR));
  const ticks: number[] = [];
  for (let v = Math.floor(lo / step) * step; v <= Math.ceil(hi / step) * step; v += step)
    ticks.push(v);
  return ticks;
}

export interface StepBar {
  key: string;
  label: string;
  current: boolean;
  median_ms: number | null;
  best_ms: number | null;
  done: number;
  skipped: number;
  /** The median's share of the longest median, 0–1, for the bar's width. */
  share: number;
}

/** One bar per step: its median against the longest step's median. */
export function stepBars(steps: readonly TimingStepStats[]): StepBar[] {
  const longest = Math.max(1, ...steps.map((s) => s.median_ms ?? 0));
  return steps.map((s) => ({
    key: s.key,
    label: s.label,
    current: s.current,
    median_ms: s.median_ms,
    best_ms: s.best_ms,
    done: s.done,
    skipped: s.skipped,
    share: (s.median_ms ?? 0) / longest,
  }));
}

/** A lap-type card's text (content-display.md §4.1): label, lap count, median, best, mean. */
export interface LapTypeCard {
  key: string;
  label: string;
  /** "4 laps". */
  laps: string;
  median: string;
  best: string;
  mean: string;
}

const dur = (ms: number | null): string => (ms === null ? '—' : fmtDuration(ms));

/** One card per lap type, in the server's order (the current version's types first). */
export function lapTypeCards(lapTypes: readonly TimingLapTypeStats[]): LapTypeCard[] {
  return lapTypes.map((t) => ({
    key: t.key,
    label: t.label,
    laps: plural(t.laps, 'lap'),
    median: dur(t.median_ms),
    best: dur(t.best_ms),
    mean: dur(t.mean_ms),
  }));
}

// ---------------------------------------------------------------------------
// Activity strip (content-display.md §4.2)
// ---------------------------------------------------------------------------

/** Weeks in the activity strip; its cells are local calendar days, Monday-started weeks. */
export const ACTIVITY_WEEKS = 12;
const DAY_MS = 86_400_000;

const dayFormats = new Map<string, Intl.DateTimeFormat>();

/** `ms`'s local calendar date in `tz`, "YYYY-MM-DD". */
export function localDay(ms: number, tz: string): string {
  let fmt = dayFormats.get(tz);
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    });
    dayFormats.set(tz, fmt);
  }
  const part = (type: string) => fmt.formatToParts(ms).find((p) => p.type === type)?.value ?? '';
  return `${part('year')}-${part('month')}-${part('day')}`;
}

/** Days since 1970-01-01 of a "YYYY-MM-DD" date (calendar arithmetic, no zone). */
const dayNumber = (day: string): number => {
  const [y = 0, m = 1, d = 1] = day.split('-').map(Number);
  return Math.round(Date.UTC(y, m - 1, d) / DAY_MS);
};
const dayString = (n: number): string => new Date(n * DAY_MS).toISOString().slice(0, 10);

/** `day` plus `n` calendar days. */
export function addDays(day: string, n: number): string {
  return dayString(dayNumber(day) + n);
}

/**
 * The first instant of `day` in `tz`, epoch ms: local midnight, or the end of the gap when
 * the clocks skip midnight (America/Santiago). The first instant whose local date is `day`.
 */
export function localMidnight(day: string, tz: string): number {
  // Every zone's offset is within ±14 h, so the answer is within 15 h of UTC midnight.
  const utc = dayNumber(day) * DAY_MS;
  let lo = utc - 15 * 3_600_000;
  let hi = utc + 15 * 3_600_000;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (localDay(mid, tz) >= day) hi = mid;
    else lo = mid;
  }
  return hi;
}

export interface ActivityStrip {
  /** The first cell: the Monday 11 weeks before this week's Monday. */
  firstDay: string;
  /** One cell per day from `firstDay` to `today`, in order (78–84 of them); the grid's
   *  slots after today are blank and not listed. */
  cells: { day: string; count: number }[];
  /** The largest cell count (0 when empty). */
  max: number;
  /** The entries that fell in a cell (entries outside the grid aren't counted). */
  total: number;
}

/**
 * Entries per local calendar day over the last 12 Monday-started weeks, today last. An entry
 * counts in the cell of its `captured_at` (epoch ms) converted to `tz` and truncated to the
 * date; `today` is the local date in `tz`. The query bound is `localMidnight(firstDay, tz)`.
 */
export function activityStrip(
  capturedAt: readonly number[],
  today: string,
  tz: string,
): ActivityStrip {
  const end = dayNumber(today);
  // 1970-01-01 was a Thursday: Monday is 0 here.
  const weekday = (((end + 3) % 7) + 7) % 7;
  const start = end - weekday - 7 * (ACTIVITY_WEEKS - 1);
  const counts = new Map<string, number>();
  for (const ms of capturedAt) {
    const day = localDay(ms, tz);
    counts.set(day, (counts.get(day) ?? 0) + 1);
  }
  const cells: ActivityStrip['cells'] = [];
  for (let n = start; n <= end; n++) {
    const day = dayString(n);
    cells.push({ day, count: counts.get(day) ?? 0 });
  }
  return {
    firstDay: dayString(start),
    cells,
    max: Math.max(0, ...cells.map((c) => c.count)),
    total: cells.reduce((a, c) => a + c.count, 0),
  };
}

/** A cell's intensity step: 0, 1, 2–3, 4+ → 0–3 (`sunken`, then the tint at 35/65/100 %). */
export function activityLevel(count: number): 0 | 1 | 2 | 3 {
  return count <= 0 ? 0 : count === 1 ? 1 : count <= 3 ? 2 : 3;
}

// ---------------------------------------------------------------------------
// Sparklines (content-display.md §4.3)
// ---------------------------------------------------------------------------

/** A sparkline's height and its inset (room for the last point's dot), px. */
export const SPARK_LAYOUT = { height: 48, pad: 4 } as const;

export interface Sparkline {
  /** `[x, y]` per bucket with a mean, in time order; y grows downward. Rounded to 0.01. */
  path: [number, number][];
  /** The last point (the marked one) and its mean. */
  last: { x: number; y: number; value: number };
  /** The smallest and largest mean drawn (the end labels). */
  min: number;
  max: number;
}

const round2 = (v: number): number => Math.round(v * 100) / 100;

/**
 * A numeric question's bucket means as a small line, `width` × 48 px: x by bucket start
 * (one point sits at the right edge), y from the smallest mean (bottom) to the largest (top),
 * a flat line in the middle. Buckets without a mean are skipped; null when none has one.
 */
export function sparkline(points: readonly SeriesPoint[], width: number): Sparkline | null {
  const { height, pad } = SPARK_LAYOUT;
  const data = points.filter((p): p is SeriesPoint & { mean: number } => p.mean !== null);
  const lastPoint = data[data.length - 1];
  if (!lastPoint) return null;
  const means = data.map((p) => p.mean);
  const min = Math.min(...means);
  const max = Math.max(...means);
  const t0 = new Date(data[0]?.start ?? 0).getTime();
  const t1 = new Date(lastPoint.start).getTime();
  const x = (t: number) =>
    t1 === t0 ? width - pad : pad + ((t - t0) / (t1 - t0)) * (width - 2 * pad);
  const y = (v: number) =>
    max === min ? height / 2 : pad + ((max - v) / (max - min)) * (height - 2 * pad);
  const path = data.map((p): [number, number] => [
    round2(x(new Date(p.start).getTime())),
    round2(y(p.mean)),
  ]);
  const [lx = 0, ly = 0] = path[path.length - 1] ?? [];
  return { path, last: { x: lx, y: ly, value: lastPoint.mean }, min, max };
}
