/**
 * What the run surfaces show (timers.md §11.1, §11.5), from a run of the local view: the
 * ticking totals, the primary button, the secondary controls and the step checklist.
 *
 * Pure. Instants are epoch ms on the server's clock (`serverNow`), as the run's are.
 */
import type { EntryOut } from '../../client';
import type { TapExpect } from '../../lib/runs/actions';
import {
  openPauseId,
  optimisticEntries,
  type LocalRun,
  type OptimisticEntry,
} from '../../lib/runs/localView';
import type { Pause, RunState, RunStatus, Timer, TimerStep } from '../../lib/runs/types';

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

// MARK: - RunAction (timers2.md §10; active-surfaces.md §1.1–§1.2)

export type RunActionKind =
  | { type: 'start' }
  /** `label`: the step it opens ("Next: {label}"); null when the steps are unknown, a plain "Next". */
  | { type: 'next'; label: string | null }
  | { type: 'lap'; nextTypeLabel: string | null }
  | { type: 'skip'; label: string }
  | { type: 'pause' }
  | { type: 'resume' }
  | { type: 'stop' }
  | { type: 'addDetails' }
  | { type: 'reopen'; target: string }
  | { type: 'revert' }
  | { type: 'discard' };
export type RunActionRole = 'primary' | 'secondary' | 'destructive' | 'overflow';
export interface RunAction {
  kind: RunActionKind;
  role: RunActionRole;
  enabled: boolean;
  /** Stable per kind (`kind.type`): the accessibility id suffix. */
  id: string;
}

/** The headline of an open run (active-surfaces.md §1.1): its text and the compact counter. */
export interface Headline {
  text: string;
  /** "L4" while a lap is open; null until `RunState.lap_count` exists (T2-M1: F1-CORE). */
  counter: string | null;
}

const action = (kind: RunActionKind, role: RunActionRole): RunAction => ({
  kind,
  role,
  enabled: true,
  id: kind.type,
});

/**
 * The run's actions in display order: the primary first, then secondaries, then overflow,
 * destructive last (active-surfaces.md §1.1). The on-screen primary rule (timers2.md §10):
 * Lap when the open segment is a lap or no named step remains, else Next with the step it
 * opens; Stop is never primary. `timer === null` (steps unknown) is the v1 fallback: a plain
 * `next` with a null label and no `skip`, no `lap`.
 *
 * T2-M1 stub half: `lap.nextTypeLabel` is null until `RunState.next_lap_type` exists
 * (F1-CORE); `reopen`/`revert` are never returned until the reopen event lands (F1-OUTBOX);
 * row 14 (busy: every `enabled === false`) waits for a cooldown notion in `RunStatus`
 * (F1-OUTBOX). A closed run (`stopped`/`discarded`) yields `[]` today (row 13 without
 * `resumable`).
 */
// Verbatim from timers2.md §10 (A13): state + status, never a LocalRun.
export function actions(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
  now: number,
): RunAction[] {
  // eslint-disable-next-line @typescript-eslint/no-meaningless-void-operator -- reserved for v2 state (T2-M1 stub half)
  void now; // the reopen window (row 13) reads it once `Timing.terminal_id` exists
  switch (status) {
    case 'finishing':
      return [
        action({ type: 'addDetails' }, 'primary'),
        action({ type: 'discard' }, 'destructive'),
      ];
    case 'stopped':
    case 'discarded':
      return [];
    case 'running':
    case 'paused':
      break;
  }
  const steps = timer?.steps ?? null;
  const open = state.open;
  const nextLabel = labelOf(steps ?? [], state.next_step);
  const primary: RunAction =
    steps === null
      ? action({ type: 'next', label: null }, 'primary')
      : open?.kind === 'lap' || nextLabel === null
        ? action({ type: 'lap', nextTypeLabel: null }, 'primary')
        : action({ type: 'next', label: nextLabel }, 'primary');
  const out = [
    primary,
    action({ type: 'stop' }, 'secondary'),
    action({ type: status === 'paused' ? 'resume' : 'pause' }, 'secondary'),
  ];
  const skip = skipTarget({ state }, steps);
  if (skip) out.push(action({ type: 'skip', label: skip.label }, 'overflow'));
  out.push(action({ type: 'discard' }, 'destructive'));
  return out;
}

/**
 * The open segment's label with its counter. T2-M1 stub half: the bare `open.label`
 * ("Shower", "Lap 3") and no counter until `RunState.lap_count`/`next_lap_type` exist
 * (F1-CORE); "Running"/"Paused" when nothing is open.
 */
export function headline(state: RunState, status: RunStatus, timer: Timer | null): Headline {
  // eslint-disable-next-line @typescript-eslint/no-meaningless-void-operator -- reserved for v2 state (T2-M1 stub half)
  void timer; // lap types label the headline once `RunState.next_lap_type` exists
  if (state.open) return { text: state.open.label, counter: null };
  return { text: status === 'paused' ? 'Paused' : 'Running', counter: null };
}

/** The next alert's label and countdown. T2-M1 stub half: null until F1-CORE's alerts land. */
export function alertLine(state: RunState, timer: Timer | null, now: number): string | null {
  // eslint-disable-next-line @typescript-eslint/no-meaningless-void-operator -- reserved for v2 state (T2-M1 stub half)
  void [state, timer, now];
  return null;
}

/**
 * Whether the entry's run can be reopened (active-surfaces.md OQ-1: an unedited timed entry
 * of the latest stop, within 15 minutes). T2-M1 stub half: false until `Timing.terminal_id`
 * exists (F1-CORE).
 */
export function resumable(entry: EntryOut, now: number): boolean {
  // eslint-disable-next-line @typescript-eslint/no-meaningless-void-operator -- reserved for v2 state (T2-M1 stub half)
  void [entry, now];
  return false;
}

/** Convenience over `actions`: the primary, for the tile and the running bar; null when the run isn't open. */
export function primaryAction(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
  now: number,
): RunAction | null {
  if (status !== 'running' && status !== 'paused') return null;
  return actions(state, status, timer, now).find((a) => a.role === 'primary') ?? null;
}

// MARK: - v1 controls (timers.md §11.1; M2 switches the callers to `actions` and removes these)

export type PrimaryAction = { type: 'next'; label: string } | { type: 'stop'; label: 'Stop' };

/**
 * §11.1: "Next: {next step}" while a named step remains, otherwise Stop (with Lap beside
 * it). That is also the "Auto" advance. With the steps unknown (`null`) there may be a
 * step left: plain "Next", with Stop beside it.
 *
 * v1's primary, kept for `RunPanel`/`useRunPrimary` until M2 adopts `primaryAction` above
 * (renamed so the §1.1 name is free; T2-M1).
 */
export function primaryActionV1(
  run: Pick<LocalRun, 'state'>,
  steps: readonly TimerStep[] | null,
): PrimaryAction {
  if (steps === null) return { type: 'next', label: 'Next' };
  const next = labelOf(steps, run.state.next_step);
  return next === null ? { type: 'stop', label: 'Stop' } : { type: 'next', label: `Next: ${next}` };
}

/**
 * The step a Skip would skip: the open step, or after a lap the next step (§4.2). Null
 * when no step is left, or the steps aren't known (a skip must name its step).
 */
export function skipTarget(
  run: Pick<LocalRun, 'state'>,
  steps: readonly TimerStep[] | null,
): { key: string; label: string } | null {
  const open = run.state.open;
  if (!open || steps === null) return null;
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

/** The version's steps, in order, with their state in the run (§11.2); none if unknown. */
export function checklist(state: RunState, steps: readonly TimerStep[] | null): ChecklistRow[] {
  return (steps ?? []).map((s) => {
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

/** What the run's controls show now, for `tapRun`'s `expect` (a double tap goes stale). */
export function expectOf(run: LocalRun, steps: readonly TimerStep[] | null): TapExpect {
  return {
    seg: run.state.open?.index ?? null,
    step: skipTarget(run, steps)?.key ?? null,
    paused: run.status === 'paused',
    pauseId: openPauseId(run),
  };
}
