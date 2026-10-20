import type { EnumOptionCount, EnumStats, SeriesPoint } from '../../client';
import { niceTicks, pickLabels, scaleLinear } from './chartUtils';

/**
 * The charts' layout decisions as pure functions (what each chart shows, its axis ticks and
 * which x labels fit), so the components stay drawing code and the iOS port can check its
 * charts against the same logic (`stats.vectors.test.ts`).
 */

/** Minimum gap between two x-axis labels, in px. */
export const LABEL_GAP = 52;

export const LINE_LAYOUT = {
  height: 170,
  pad: { top: 10, right: 8, bottom: 22, left: 36 },
} as const;

export interface LineModel {
  /** The buckets with a mean, in order. */
  data: SeriesPoint[];
  ticks: number[];
  x: (t: number) => number;
  y: (v: number) => number;
  /** Each kept bucket's x position. */
  xs: number[];
  /** Indices of `data` whose x label is drawn. */
  labelled: Set<number>;
}

/** Mean per bucket with a min–max band; null when no bucket has a mean. */
export function lineModel(points: readonly SeriesPoint[], width: number): LineModel | null {
  const { height, pad } = LINE_LAYOUT;
  const data = points.filter((p) => p.mean !== null);
  if (data.length === 0) return null;
  const lows = data.map((p) => p.min ?? p.mean ?? 0);
  const highs = data.map((p) => p.max ?? p.mean ?? 0);
  const ticks = niceTicks(Math.min(...lows), Math.max(...highs), 4);
  const y0 = ticks[0] ?? 0;
  const y1 = ticks[ticks.length - 1] ?? 1;
  const t0 = new Date(data[0]?.start ?? 0).getTime();
  const t1 = new Date(data[data.length - 1]?.start ?? 0).getTime();
  const x = scaleLinear(
    t0,
    t1 === t0 ? t0 + 1 : t1,
    pad.left + (t1 === t0 ? (width - pad.left - pad.right) / 2 : 0),
    width - pad.right,
  );
  const y = scaleLinear(y0, y1, height - pad.bottom, pad.top);
  const xs = data.map((p) => x(new Date(p.start).getTime()));
  return { data, ticks, x, y, xs, labelled: pickLabels(xs, LABEL_GAP) };
}

export const BARS_LAYOUT = { height: 150, pad: { top: 6, bottom: 20 }, gap: 3 } as const;

export interface StackedModel {
  /** The buckets with answers, in order. */
  data: SeriesPoint[];
  /** The tallest bucket's total (at least 1). */
  max: number;
  /** Bar width and the left offset that centres the bars. */
  bw: number;
  offset: number;
  /** The options that appear, config order first, then unknown values as they appear. */
  legend: { value: string; label: string }[];
  labelled: Set<number>;
}

export function seriesTotal(p: SeriesPoint): number {
  return Object.values(p.option_counts).reduce((a, b) => a + b, 0);
}

/** Counts per option per bucket, stacked; null when no bucket has an answer. */
export function stackedModel(
  points: readonly SeriesPoint[],
  options: readonly { value: string; label: string }[],
  width: number,
): StackedModel | null {
  const { gap } = BARS_LAYOUT;
  const data = points.filter((p) => p.count > 0);
  if (data.length === 0) return null;
  const max = Math.max(1, ...data.map(seriesTotal));
  const bw = Math.min(36, (width - gap * (data.length - 1)) / data.length);
  const used = bw * data.length + gap * (data.length - 1);
  const offset = (width - used) / 2;
  const known = new Set(options.map((o) => o.value));
  const seen = new Set(data.flatMap((p) => Object.keys(p.option_counts)));
  const legend = [
    ...options.filter((o) => seen.has(o.value)).map((o) => ({ value: o.value, label: o.label })),
    ...[...seen].filter((v) => !known.has(v)).map((v) => ({ value: v, label: v })),
  ];
  const labelled = pickLabels(
    data.map((_, i) => offset + i * (bw + gap) + bw / 2),
    LABEL_GAP,
  );
  return { data, max, bw, offset, legend, labelled };
}

/** A bucket's stacked segments, bottom up: the legend's options it has, in legend order. */
export function stackSegments(
  p: SeriesPoint,
  legend: readonly { value: string; label: string }[],
): { value: string; n: number }[] {
  return legend.map((o) => ({ value: o.value, n: p.option_counts[o.value] ?? 0 })).filter((s) => s.n > 0);
}

export interface EnumView {
  /** The bars: archived options only when they were picked. */
  visible: EnumOptionCount[];
  /** "Most often": the first option with the highest count, when any was picked. */
  top: EnumOptionCount | null;
}

export function enumView(stats: EnumStats): EnumView {
  const top = [...stats.options].sort((a, b) => b.count - a.count)[0];
  return {
    visible: stats.options.filter((o) => !o.archived || o.count > 0),
    top: top && top.count > 0 ? top : null,
  };
}
