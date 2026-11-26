/**
 * The run fold: a run's events in, its state and timing out (timers.md §4, §2.3, as changed
 * by timers2.md §3: fold v4).
 *
 * A port of backend/app/services/run_fold.py, the reference. `shared/fixtures/
 * run-fold-vectors.json` is the contract the server, the PWA and the iOS app all check.
 * Every instant is an integer count of epoch milliseconds (`instant.ts`), so durations
 * are exact integer differences and segment sums equal the totals exactly. No `Date`.
 *
 * - {@link fold} replays a run's events (in arrival order) over its version's timer (steps
 *   and lap types) into a {@link RunState}. Pass 1, by arrival: terminals, reopens (and
 *   their revert by a discard) and removes. Pass 2, by `(at, rank, id)`: every other tap,
 *   with each reopened stop as a gap pause and each reopen as a gap resume (timers2.md
 *   §3.4); a resume at the same instant as the pause it names comes right after it.
 *   Effects are outputs of one fold only: nothing is retained between folds.
 * - {@link projectTiming} turns a stopped run's state into the entry's {@link Timing}.
 *
 * Decided outside the fold, by the server (§3.6, §3.7, §4.4; timers2.md §3.6): `finish`
 * (no effect here), the discard of a finishing run, `finishing` versus `stopped` (the fold
 * says `stopped`), and the `frozen` cut-off after which arrivals are void and not folded.
 */
import { formatInstant, parseInstant } from './instant';
import type {
  Effect,
  FoldStatus,
  FoldTimer,
  Frozen,
  LapType,
  OpenSegment,
  OpenedBy,
  Pause,
  PauseWire,
  RunEvent,
  RunEventWire,
  RunState,
  RunStateWire,
  Segment,
  SegmentWire,
  StoredPauseWire,
  StoredSegmentWire,
  StoredTimingWire,
  Timing,
  TimingWire,
  TimerStep,
  VoidReason,
} from './types';
import { RUN_EVENT_TYPES } from './types';

/** §5: a run lasts at most 7 days from its start. */
export const MAX_RUN_MS = 7 * 24 * 60 * 60 * 1000;

const APPLIED: Effect = Object.freeze({ effect: 'applied', reason: null });
const effectOf = (reason: VoidReason | null): Effect =>
  reason === null ? APPLIED : { effect: 'void', reason };

const lc = (id: string): string => id.toLowerCase();

/**
 * The lap type key and label of the run's `n`-th lap segment (1-based): laps cycle through
 * the lap types in order with a per-type ordinal ("Run 1, Rest 1, Run 2"); with no lap
 * types, `[null, "Lap n"]` (timers2.md §3.2).
 */
export function lapTyping(
  n: number,
  laps: readonly LapType[] = [],
): [lapType: string | null, label: string] {
  const count = laps.length;
  const type = count ? laps[(n - 1) % count] : undefined;
  if (type === undefined) return [null, `Lap ${n}`];
  return [type.key, `${type.label} ${Math.floor((n - 1) / count) + 1}`];
}

/** The label of the run's `n`-th lap segment (1-based). */
export function lapLabel(n: number, laps: readonly LapType[] = []): string {
  return lapTyping(n, laps)[1];
}

/**
 * Replay `events` (in arrival order) of run `runId` over its version's `timer` (its steps
 * and lap types; variables and alerts are not fold inputs, timers2.md §3.1).
 *
 * The run's own start (the event whose id is `runId`) must be among them. A stop before
 * the start or more than 7 days after it is void (`before_start`, `too_long`) and doesn't
 * close the run.
 */
export function fold(
  runId: string,
  timer: FoldTimer,
  events: readonly RunEvent[],
  frozen: Frozen | null = null,
): RunState {
  const id = lc(runId);
  const start = events.find((e) => lc(e.id) === id && e.type === 'start');
  if (!start) throw new Error("the run's start event is missing");
  const effects: Record<string, Effect> = {};
  const arrival = new Arrival(start, effects);
  arrival.pass(id, events, frozen);
  const terminal = arrival.terminal;

  const clock = new Clock(timer, start.at, arrival.removed);
  const end = terminal ? terminal.at : null;
  const items: (RunEvent | Role)[] = [...arrival.accepted, ...arrival.gaps()];
  for (const item of items.sort(timeOrder(arrival.accepted))) {
    if (isRole(item)) {
      // Never recorded; skipped outside the run.
      if (item.at >= start.at && (end === null || item.at <= end)) clock.role(item);
      continue;
    }
    let reason: VoidReason | null;
    if (item.at < start.at) reason = 'before_start';
    else if (end !== null && item.at > end) reason = 'after_stop';
    else if (item.at > start.at + MAX_RUN_MS) reason = 'too_long';
    else reason = clock.apply(item);
    effects[lc(item.id)] = effectOf(reason);
  }
  return clock.state(start.at, terminal, effects);
}

/**
 * A reopened stop's gap pause (id = the stop's) or a reopen's gap resume (id = the
 * reopen's) in pass 2 (timers2.md §3.4). Ids are lowercase.
 */
export interface Role {
  role: 'gap_pause' | 'gap_resume';
  at: number;
  id: string;
}

const isRole = (x: RunEvent | Role): x is Role => 'role' in x;

type SortKey = [number, number, string, number, string];

const cmp = <T extends number | string>(x: T, y: T): number => (x < y ? -1 : x > y ? 1 : 0);

const compareKeys = (a: SortKey, b: SortKey): number =>
  cmp(a[0], b[0]) || cmp(a[1], b[1]) || cmp(a[2], b[2]) || cmp(a[3], b[3]) || cmp(a[4], b[4]);

/**
 * Pass 2's order `(at, rank, id)` ascending, ids lowercase: at equal `at` a gap pause
 * (rank 0) comes before every user event (rank 1) and a gap resume (rank 2) after them;
 * among user events a resume at the same instant as the pause it names comes right after
 * that pause (several such resumes by id).
 */
export function timeOrder(
  accepted: readonly RunEvent[],
): (a: RunEvent | Role, b: RunEvent | Role) => number {
  const pauses = new Map<string, number>();
  for (const e of accepted) if (e.type === 'pause') pauses.set(lc(e.id), e.at);
  const key = (x: RunEvent | Role): SortKey => {
    if (isRole(x)) return [x.at, x.role === 'gap_pause' ? 0 : 2, x.id, 0, ''];
    const named = lc(x.pause_id ?? '');
    if (x.type === 'resume' && pauses.get(named) === x.at) return [x.at, 1, named, 1, lc(x.id)];
    return [x.at, 1, lc(x.id), 0, ''];
  };
  return (a, b) => compareKeys(key(a), key(b));
}

/** An applied (stop, reopen) pair: the stop's gap pause and the reopen's gap resume. */
type RolePair = readonly [stop: RunEvent, reopen: RunEvent];

/**
 * Pass 1, arrival order (§4.2, timers2.md §3.4): duplicates, starts, the frozen cut-off,
 * terminals, reopens (and their revert by a discard) and removes. Records their effects;
 * leaves the terminal, the events for pass 2, the role pairs and the removed targets.
 */
class Arrival {
  /** The first occurrence of each (lowercase) id. */
  private readonly seen = new Map<string, RunEvent>();
  terminal: RunEvent | null = null;
  readonly accepted: RunEvent[] = [];
  /** The pair whose reopen cleared the CURRENT terminal. */
  private openReopen: RolePair | null = null;
  private readonly roles: RolePair[] = [];
  /** Target id (lowercase) → the remove that applied. */
  readonly removed = new Map<string, RunEvent>();
  private readonly start: RunEvent;
  private readonly effects: Record<string, Effect>;

  constructor(start: RunEvent, effects: Record<string, Effect>) {
    this.start = start;
    this.effects = effects;
  }

  pass(runId: string, events: readonly RunEvent[], frozen: Frozen | null): void {
    events.forEach((e, i) => {
      if (!RUN_EVENT_TYPES.includes(e.type))
        throw new Error(`unknown event type ${JSON.stringify(e.type)}`);
      const eid = lc(e.id);
      if (this.seen.has(eid)) return;
      this.seen.set(eid, e);
      if (e.type === 'finish') return;
      let reason: VoidReason | null;
      if (frozen !== null && i >= frozen.after) reason = frozen.reason;
      else if (e.type === 'start') reason = eid === runId ? null : 'merged';
      else if (e.type === 'stop') reason = this.stop(e);
      else if (e.type === 'discard') reason = this.discard(e);
      else if (e.type === 'reopen') reason = this.reopen(e);
      else if (e.type === 'remove') reason = this.remove(e);
      else {
        this.accepted.push(e); // next, lap, skip, pause, resume
        return;
      }
      this.effects[eid] = effectOf(reason);
    });
  }

  /** Pass 2's roles: gap pauses of pairs whose stop isn't removed, and every gap resume. */
  gaps(): Role[] {
    return [
      ...this.roles
        .filter(([s]) => !this.removed.has(lc(s.id)))
        .map(([s]): Role => ({ role: 'gap_pause', at: s.at, id: lc(s.id) })),
      ...this.roles.map(([, r]): Role => ({ role: 'gap_resume', at: r.at, id: lc(r.id) })),
    ];
  }

  private stop(e: RunEvent): VoidReason | null {
    // An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
    if (e.at < this.start.at) return 'before_start';
    if (e.at > this.start.at + MAX_RUN_MS) return 'too_long';
    if (this.terminal !== null) return 'already_closed';
    this.terminal = e;
    this.openReopen = null; // a new terminal ends the reopen transaction
    return null;
  }

  private discard(e: RunEvent): VoidReason | null {
    if (this.terminal !== null) return 'already_closed';
    const pair = this.openReopen;
    if (pair === null) {
      this.terminal = e;
      return null;
    }
    // The terminal was cleared by a reopen: revert it (OQ-2).
    const [stop, reopen] = pair;
    this.openReopen = null;
    this.effects[lc(reopen.id)] = effectOf('reverted');
    this.terminal = stop;
    this.roles.splice(this.roles.indexOf(pair), 1);
    const removal = this.removed.get(lc(stop.id));
    if (removal !== undefined) {
      // The gap pause had been removed: the stop is a terminal again.
      this.effects[lc(stop.id)] = APPLIED;
      this.effects[lc(removal.id)] = effectOf('no_target');
      this.removed.delete(lc(stop.id));
    }
    return null; // the discard closed what the reopen opened
  }

  private reopen(e: RunEvent): VoidReason | null {
    const target = lc(e.target ?? '');
    const t = this.seen.get(target);
    if (t?.type !== 'stop') return 'no_target';
    if (this.terminal !== null && this.terminal.type === 'discard') return 'already_closed';
    if (this.terminal === null || lc(this.terminal.id) !== target) return 'not_stopped';
    if (e.at <= t.at) return 'stale';
    if (e.at > this.start.at + MAX_RUN_MS) return 'too_long';
    const pair: RolePair = [t, e];
    this.openReopen = pair;
    this.roles.push(pair);
    this.terminal = null;
    return null;
  }

  /**
   * Eligibility is by type and identity only: a pause, a lap, or a reopened stop, not yet
   * removed, with `e.at` after it. There is no 7-day bound.
   */
  private remove(e: RunEvent): VoidReason | null {
    const target = lc(e.target ?? '');
    const t = this.seen.get(target);
    if (t === undefined || this.removed.has(target) || e.at <= t.at) return 'no_target';
    if (t.type === 'stop') {
      if (!this.roles.some(([s]) => lc(s.id) === target)) return 'no_target';
      this.effects[target] = effectOf('deleted'); // the gap pause goes; its reopen stays applied
    } else if (t.type !== 'pause' && t.type !== 'lap') return 'no_target';
    this.removed.set(target, e);
    return null;
  }
}

/** A closed segment before labelling: its step (null for a lap), bounds and opener. */
interface Closed {
  step: TimerStep | null;
  started_at: number;
  ended_at: number;
  event_id: string | null;
  opened_by: OpenedBy | null;
}

type Opener = [eventId: string | null, openedBy: OpenedBy | null];

/**
 * Pass 2's state: the open segment, the steps still to come, what has closed, the open
 * pause and its owner, and the ghost boundaries of removed laps.
 */
class Clock {
  private readonly pending: TimerStep[];
  private openStep: TimerStep | null; // null: a lap
  private openStart: number;
  private openEvent: Opener = [null, 'start'];
  private readonly closed: Closed[] = [];
  private readonly skipped: string[] = [];
  private readonly pauses: Pause[] = [];
  private pausedSince: number | null = null;
  private pauseId: string | null = null;
  /** `[lap.at, remove.at]` of removed lap boundaries (timers2.md §3.5). */
  private readonly ghosts: [number, number][] = [];
  private readonly laps: readonly LapType[];
  /** Target id (lowercase) → the remove that applied (pass 1's). */
  private readonly removed: ReadonlyMap<string, RunEvent>;

  constructor(timer: FoldTimer, startedAt: number, removed: ReadonlyMap<string, RunEvent>) {
    this.removed = removed;
    this.pending = [...timer.steps];
    this.laps = timer.laps ?? [];
    this.openStep = this.pop();
    this.openStart = startedAt;
  }

  /** The next step, or a lap once the steps run out. */
  private pop(): TimerStep | null {
    return this.pending.shift() ?? null;
  }

  /**
   * §3.5: the closed segments plus the removed boundaries a device tapping at `at` still
   * saw (removed later than `at`).
   */
  private expectedSeg(at: number): number {
    let n = this.closed.length;
    for (const [lapAt, removedAt] of this.ghosts) if (lapAt < at && at < removedAt) n += 1;
    return n;
  }

  private close(at: number, then: TimerStep | null, opener: Opener): void {
    const [eventId, openedBy] = this.openEvent;
    this.closed.push({
      step: this.openStep,
      started_at: this.openStart,
      ended_at: at,
      event_id: eventId,
      opened_by: openedBy,
    });
    this.openStep = then;
    this.openStart = at;
    this.openEvent = opener;
  }

  private endPause(at: number): void {
    if (this.pausedSince === null) return;
    this.pauses.push({ start: this.pausedSince, end: at, id: this.pauseId });
    this.pausedSince = null;
    this.pauseId = null;
  }

  /** A gap pause or gap resume in range (timers2.md §3.4). */
  role(role: Role): void {
    if (role.role === 'gap_pause') {
      this.pausedSince ??= role.at;
      this.pauseId = role.id; // the gap OWNS the open pause: a user resume inside it is stale
    } else {
      this.endPause(role.at); // ends WHATEVER pause is open
    }
  }

  /** Apply one in-range event; its void reason, or null when it applied. */
  apply(e: RunEvent): VoidReason | null {
    const eid = lc(e.id);
    const removal = this.removed.get(eid);
    if (removal !== undefined) {
      // A deleted boundary or pause.
      if (e.type === 'lap' && e.seg === this.expectedSeg(e.at))
        this.ghosts.push([e.at, removal.at]);
      return 'deleted';
    }
    if (
      (e.type === 'next' || e.type === 'lap' || e.type === 'skip') &&
      e.seg !== this.expectedSeg(e.at)
    )
      return 'stale';
    switch (e.type) {
      case 'next':
        this.close(e.at, this.pop(), [eid, 'next']);
        return null;
      case 'lap':
        this.close(e.at, null, [eid, 'lap']);
        return null;
      case 'skip':
        return this.skip(e.step);
      case 'pause':
        if (this.pausedSince !== null) return 'already_paused';
        this.pausedSince = e.at;
        this.pauseId = eid;
        return null;
      case 'resume': {
        const named = lc(e.pause_id ?? '');
        if (this.removed.has(named)) return 'deleted';
        if (this.pausedSince === null) return 'not_paused';
        if (named !== this.pauseId) return 'stale'; // it ends an older pause, or one the gap took over
        this.endPause(e.at);
        return null;
      }
      default: // start, stop, discard, finish, reopen and remove never reach pass 2
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
    let terminalId: string | null = null;
    if (terminal !== null && terminal.type === 'stop') {
      this.endPause(terminal.at); // stop while paused ends the pause
      this.close(terminal.at, null, [null, null]);
      status = 'stopped';
      endedAt = terminal.at;
      terminalId = lc(terminal.id);
    } else if (terminal !== null) {
      status = 'discarded';
      this.pausedSince = null;
      this.pauseId = null;
    } else {
      status = this.pausedSince !== null ? 'paused' : 'running';
    }

    const segments = toSegments(this.closed, this.pauses, this.laps, this.pausedSince);
    const lapCount = segments.filter((s) => s.kind === 'lap').length;
    let open: OpenSegment | null = null;
    let nextLapType: string | null = null;
    if (status === 'running' || status === 'paused') {
      const step = this.openStep;
      const [lapType, label] =
        step === null ? lapTyping(lapCount + 1, this.laps) : [null, step.label];
      open = {
        index: this.closed.length,
        kind: step === null ? 'lap' : 'step',
        step: step === null ? null : step.key,
        label,
        started_at: this.openStart,
        lap_type: lapType,
      };
      // The lap a `lap` tap would open now.
      if (this.laps.length)
        nextLapType = lapTyping(lapCount + (step === null ? 1 : 0) + 1, this.laps)[0];
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
      terminal_id: terminalId,
      next_lap_type: nextLapType,
      lap_count: lapCount,
    };
  }
}

/**
 * How much of `[start, end)` the pauses cover. `openPause` is the start of a pause not
 * resumed yet, which covers up to `end` (measured to `end`: no "not resumed" sentinel).
 */
export function overlap(
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
 * Closed segments with their labels and lap types (timers2.md §3.2). Pauses stay whole;
 * each segment's paused_ms is its overlap with them (T5).
 */
function toSegments(
  closed: readonly Closed[],
  pauses: readonly Pause[],
  laps: readonly LapType[],
  openPause: number | null,
): Segment[] {
  let lapN = 0;
  return closed.map((c) => {
    let lapType: string | null = null;
    let label: string;
    if (c.step === null) {
      lapN += 1;
      [lapType, label] = lapTyping(lapN, laps);
    } else {
      label = c.step.label;
    }
    const paused = overlap(c.started_at, c.ended_at, pauses, openPause);
    return {
      kind: c.step === null ? 'lap' : 'step',
      step: c.step === null ? null : c.step.key,
      label,
      started_at: c.started_at,
      ended_at: c.ended_at,
      active_ms: c.ended_at - c.started_at - paused,
      paused_ms: paused,
      lap_type: lapType,
      event_id: c.event_id,
      opened_by: c.opened_by,
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
 * A stopped run's `Timing`: exactly its fold state (§4.3). `timer` is the run version's,
 * the one it was folded over.
 */
export function projectTiming(state: RunState, timer: FoldTimer): Timing {
  if (state.status !== 'stopped' || state.ended_at === null)
    throw new Error('only a stopped run has a timing');
  const paused = state.pauses.reduce((sum, p) => sum + p.end - p.start, 0);
  return {
    started_at: state.started_at,
    ended_at: state.ended_at,
    active_ms: state.ended_at - state.started_at - paused,
    paused_ms: paused,
    complete: isComplete(timer.steps, state.segments, state.skipped),
    edited: false,
    segments: state.segments,
    skipped: state.skipped,
    pauses: state.pauses,
    terminal_id: state.terminal_id,
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
/** A segment as served or stored; the v2 fields of a pre-v2 one read null (timers2.md §3.3). */
const segmentFromWire = (s: StoredSegmentWire): Segment => ({
  ...s,
  started_at: parseInstant(s.started_at),
  ended_at: parseInstant(s.ended_at),
  lap_type: s.lap_type ?? null,
  event_id: s.event_id ?? null,
  opened_by: s.opened_by ?? null,
});
const pauseToWire = (p: Pause): PauseWire => ({
  start: formatInstant(p.start),
  end: formatInstant(p.end),
  id: p.id,
});
const pauseFromWire = (p: StoredPauseWire): Pause => ({
  start: parseInstant(p.start),
  end: parseInstant(p.end),
  id: p.id ?? null,
});

/** `RunState` as the API carries it (§4.3, timers2.md §3.3). */
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
    skipped: [...state.skipped],
    effects: { ...state.effects },
    pauses: state.pauses.map(pauseToWire),
  };
}

/**
 * The API's `RunState` in integer milliseconds. A `finishing` run is `stopped` to the
 * fold (the server decides `finishing`, §3.5).
 */
export function stateFromWire(state: RunStateWire): RunState {
  return {
    ...state,
    status: state.status === 'finishing' ? 'stopped' : state.status,
    started_at: parseInstant(state.started_at),
    ended_at: state.ended_at === null ? null : parseInstant(state.ended_at),
    open:
      state.open === null
        ? null
        : { ...state.open, started_at: parseInstant(state.open.started_at) },
    paused_since: state.paused_since === null ? null : parseInstant(state.paused_since),
    segments: state.segments.map(segmentFromWire),
    skipped: [...state.skipped],
    pauses: state.pauses.map(pauseFromWire),
    effects: { ...state.effects },
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

/**
 * A served or stored `entries.timing` in integer milliseconds. A pre-v2 stored timing's
 * `terminal_id`, lap types, segment event ids and pause ids read null (timers2.md §3.3).
 */
export function timingFromWire(t: StoredTimingWire): Timing {
  return {
    ...t,
    started_at: parseInstant(t.started_at),
    ended_at: parseInstant(t.ended_at),
    segments: t.segments.map(segmentFromWire),
    pauses: t.pauses.map(pauseFromWire),
    terminal_id: t.terminal_id ?? null,
  };
}
