/**
 * Timing stats: best, median and mean run times, per step, per lap type, laps and pauses
 * (timers.md §9.1, timers2.md §7.4).
 *
 * A port of backend/app/services/timing_stats.py, the model behind the timing charts;
 * `shared/fixtures/timing-stats-vectors.json` is the contract. Every duration is active
 * time in integer milliseconds. Best, median and mean of run totals count complete runs
 * only; per-step stats, lap types, laps, pauses and the series count every timed run.
 * Untimed entries (`timing` null) count toward nothing here. Step buckets and lap-type
 * buckets are keyed separately: the shared key namespace of timers2.md §1.1 is per timer,
 * not per topic, so a lap type whose key equals a historic step's never joins that step's
 * bucket, nor the other way round.
 */
import type {
  FoldTimer,
  LapTypeStats,
  SeriesPoint,
  StepStats,
  Summary,
  Timing,
  TopicTiming,
} from './types';

function push(map: Map<string, number[]>, key: string, value: number): void {
  const values = map.get(key);
  if (values) values.push(value);
  else map.set(key, [value]);
}

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

/** A topic's versions: each version number's timer, null when that version isn't timed. */
export type TimerVersions = ReadonlyMap<number, FoldTimer | null>;

/** Each key's label in the latest version that has it, over `pick`'s list of each timer. */
function latestLabels(
  versions: TimerVersions,
  pick: (t: FoldTimer) => readonly { key: string; label: string }[] | undefined,
): Map<string, string> {
  const labels = new Map<string, string>();
  for (const n of [...versions.keys()].sort((a, b) => a - b)) {
    const timer = versions.get(n);
    for (const item of (timer && pick(timer)) ?? []) labels.set(item.key, item.label);
  }
  return labels;
}

/** Each step key's label in the latest version that has it. */
export const stepLabels = (versions: TimerVersions) => latestLabels(versions, (t) => t.steps);

/** Each lap-type key's label in the latest version that has it. */
export const lapTypeLabels = (versions: TimerVersions) => latestLabels(versions, (t) => t.laps);

/** The current version's keys first, in its order, then the rest by key (code points). */
function ordered(current: readonly string[], seen: ReadonlySet<string>): string[] {
  return [
    ...current.filter((k) => seen.has(k)),
    ...[...seen].filter((k) => !current.includes(k)).sort(),
  ];
}

/**
 * Timing stats over `entries` (already filtered to the range).
 *
 * `versions` maps each version number of the topic to its timer (null when that version
 * isn't timed). `steps` and `lap_types` list only keys seen in range (done or skipped
 * steps; lap types with a lap segment): the current version's first, in its order, then
 * the rest by key. A key keeps the label of the latest version that has it, else (steps)
 * its latest segment's.
 */
export function timingStats(
  entries: readonly TimedEntry[],
  versions: TimerVersions,
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
  const currentTimer = versions.get(currentVersion) ?? null;
  const current = (currentTimer?.steps ?? []).map((s) => s.key);
  const currentTypes = (currentTimer?.laps ?? []).map((t) => t.key);
  const labels = stepLabels(versions);
  const typeLabels = lapTypeLabels(versions);
  const segmentLabels = new Map<string, string>(); // a key in no version: its latest segment's label

  const done = new Map<string, number[]>();
  const skipped = new Map<string, number>();
  const typed = new Map<string, number[]>();
  const lapTotals: number[] = [];
  const paused: number[] = [];
  const series: SeriesPoint[] = [];
  for (const e of timed) {
    const t = e.timing;
    const steps: Record<string, number> = {};
    const byType: Record<string, number> = {};
    for (const s of t.segments) {
      if (s.step !== null) {
        steps[s.step] = s.active_ms;
        push(done, s.step, s.active_ms);
        segmentLabels.set(s.step, s.label);
      } else if (s.lap_type !== null) {
        push(typed, s.lap_type, s.active_ms);
        // Own keys only: a lap type may be called `constructor`.
        const sum = Object.hasOwn(byType, s.lap_type) ? (byType[s.lap_type] ?? 0) : 0;
        byType[s.lap_type] = sum + s.active_ms;
      }
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
      lap_types: byType,
    });
  }

  const order = ordered(current, new Set([...done.keys(), ...skipped.keys()]));
  const complete = timed.filter((e) => e.timing.complete).map((e) => e.timing.active_ms);
  return {
    runs: timed.length,
    complete_runs: complete.length,
    total: summary(complete),
    steps: order.map((key): StepStats => ({
      key,
      label: labels.get(key) || (segmentLabels.get(key) ?? key),
      current: current.includes(key),
      done: done.get(key)?.length ?? 0,
      skipped: skipped.get(key) ?? 0,
      ...summary(done.get(key) ?? []),
    })),
    lap_types: ordered(currentTypes, new Set(typed.keys())).map((key): LapTypeStats => {
      const durations = typed.get(key) ?? [];
      return {
        key,
        label: typeLabels.get(key) ?? key,
        laps: durations.length,
        ...summary(durations),
      };
    }),
    laps: {
      runs_with_laps: lapTotals.length,
      median_ms: median(lapTotals),
      mean_ms: mean(lapTotals),
    },
    paused: { runs_with_pauses: paused.length, median_ms: median(paused) },
    series,
  };
}
