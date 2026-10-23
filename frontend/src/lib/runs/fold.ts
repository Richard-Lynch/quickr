/**
 * The run fold: a run's events in, its state and timing out (timers.md §4, §2.3).
 *
 * A port of backend/app/services/run_fold.py, the reference. `shared/fixtures/
 * run-fold-vectors.json` is the contract the server, the PWA and the iOS app all check.
 * Every instant is an integer count of epoch milliseconds (`instant.ts`), so durations
 * are exact integer differences and segment sums equal the totals exactly.
 *
 * - {@link fold} replays a run's events (in arrival order) into a {@link RunState}:
 *   terminal events by arrival, everything else by `(at, id)`, except that a resume at the
 *   same instant as the pause it names comes right after it (§4.1, §4.2).
 * - {@link projectTiming} turns a stopped run's state into the entry's {@link Timing}.
 *
 * Decided outside the fold, by the server (§3.6, §3.7, §4.4): `finish` (no effect here),
 * the discard of a finishing run, `finishing` versus `stopped` (the fold says `stopped`),
 * and the `frozen` cut-off after which arrivals are void and not folded.
 */
import { formatInstant, parseInstant } from './instant';
import type {
  Effect,
  FoldStatus,
  Frozen,
  OpenSegment,
  Pause,
  PauseWire,
  RunEvent,
  RunEventWire,
  RunState,
  RunStateWire,
  Segment,
  SegmentWire,
  Timing,
  TimingWire,
  TimerStep,
  VoidReason,
} from './types';
import { RUN_EVENT_TYPES } from './types';

/** §5: a run lasts at most 7 days from its start. */
export const MAX_RUN_MS = 7 * 24 * 60 * 60 * 1000;

const APPLIED: Effect = { effect: 'applied', reason: null };
const effectOf = (reason: VoidReason | null): Effect =>
  reason === null ? APPLIED : { effect: 'void', reason };

/** The label of the run's `n`-th lap segment (1-based). */
export function lapLabel(n: number): string {
  return `Lap ${n}`;
}

/**
 * Replay `events` (in arrival order) of run `runId` over its version's `steps`.
 *
 * The run's own start (the event whose id is `runId`) must be among them. A stop before
 * the start or more than 7 days after it is void (`before_start`, `too_long`) and doesn't
 * close the run.
 */
export function fold(
  runId: string,
  steps: readonly TimerStep[],
  events: readonly RunEvent[],
  frozen: Frozen | null = null,
): RunState {
  const id = runId.toLowerCase();
  const start = events.find((e) => e.id.toLowerCase() === id && e.type === 'start');
  if (!start) throw new Error("the run's start event is missing");
  const effects: Record<string, Effect> = {};
  const { terminal, accepted } = arrivalPass(id, start, events, frozen, effects);

  const clock = new Clock(steps, start.at);
  const end = terminal ? terminal.at : null;
  for (const e of [...accepted].sort(timeOrder(accepted))) {
    let reason: VoidReason | null;
    if (e.at < start.at) reason = 'before_start';
    else if (end !== null && e.at > end) reason = 'after_stop';
    else if (e.at > start.at + MAX_RUN_MS) reason = 'too_long';
    else reason = clock.apply(e);
    effects[e.id.toLowerCase()] = effectOf(reason);
  }
  return clock.state(start.at, terminal, effects);
}

type SortKey = [number, string, number, string];

const cmp = <T extends number | string>(x: T, y: T): number => (x < y ? -1 : x > y ? 1 : 0);

const compareKeys = ([a0, a1, a2, a3]: SortKey, [b0, b1, b2, b3]: SortKey): number =>
  cmp(a0, b0) || cmp(a1, b1) || cmp(a2, b2) || cmp(a3, b3);

/**
 * Pass 2's order: `(at, id)` ascending, ids lowercase, except that a resume at the same
 * instant as the pause it names comes right after that pause.
 */
function timeOrder(accepted: readonly RunEvent[]): (a: RunEvent, b: RunEvent) => number {
  const pauses = new Map<string, number>();
  for (const e of accepted) if (e.type === 'pause') pauses.set(e.id.toLowerCase(), e.at);
  const key = (e: RunEvent): SortKey => {
    const named = (e.pause_id ?? '').toLowerCase();
    if (e.type === 'resume' && pauses.get(named) === e.at)
      return [e.at, named, 1, e.id.toLowerCase()];
    return [e.at, e.id.toLowerCase(), 0, ''];
  };
  return (a, b) => compareKeys(key(a), key(b));
}

/**
 * Pass 1, arrival order (§4.2): duplicates, starts, terminals and the frozen cut-off.
 * Records their effects; returns the terminal and the events left for pass 2.
 */
function arrivalPass(
  runId: string,
  start: RunEvent,
  events: readonly RunEvent[],
  frozen: Frozen | null,
  effects: Record<string, Effect>,
): { terminal: RunEvent | null; accepted: RunEvent[] } {
  const seen = new Set<string>();
  let terminal: RunEvent | null = null;
  const accepted: RunEvent[] = [];
  events.forEach((e, i) => {
    if (!RUN_EVENT_TYPES.includes(e.type))
      throw new Error(`unknown event type ${JSON.stringify(e.type)}`);
    const eid = e.id.toLowerCase();
    if (seen.has(eid)) return;
    seen.add(eid);
    if (e.type === 'finish') return;
    let reason: VoidReason | null = null;
    if (frozen !== null && i >= frozen.after) reason = frozen.reason;
    else if (e.type === 'start') reason = eid === runId ? null : 'merged';
    else if (e.type === 'stop' || e.type === 'discard') {
      // An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
      if (e.type === 'stop' && e.at < start.at) reason = 'before_start';
      else if (e.type === 'stop' && e.at > start.at + MAX_RUN_MS) reason = 'too_long';
      else if (terminal !== null) reason = 'already_closed';
      else terminal = e;
    } else {
      accepted.push(e);
      return;
    }
    effects[eid] = effectOf(reason);
  });
  return { terminal, accepted };
}

/** A closed segment before labelling: its step (null for a lap) and bounds. */
type Closed = [step: TimerStep | null, startedAt: number, endedAt: number];

/** Pass 2's state: the open segment, the steps still to come, and what has closed. */
class Clock {
  private readonly pending: TimerStep[];
  private openStep: TimerStep | null; // null: a lap
  private openStart: number;
  private readonly closed: Closed[] = [];
  private readonly skipped: string[] = [];
  private readonly pauses: Pause[] = [];
  private pausedSince: number | null = null;
  private pauseId: string | null = null;

  constructor(steps: readonly TimerStep[], startedAt: number) {
    this.pending = [...steps];
    this.openStep = this.pop();
    this.openStart = startedAt;
  }

  /** The next step, or a lap once the steps run out. */
  private pop(): TimerStep | null {
    return this.pending.shift() ?? null;
  }

  private close(at: number, then: TimerStep | null): void {
    this.closed.push([this.openStep, this.openStart, at]);
    this.openStep = then;
    this.openStart = at;
  }

  /** Apply one in-range event; its void reason, or null when it applied. */
  apply(e: RunEvent): VoidReason | null {
    if (
      (e.type === 'next' || e.type === 'lap' || e.type === 'skip') &&
      e.seg !== this.closed.length
    )
      return 'stale';
    switch (e.type) {
      case 'next':
        this.close(e.at, this.pop());
        return null;
      case 'lap':
        this.close(e.at, null);
        return null;
      case 'skip':
        return this.skip(e.step);
      case 'pause':
        if (this.pausedSince !== null) return 'already_paused';
        this.pausedSince = e.at;
        this.pauseId = e.id.toLowerCase();
        return null;
      case 'resume':
        if (this.pausedSince === null) return 'not_paused';
        if ((e.pause_id ?? '').toLowerCase() !== this.pauseId) return 'stale'; // it ends an older pause
        this.pauses.push({ start: this.pausedSince, end: e.at });
        this.pausedSince = null;
        this.pauseId = null;
        return null;
      default: // start, stop, discard and finish never reach pass 2
        throw new Error(`unexpected ${e.type} in pass 2`);
    }
  }

  private skip(step: string | null): VoidReason | null {
    if (this.openStep !== null) {
      if (step !== this.openStep.key) return 'stale';
      this.skipped.push(this.openStep.key);
      this.openStep = this.pop(); // relabel the open segment: no time moves
      return null;
    }
    const head = this.pending[0];
    if (head === undefined) return 'no_step';
    if (step !== head.key) return 'stale';
    this.skipped.push(head.key);
    this.pending.shift();
    return null;
  }

  state(startedAt: number, terminal: RunEvent | null, effects: Record<string, Effect>): RunState {
    let status: FoldStatus;
    let endedAt: number | null = null;
    if (terminal !== null && terminal.type === 'stop') {
      if (this.pausedSince !== null) {
        // Stop while paused ends the pause.
        this.pauses.push({ start: this.pausedSince, end: terminal.at });
        this.pausedSince = null;
      }
      this.close(terminal.at, null);
      status = 'stopped';
      endedAt = terminal.at;
    } else if (terminal !== null) {
      status = 'discarded';
      this.pausedSince = null;
    } else {
      status = this.pausedSince !== null ? 'paused' : 'running';
    }

    const segments = toSegments(this.closed, this.pauses, this.pausedSince);
    let open: OpenSegment | null = null;
    if (status === 'running' || status === 'paused') {
      const laps = segments.filter((s) => s.kind === 'lap').length;
      const step = this.openStep;
      open = {
        index: this.closed.length,
        kind: step === null ? 'lap' : 'step',
        step: step === null ? null : step.key,
        label: step === null ? lapLabel(laps + 1) : step.label,
        started_at: this.openStart,
      };
    }
    return {
      status,
      started_at: startedAt,
      ended_at: endedAt,
      open,
      next_step: open !== null ? (this.pending[0]?.key ?? null) : null,
      paused_since: this.pausedSince,
      segments,
      skipped: [...this.skipped],
      pauses: [...this.pauses],
      effects: { ...effects },
    };
  }
}

/**
 * How much of `[start, end)` the pauses cover. `openPause` is the start of a pause not
 * resumed yet, which covers up to `end` (measured to `end`: no "not resumed" sentinel).
 */
function overlap(
  start: number,
  end: number,
  pauses: readonly Pause[],
  openPause: number | null = null,
): number {
  let paused = 0;
  for (const p of pauses) paused += Math.max(0, Math.min(end, p.end) - Math.max(start, p.start));
  return openPause === null ? paused : paused + Math.max(0, end - Math.max(start, openPause));
}

/**
 * Closed segments with their labels. Pauses stay whole; each segment's paused_ms is its
 * overlap with them (T5).
 */
function toSegments(
  closed: readonly Closed[],
  pauses: readonly Pause[],
  openPause: number | null,
): Segment[] {
  let laps = 0;
  return closed.map(([step, startedAt, endedAt]) => {
    if (step === null) laps += 1;
    const paused = overlap(startedAt, endedAt, pauses, openPause);
    return {
      kind: step === null ? 'lap' : 'step',
      step: step === null ? null : step.key,
      label: step === null ? lapLabel(laps) : step.label,
      started_at: startedAt,
      ended_at: endedAt,
      active_ms: endedAt - startedAt - paused,
      paused_ms: paused,
    };
  });
}

// --- timing ------------------------------------------------------------------------------

/**
 * §9.1: the version has no steps, or every one of its steps has a segment and none was
 * skipped. A run stopped before it reached its last step is not complete.
 */
export function isComplete(
  steps: readonly TimerStep[],
  segments: readonly Segment[],
  skipped: readonly string[],
): boolean {
  const done = new Set(segments.map((s) => s.step));
  return skipped.length === 0 && steps.every((step) => done.has(step.key));
}

/**
 * A stopped run's `Timing`: exactly its fold state (§4.3). `steps` are the run version's
 * steps, the ones it was folded over.
 */
export function projectTiming(state: RunState, steps: readonly TimerStep[]): Timing {
  if (state.status !== 'stopped' || state.ended_at === null)
    throw new Error('only a stopped run has a timing');
  const paused = state.pauses.reduce((sum, p) => sum + p.end - p.start, 0);
  return {
    started_at: state.started_at,
    ended_at: state.ended_at,
    active_ms: state.ended_at - state.started_at - paused,
    paused_ms: paused,
    complete: isComplete(steps, state.segments, state.skipped),
    edited: false,
    segments: state.segments,
    skipped: state.skipped,
    pauses: state.pauses,
  };
}

// --- wire --------------------------------------------------------------------------------

export function eventFromWire(e: RunEventWire): RunEvent {
  return { ...e, at: parseInstant(e.at) };
}

const segmentToWire = (s: Segment): SegmentWire => ({
  ...s,
  started_at: formatInstant(s.started_at),
  ended_at: formatInstant(s.ended_at),
});
const segmentFromWire = (s: SegmentWire): Segment => ({
  ...s,
  started_at: parseInstant(s.started_at),
  ended_at: parseInstant(s.ended_at),
});
const pauseToWire = (p: Pause): PauseWire => ({
  start: formatInstant(p.start),
  end: formatInstant(p.end),
});
const pauseFromWire = (p: PauseWire): Pause => ({
  start: parseInstant(p.start),
  end: parseInstant(p.end),
});

/** `RunState` as the API carries it (§4.3). */
export function stateToWire(state: RunState): RunStateWire {
  return {
    ...state,
    started_at: formatInstant(state.started_at),
    ended_at: state.ended_at === null ? null : formatInstant(state.ended_at),
    open:
      state.open === null
        ? null
        : { ...state.open, started_at: formatInstant(state.open.started_at) },
    paused_since: state.paused_since === null ? null : formatInstant(state.paused_since),
    segments: state.segments.map(segmentToWire),
    pauses: state.pauses.map(pauseToWire),
  };
}

export function timingToWire(t: Timing): TimingWire {
  return {
    ...t,
    started_at: formatInstant(t.started_at),
    ended_at: formatInstant(t.ended_at),
    segments: t.segments.map(segmentToWire),
    pauses: t.pauses.map(pauseToWire),
  };
}

export function timingFromWire(t: TimingWire): Timing {
  return {
    ...t,
    started_at: parseInstant(t.started_at),
    ended_at: parseInstant(t.ended_at),
    segments: t.segments.map(segmentFromWire),
    pauses: t.pauses.map(pauseFromWire),
  };
}
