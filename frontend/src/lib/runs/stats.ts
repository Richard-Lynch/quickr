/**
 * Timing stats: best, median and mean run times, per step, laps and pauses (timers.md §9.1).
 *
 * A port of backend/app/services/timing_stats.py, the model behind the timing charts;
 * `shared/fixtures/timing-stats-vectors.json` is the contract. Every duration is active
 * time in integer milliseconds. Best, median and mean of run totals count complete runs
 * only; per-step stats, laps, pauses and the series count every timed run. Untimed entries
 * (`timing` null) count toward nothing here.
 */
import type { SeriesPoint, StepStats, Summary, TimerStep, Timing, TopicTiming } from './types';

export interface TimedEntry {
  entry_id: string;
  captured_at: number; // epoch milliseconds
  timing: Timing | null;
}

/** The middle value; `floor((a + b) / 2)` of the two middle ones for an even count. */
export function median(values: readonly number[]): number | null {
  if (values.length === 0) return null;
  const ordered = [...values].sort((a, b) => a - b);
  const mid = Math.floor(ordered.length / 2);
  const [lo = 0, hi = 0] = ordered.slice(mid - 1 + (ordered.length % 2), mid + 1);
  return ordered.length % 2 ? lo : Math.floor((lo + hi) / 2);
}

/** `floor(sum / n)`. */
export function mean(values: readonly number[]): number | null {
  return values.length ? Math.floor(values.reduce((a, b) => a + b, 0) / values.length) : null;
}

const best = (values: readonly number[]): number | null =>
  values.length ? values.reduce((a, b) => Math.min(a, b)) : null;

export function summary(values: readonly number[]): Summary {
  return { best_ms: best(values), median_ms: median(values), mean_ms: mean(values) };
}

/** Each step key's label in the latest version that has it. */
export function stepLabels(
  versions: ReadonlyMap<number, readonly TimerStep[] | null>,
): Map<string, string> {
  const labels = new Map<string, string>();
  for (const n of [...versions.keys()].sort((a, b) => a - b)) {
    for (const step of versions.get(n) ?? []) labels.set(step.key, step.label);
  }
  return labels;
}

/**
 * Timing stats over `entries` (already filtered to the range).
 *
 * `versions` maps each version number of the topic to its steps (null when that version
 * isn't timed). `steps` lists only keys seen in range (done or skipped): the current
 * version's first, in step order, then the rest by key. A key keeps the label of the
 * latest version that has it, else its latest segment's.
 */
export function timingStats(
  entries: readonly TimedEntry[],
  versions: ReadonlyMap<number, readonly TimerStep[] | null>,
  currentVersion: number,
): TopicTiming {
  const timed = entries
    .filter((e): e is TimedEntry & { timing: Timing } => e.timing !== null)
    .sort((a, b) =>
      a.captured_at !== b.captured_at
        ? a.captured_at - b.captured_at
        : a.entry_id < b.entry_id
          ? -1
          : a.entry_id > b.entry_id
            ? 1
            : 0,
    );
  const current = (versions.get(currentVersion) ?? []).map((s) => s.key);
  const labels = stepLabels(versions);
  const latestLabels = new Map<string, string>(); // a key in no version: its latest segment's label

  const done = new Map<string, number[]>();
  const skipped = new Map<string, number>();
  const lapTotals: number[] = [];
  const paused: number[] = [];
  const series: SeriesPoint[] = [];
  for (const e of timed) {
    const t = e.timing;
    const steps: Record<string, number> = {};
    for (const s of t.segments) {
      if (s.step === null) continue;
      steps[s.step] = s.active_ms;
      const durations = done.get(s.step);
      if (durations) durations.push(s.active_ms);
      else done.set(s.step, [s.active_ms]);
      latestLabels.set(s.step, s.label);
    }
    for (const key of t.skipped) skipped.set(key, (skipped.get(key) ?? 0) + 1);
    const laps = t.segments.filter((s) => s.kind === 'lap').map((s) => s.active_ms);
    if (laps.length) lapTotals.push(laps.reduce((a, b) => a + b, 0));
    if (t.paused_ms > 0) paused.push(t.paused_ms); // a zero-length pause doesn't count
    series.push({
      entry_id: e.entry_id,
      captured_at: e.captured_at,
      started_at: t.started_at,
      active_ms: t.active_ms,
      paused_ms: t.paused_ms,
      complete: t.complete,
      steps,
    });
  }

  const seen = new Set([...done.keys(), ...skipped.keys()]);
  const order = [
    ...current.filter((k) => seen.has(k)),
    ...[...seen].filter((k) => !current.includes(k)).sort(),
  ];
  const complete = timed.filter((e) => e.timing.complete).map((e) => e.timing.active_ms);
  return {
    runs: timed.length,
    complete_runs: complete.length,
    total: summary(complete),
    steps: order.map((key): StepStats => ({
      key,
      label: labels.get(key) || (latestLabels.get(key) ?? key),
      current: current.includes(key),
      done: done.get(key)?.length ?? 0,
      skipped: skipped.get(key) ?? 0,
      ...summary(done.get(key) ?? []),
    })),
    laps: {
      runs_with_laps: lapTotals.length,
      median_ms: median(lapTotals),
      mean_ms: mean(lapTotals),
    },
    paused: { runs_with_pauses: paused.length, median_ms: median(paused) },
    series,
  };
}
