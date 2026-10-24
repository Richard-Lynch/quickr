import type { SeriesPoint, TimingSeriesPoint, TimingStepStats } from '../../client';
import { toOffsetIso } from '../../lib/dates';
import type { Bucket } from './chartUtils';

/**
 * The Overview's Timing charts as pure functions (timers.md §9, §11.5): the run totals and
 * the per-step times bucketed by when each run ended, in the shapes `LineChart` and
 * `StackedBars` draw (`SeriesPoint`), duration axis ticks, and the per-step bars. Every
 * value is active time in milliseconds.
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

/**
 * Each step's mean time per run in a bucket, stacked (`option_counts` keyed by step key): a
 * run that didn't time the step counts as 0, so a bar's height is the mean time per run spent
 * in steps. Laps aren't steps and aren't in the stack.
 */
export function stepsByBucket(series: readonly TimingSeriesPoint[], bucket: Bucket): SeriesPoint[] {
  return groupByBucket(series, bucket).map(([start, points]) => {
    const keys = new Set(points.flatMap((p) => Object.keys(p.steps)));
    const option_counts: Record<string, number> = {};
    for (const key of keys) option_counts[key] = floorMean(points.map((p) => p.steps[key] ?? 0));
    return { start, count: points.length, mean: null, min: null, max: null, option_counts };
  });
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
