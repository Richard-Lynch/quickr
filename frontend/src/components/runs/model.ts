/**
 * What the run surfaces show (timers.md §11.1, §11.5), from a run of the local view: the
 * ticking totals, the primary button, the secondary controls and the step checklist.
 *
 * Pure. Instants are epoch ms on the server's clock (`serverNow`), as the run's are.
 */
import type { EntryOut } from '../../client';
import type { TapExpect } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { parseInstant } from '../../lib/runs/instant';
import {
  isOpen,
  openPauseId,
  optimisticEntries,
  type LocalRun,
  type OptimisticEntry,
} from '../../lib/runs/localView';
import type {
  Pause,
  RunState,
  RunStatus,
  Timer,
  TimerAlert,
  TimerStep,
} from '../../lib/runs/types';

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
  /** `label`: the step it opens ("Next: {label}"); empty when the steps are unknown, a plain "Next". */
  | { type: 'next'; label: string }
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
  /** "L4" while a lap is open (its number in the run), for compact surfaces; else null. */
  counter: string | null;
}

/**
 * OQ-1: how long after its stop a run is offered "Resume run" on tiles, toasts and the run
 * screen (timers2.md glossary, "Resumable"). iOS: `RunPresentation.reopenWindowMs`.
 */
export const REOPEN_WINDOW_MS = 15 * 60 * 1000;

const action = (kind: RunActionKind, role: RunActionRole): RunAction => ({
  kind,
  role,
  enabled: true,
  id: kind.type,
});

/**
 * The run's actions in display order: the primary first, then secondaries, then overflow,
 * destructive last (active-surfaces.md §1.1, §1.2). The on-screen primary rule (timers2.md
 * §10): Lap when the open segment is a lap or no named step remains, labelled with the lap it
 * opens when the timer has lap types (`next_lap_type`: "Lap → Rest"), else Next with the step
 * it opens; Stop is never primary. `timer === null` (steps unknown) is the v1 fallback:
 * `next` with an empty label, which §1.3 renders as a plain "Next", and no `skip`, no `lap`.
 *
 * - An open run reached by a reopen (`state.reopen_id`) offers `revert` instead of `discard`
 *   (row 10).
 * - A closed run (`stopped`/`discarded`) is idle (rows 1–3): `start` (primary). A stopped run
 *   with a `terminal_id` also offers `reopen` (secondary) within `REOPEN_WINDOW_MS` of its
 *   stop (row 13); the store-level rules (unedited, latest stop, no other open run) are
 *   `resumable`'s and the surface's. A topic with no run doesn't call this.
 * - A finishing run: `addDetails`, `discard` (row 12).
 *
 * Not expressible here: rows 11 (a queued reopen's "resuming" run shows no controls) and 14
 * (busy: every `enabled === false`); the surface applies both. iOS:
 * `RunPresentation.actions(_:status:timer:now:)`.
 */
// Verbatim from timers2.md §10 (A13): state + status, never a LocalRun.
export function actions(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
  now: number,
): RunAction[] {
  switch (status) {
    case 'finishing':
      return [
        action({ type: 'addDetails' }, 'primary'),
        action({ type: 'discard' }, 'destructive'),
      ];
    case 'stopped':
    case 'discarded': {
      const out = [action({ type: 'start' }, 'primary')];
      const end = state.ended_at;
      if (
        status === 'stopped' &&
        state.terminal_id !== null &&
        end !== null &&
        now - end <= REOPEN_WINDOW_MS
      )
        out.push(action({ type: 'reopen', target: state.terminal_id }, 'secondary'));
      return out;
    }
    case 'running':
    case 'paused':
      break;
  }
  const steps = timer?.steps ?? null;
  const open = state.open;
  const nextLabel = labelOf(steps ?? [], state.next_step);
  const primary: RunAction =
    steps === null
      ? action({ type: 'next', label: '' }, 'primary')
      : open?.kind === 'lap' || nextLabel === null
        ? action({ type: 'lap', nextTypeLabel: nextTypeLabel(state, timer) }, 'primary')
        : action({ type: 'next', label: nextLabel }, 'primary');
  const out = [
    primary,
    action({ type: 'stop' }, 'secondary'),
    action({ type: status === 'paused' ? 'resume' : 'pause' }, 'secondary'),
  ];
  const skip = skipTarget({ state }, steps);
  if (skip) out.push(action({ type: 'skip', label: skip.label }, 'overflow'));
  out.push(action({ type: state.reopen_id != null ? 'revert' : 'discard' }, 'destructive'));
  return out;
}

/** The label of the lap type a `lap` tap would open now; null when laps are untyped. */
function nextTypeLabel(state: RunState, timer: Timer | null): string | null {
  const key = state.next_lap_type;
  if (key === null) return null;
  return timer?.laps?.find((l) => l.key === key)?.label ?? null;
}

/**
 * The open segment's label with its counter (active-surfaces.md §1.1):
 *
 * - a typed lap: "{label} · lap {n}" ("Rest 2 · lap 4"), counter "L{n}", where n is the lap's
 *   number in the run (`lap_count + 1`);
 * - an untyped lap: its label ("Lap 3"), counter "L3";
 * - a step: "{label} · {position} of {count}" over the timer's steps ("Shower · 2 of 5"), no
 *   counter; the bare label when the timer isn't known or lacks the step;
 * - nothing open: "Running", or "Paused" while `status` is paused.
 *
 * iOS: `RunPresentation.headline(_:status:timer:)`.
 */
export function headline(state: RunState, status: RunStatus, timer: Timer | null): Headline {
  const open = state.open;
  if (!open) return { text: status === 'paused' ? 'Paused' : 'Running', counter: null };
  if (open.kind === 'lap') {
    const n = state.lap_count + 1;
    const text = open.lap_type !== null ? `${open.label} · lap ${String(n)}` : open.label;
    return { text, counter: `L${String(n)}` };
  }
  const steps = timer?.steps;
  const index = steps?.findIndex((x) => x.key === open.step) ?? -1;
  if (!steps || index < 0) return { text: open.label, counter: null };
  return { text: `${open.label} · ${String(index + 1)} of ${String(steps.length)}`, counter: null };
}

/** The alerts of the open segment's step or lap type (an untyped lap has none). */
function openAlerts(state: RunState, timer: Timer): readonly TimerAlert[] {
  const open = state.open;
  if (!open) return [];
  if (open.kind === 'step') return timer.steps.find((x) => x.key === open.step)?.alerts ?? [];
  if (open.lap_type === null) return [];
  return timer.laps?.find((l) => l.key === open.lap_type)?.alerts ?? [];
}

/**
 * The next alert of the open segment and its countdown: "Half way · in 0:12"
 * (active-surfaces.md §1.1). The alerts are the open step's or lap type's (timers2.md §1.1),
 * in `at_ms` order then position; the next is the first whose `at_ms` is beyond the segment's
 * active time now (paused time doesn't count). Null while paused, when nothing is open, when
 * the timer isn't known, or when none remain. The countdown is `fmtDuration` (truncated).
 * iOS: `RunPresentation.alertLine(_:timer:now:)`.
 */
export function alertLine(state: RunState, timer: Timer | null, now: number): string | null {
  if (!state.open || state.paused_since !== null || !timer) return null;
  const active = segmentMs(state, now);
  let next: { at: number; label: string } | null = null;
  for (const alert of openAlerts(state, timer)) {
    const at = alert.at_ms;
    if (at === undefined || at <= active) continue;
    if (next === null || at < next.at) next = { at, label: alert.label };
  }
  return next === null ? null : `${next.label} · in ${fmtDuration(next.at - active)}`;
}

/**
 * OQ-1: from the entry detail, a run can be reopened within 7 days of its start (timers2.md
 * glossary, "Resumable"; content-display.md §3.2). iOS: `RunPresentation.entryReopenWindowMs`.
 */
export const ENTRY_REOPEN_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/** The entry's timing instants and edited flag, or null for an untimed entry. */
function timingOf(entry: Pick<EntryOut, 'timing'>): {
  started_at: number;
  ended_at: number;
  edited: boolean;
} | null {
  const t = entry.timing;
  if (!t) return null;
  return {
    started_at: parseInstant(t.started_at),
    ended_at: parseInstant(t.ended_at),
    edited: t.edited,
  };
}

/**
 * The entry's half of "resumable" (timers2.md glossary, OQ-1) on tiles, toasts and the run
 * screen: a timed entry whose times are unedited (`timing.edited === false`, i.e.
 * `run.edited === false`; answers, notes and meta changes don't count), within
 * `REOPEN_WINDOW_MS` of its stop. A pre-v2 timing (no `terminal_id`) qualifies: its Resume
 * sends `target: null` (A12). The view's half (the topic's latest stop, no locally open run:
 * A15) is `resumableInView`, which surfaces call; the entry alone can't tell.
 * iOS: `RunPresentation.resumable(_:now:)`.
 */
export function resumable(entry: Pick<EntryOut, 'timing'>, now: number): boolean {
  const t = timingOf(entry);
  if (!t || t.edited) return false;
  return now - t.ended_at <= REOPEN_WINDOW_MS;
}

/**
 * `resumable` from the entry detail (OQ-1, content-display.md §3.2): unedited, within
 * `ENTRY_REOPEN_WINDOW_MS` of the run's start. The detail hides Resume while the topic has a
 * locally open or finishing run (A15) and while the entry is pending; that is the page's.
 * iOS: `RunPresentation.resumableFromDetail(_:now:)`.
 */
export function resumableFromDetail(entry: Pick<EntryOut, 'timing'>, now: number): boolean {
  const t = timingOf(entry);
  if (!t || t.edited) return false;
  return now - t.started_at <= ENTRY_REOPEN_WINDOW_MS;
}

/**
 * Whether the entry's run is offered "Resume run" on tiles, toasts and the run screen
 * (timers2.md glossary, OQ-1, A15): `resumable` (an unedited timed entry within 15 minutes of
 * its stop), the entry is the topic's latest stop (no later timed entry in `entries`, and no
 * later stop of a run in the view: a finishing run has no entry yet), and the topic has no
 * locally open run (a reopen would be refused with 409 `conflict`), the entry's own run
 * included (already reopened here). A later stop on the same instant is broken by id, as
 * iOS does; ids compare case-insensitively. `entries` are the ones this device has for the topic (others are ignored).
 * iOS: `RunOverlay.resumable(_:entryId:now:)`.
 */
export function resumableInView(
  entry: Pick<EntryOut, 'id' | 'topic_id' | 'timing'>,
  entries: readonly Pick<EntryOut, 'id' | 'topic_id' | 'timing'>[],
  runs: readonly LocalRun[],
  now: number,
): boolean {
  const end = timingOf(entry)?.ended_at;
  if (end === undefined || !resumable(entry, now)) return false;
  const id = entry.id.toLowerCase();
  const topicId = entry.topic_id.toLowerCase();
  const topicRuns = runs.filter((r) => r.topic_id.toLowerCase() === topicId);
  const answers = (r: LocalRun) => r.id === id || r.aliases.includes(id);
  if (topicRuns.some((r) => isOpen(r) || (answers(r) && r.status === 'finishing'))) return false;
  const later = (otherId: string, otherEnd: number) =>
    otherEnd > end || (otherEnd === end && otherId.toLowerCase() > id);
  if (
    topicRuns.some(
      (r) =>
        !answers(r) &&
        r.status !== 'discarded' &&
        r.state.ended_at !== null &&
        later(r.id, r.state.ended_at),
    )
  )
    return false;
  return !entries.some((e) => {
    if (e.topic_id.toLowerCase() !== topicId || e.id.toLowerCase() === id) return false;
    const otherEnd = timingOf(e)?.ended_at;
    return otherEnd !== undefined && later(e.id, otherEnd);
  });
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
