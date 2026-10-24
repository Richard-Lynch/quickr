/**
 * What the run surfaces show (timers.md §11.1, §11.5), from a run of the local view: the
 * ticking totals, the primary button, the secondary controls and the step checklist.
 *
 * Pure. Instants are epoch ms on the server's clock (`serverNow`), as the run's are.
 */
import { optimisticEntries, type LocalRun, type OptimisticEntry } from '../../lib/runs/localView';
import type { Pause, RunState, TimerStep } from '../../lib/runs/types';

/** The time inside [from, to] covered by `pauses` and the open pause (since `pausedSince`). */
function pausedWithin(
  pauses: readonly Pause[],
  pausedSince: number | null,
  from: number,
  to: number,
): number {
  const all = pausedSince === null ? pauses : [...pauses, { start: pausedSince, end: to }];
  let sum = 0;
  for (const p of all) sum += Math.max(0, Math.min(p.end, to) - Math.max(p.start, from));
  return sum;
}

/** The run's active time so far (wall time minus paused time), up to `now` or its end. */
export function activeMs(state: RunState, now: number): number {
  const end = state.ended_at ?? Math.max(now, state.started_at);
  return (
    end - state.started_at - pausedWithin(state.pauses, state.paused_since, state.started_at, end)
  );
}

/** The open segment's active time so far; 0 once the run has closed. */
export function segmentMs(state: RunState, now: number): number {
  if (!state.open) return 0;
  const from = state.open.started_at;
  const to = Math.max(now, from);
  return to - from - pausedWithin(state.pauses, state.paused_since, from, to);
}

const labelOf = (steps: readonly TimerStep[], key: string | null): string | null =>
  key === null ? null : (steps.find((s) => s.key === key)?.label ?? key);

export type PrimaryAction = { type: 'next'; label: string } | { type: 'stop'; label: 'Stop' };

/**
 * §11.1: "Next: {next step}" while a named step remains, otherwise Stop (with Lap beside
 * it). That is also the "Auto" advance.
 */
export function primaryAction(
  run: Pick<LocalRun, 'state'>,
  steps: readonly TimerStep[],
): PrimaryAction {
  const next = labelOf(steps, run.state.next_step);
  return next === null ? { type: 'stop', label: 'Stop' } : { type: 'next', label: `Next: ${next}` };
}

/**
 * The step a Skip would skip: the open step, or after a lap the next step (§4.2). Null
 * when no step is left.
 */
export function skipTarget(
  run: Pick<LocalRun, 'state'>,
  steps: readonly TimerStep[],
): { key: string; label: string } | null {
  const open = run.state.open;
  if (!open) return null;
  const key = open.kind === 'step' ? open.step : run.state.next_step;
  if (key === null) return null;
  return {
    key,
    label: open.kind === 'step' && open.step === key ? open.label : (labelOf(steps, key) ?? key),
  };
}

export type StepStatus = 'done' | 'skipped' | 'current' | 'upcoming';

export interface ChecklistRow {
  key: string;
  label: string;
  status: StepStatus;
  /** Done: the step's active time. Current: null (the panel ticks it). */
  ms: number | null;
}

/** The version's steps, in order, with their state in the run (§11.2). */
export function checklist(state: RunState, steps: readonly TimerStep[]): ChecklistRow[] {
  return steps.map((s) => {
    const seg = state.segments.find((x) => x.kind === 'step' && x.step === s.key);
    if (seg) return { key: s.key, label: seg.label, status: 'done', ms: seg.active_ms };
    if (state.skipped.includes(s.key))
      return { key: s.key, label: s.label, status: 'skipped', ms: null };
    if (state.open?.kind === 'step' && state.open.step === s.key)
      return { key: s.key, label: state.open.label, status: 'current', ms: null };
    return { key: s.key, label: s.label, status: 'upcoming', ms: null };
  });
}

/** The closed lap segments, in order, with their times. */
export function laps(state: RunState): { label: string; ms: number }[] {
  return state.segments
    .filter((s) => s.kind === 'lap')
    .map((s) => ({ label: s.label, ms: s.active_ms }));
}

/**
 * The topic's optimistic entries (queued stops and finishes that make the entry, §8.3),
 * less those the server already lists: an entry's id is its run's, so once the server's
 * entry is in, the optimistic one with that id goes.
 */
export function pendingTimedEntries(
  runs: readonly LocalRun[],
  topicId: string,
  serverIds: ReadonlySet<string>,
): OptimisticEntry[] {
  return optimisticEntries(runs).filter(
    (e) => e.topic_id === topicId && !serverIds.has(e.id.toLowerCase()),
  );
}
