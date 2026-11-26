/**
 * The local view of runs (timers.md §8.3).
 *
 * A run as this device sees it is the fold (§4) of the server's events, in their arrival
 * order, then its own queued `run.event` items for that run and its aliases, in outbox
 * order. Failed items are left out (the sync sheet lists them). A queued start therefore
 * makes an open run at once, offline too, and a device that is the only one tapping sees
 * exactly the state the server will reach.
 *
 * Pure: the hooks in `useRuns.ts` feed it the cached `listRuns` answer and the outbox.
 */
import type { RunOut } from '../../client/types.gen';
import { isRunEvent, type RunEventPayload } from '../outbox/kinds';
import type { OutboxItem } from '../outbox/types';
import {
  eventFromWire,
  fold,
  lapTyping,
  MAX_RUN_MS,
  overlap,
  projectTiming,
  stateFromWire,
  timeOrder,
  timingFromWire,
} from './fold';
import { parseInstant } from './instant';
import type {
  Effect,
  LapType,
  OpenedBy,
  OpenSegment,
  Pause,
  RunEvent,
  RunState,
  RunStatus,
  Segment,
  TimerStep,
  Timing,
  VoidReason,
} from './types';

type QueuedRunEvent = OutboxItem<RunEventPayload>;

export interface LocalRun {
  /** The server's id for the run (a merge target), or the queued start's id. */
  id: string;
  topic_id: string;
  /** The topic as the queued items name it; null for a run known only from the server. */
  topic: RunEventPayload['topic'] | null;
  version: number;
  /** As the server will have it once the queued items are in (`finishing` included). */
  status: RunStatus;
  state: RunState;
  /** Every event of the view: the server's in arrival order, then the queued ones. */
  events: readonly RunEvent[];
  /** Other run ids that route here: the server's aliases, and queued items' run ids. */
  aliases: readonly string[];
  /** The server's run, once it has seen it. */
  server: RunOut | null;
  /** This run's pending queued items, in outbox order. */
  queued: readonly QueuedRunEvent[];
  /** The version's steps and required-question flag, when a queued item carries them. */
  steps: readonly TimerStep[] | null;
  requires_answers: boolean | null;
  /** The version's lap types, when a queued item carries them (timers2.md §3.2). */
  laps: readonly LapType[] | null;
  /**
   * A reopen enqueued from an entry with no run row here (timers2.md §5.3): the run is
   * projected from the entry's timing, "Resuming…" without controls until the ack.
   */
  resuming: boolean;
  /**
   * A reopened run that has its entry already (timers2.md §4.1): its re-stop updates that
   * entry, so it never makes one, and never leaves the run finishing. False for a run never
   * reopened; null when that hinges on whether the version has a required question, which
   * no queued item here says (the tapping context does).
   */
  has_entry: boolean | null;
}

/** A queued stop's or finish's entry, shown until the server's replaces it (§8.3). */
export interface OptimisticEntry {
  /** The run id: the entry's id is always its run's (§3.5). */
  id: string;
  topic_id: string;
  topic: RunEventPayload['topic'] | null;
  version: number;
  captured_at: number;
  timing: Timing;
  answers: NonNullable<RunEventPayload['event']['answers']>;
  notes: string;
  meta: Record<string, string>;
  sync_state: 'pending';
}

const lc = (id: string) => id.toLowerCase();

/** Outbox order: enqueue time, then the event's own (clamped, so increasing) `at`. */
function outboxOrder(a: QueuedRunEvent, b: QueuedRunEvent): number {
  return (
    a.created_at.localeCompare(b.created_at) ||
    parseInstant(a.payload.event.at) - parseInstant(b.payload.event.at) ||
    a.id.localeCompare(b.id)
  );
}

function queuedEvent(item: QueuedRunEvent): RunEvent {
  const e = item.payload.event;
  return {
    id: lc(item.id),
    type: e.type,
    at: parseInstant(e.at),
    seg: e.seg ?? null,
    step: e.step ?? null,
    pause_id: e.pause_id == null ? null : lc(e.pause_id),
    target: e.target == null ? null : lc(e.target),
  };
}

function serverEvent(e: RunOut['events'][number]): RunEvent {
  return eventFromWire({
    id: lc(e.id),
    type: e.type,
    at: e.at,
    seg: e.seg,
    step: e.step,
    pause_id: e.pause_id == null ? null : lc(e.pause_id),
    target: e.target == null ? null : lc(e.target),
  });
}

const applied = (state: RunState, id: string) => state.effects[lc(id)]?.effect === 'applied';

/** The run's events of `type` that the state applied. */
const appliedOf = (state: RunState, events: readonly RunEvent[], type: RunEvent['type']) =>
  events.filter((e) => e.type === type && applied(state, e.id));

/** Whether a reopen in the run's events was reverted by a discard (timers2.md §3.4). */
const reverted = (state: RunState, events: readonly RunEvent[]) =>
  events.some((e) => e.type === 'reopen' && state.effects[e.id]?.reason === 'reverted');

/**
 * Whether the run has its entry (timers2.md §4.1), as far as this device can tell: the
 * stop that a reopen reopened made it, or a finish did. A reopen from an entry
 * (`payload.entry`) says so outright; this device's stop that carried answers, or any stop
 * of a version without a required question, made one; one without answers on a version
 * with one left the run finishing, until a finish. Only asked of a reopened run.
 */
function hasEntry(
  server: RunOut | null,
  events: readonly RunEvent[],
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean | null,
): boolean | null {
  if (mine.some((i) => i.payload.entry !== undefined)) return true;
  // A finish the server applied, or one of this device's (sent only once the run is
  // stopped or finishing, so it makes the entry, or fails without being stored).
  if (server?.events.some((e) => e.type === 'finish' && e.effect === 'applied')) return true;
  if (mine.some((i) => i.payload.event.type === 'finish')) return true;
  const reopen = events.find((e) => e.type === 'reopen' && e.target != null);
  const stop = mine.find((i) => lc(i.id) === reopen?.target);
  if (stop?.payload.event.answers != null) return true;
  return requiresAnswers === null ? null : !requiresAnswers;
}

/**
 * Whether the run's stop leaves it `finishing` (§3.5): the server says so, or the stop is
 * this device's (queued or just acked), carries no answers, and the version has a
 * required question. The stop is the run's terminal; a re-stop of a run that has its entry
 * never leaves it finishing (timers2.md §4.1).
 */
function stopLeavesFinishing(
  server: RunOut | null,
  state: RunState,
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean,
  entry: boolean,
): boolean {
  // A re-stop of a run that has its entry closes it, whatever the server's status said
  // before the reopen (timers2.md §4.1).
  if (entry) return false;
  if (server?.status === 'finishing') return true;
  if (server?.status === 'stopped') return false;
  const stop = mine.find((i) => i.payload.event.type === 'stop' && lc(i.id) === state.terminal_id);
  if (!stop) return false;
  return stop.payload.event.answers == null && requiresAnswers;
}

/** Whether a reopen in the run's events applied, or was reverted since. */
const reopened = (state: RunState, events: readonly RunEvent[]) =>
  appliedOf(state, events, 'reopen').length > 0 || reverted(state, events);

/**
 * The run's status as the server will have it. `entry`: the run was reopened and has
 * its entry ({@link reopenedWithEntry}, unknown counting as yes).
 */
function statusOf(
  server: RunOut | null,
  state: RunState,
  events: readonly RunEvent[],
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean,
  entry: boolean,
): RunStatus {
  // An open run is open, whatever came before: a reopen reverted by a discard stays void
  // `reverted` after a later reopen opens the run again (vector
  // reopen-revert-then-reopen-again).
  if (state.status === 'running' || state.status === 'paused') return state.status;
  if (reverted(state, events) || (state.status === 'discarded' && reopened(state, events))) {
    // A revert (timers2.md §4.1): the fold restores the stop, but a reopened finishing run
    // (no entry) is thrown away by the server (§5.3, A15).
    return entry ? 'stopped' : 'discarded';
  }
  if (state.status !== 'stopped') return state.status;
  if (!stopLeavesFinishing(server, state, mine, requiresAnswers, entry)) return 'stopped';
  // A finishing run's discard and finish are decided outside the fold (§3.6, §3.7).
  if (mine.some((i) => i.payload.event.type === 'discard')) return 'discarded';
  if (mine.some((i) => i.payload.event.type === 'finish')) return 'stopped';
  return 'finishing';
}

/**
 * `state` (stopped) reopened by `reopen` (timers2.md §3.4): the last segment open again from
 * its start, the gap from the stop to the reopen a pause carrying the stop's id. What the
 * fold makes of a reopen with no taps after it, built without the events: for the overlay
 * (no step list) and for a reopen from an entry (no events at all, §5.3).
 */
function reopenState(
  state: RunState,
  reopen: RunEvent,
  steps: readonly TimerStep[] | null,
  laps: readonly LapType[] | null,
): RunState {
  const last = state.segments.at(-1);
  if (!last || state.ended_at === null) return state;
  const segments = state.segments.slice(0, -1);
  const lapCount = segments.filter((x) => x.kind === 'lap').length;
  const done = new Set([...state.segments.map((x) => x.step), ...state.skipped]);
  return {
    ...state,
    status: 'running',
    ended_at: null,
    open: {
      index: segments.length,
      kind: last.kind,
      step: last.step,
      label: last.label,
      started_at: last.started_at,
      lap_type: last.lap_type,
    },
    next_step: steps?.find((x) => !done.has(x.key))?.key ?? null,
    paused_since: null,
    segments,
    pauses: [...state.pauses, { start: state.ended_at, end: reopen.at, id: state.terminal_id }],
    effects: { ...state.effects, [reopen.id]: { effect: 'applied', reason: null } },
    terminal_id: null,
    next_lap_type: laps?.length
      ? lapTyping(lapCount + (last.kind === 'lap' ? 1 : 0) + 1, laps)[0]
      : null,
    lap_count: lapCount,
  };
}

/**
 * The server's state with this device's taps that need no step list applied on top, in
 * outbox order (§8.3): pause, resume, lap, stop and discard, with the fold's rules. A Next
 * or Skip needs the steps: it shows once the server answers. For a run whose pinned
 * version's steps this device doesn't know, so an offline Pause or Stop still shows.
 * A lap tapped here is labelled from the version's lap types when a queued item carries
 * them (`laps`), else untyped ("Lap n") until the server answers. A reopen of a finishing
 * run reopens it first ({@link reopenState}); taps queued before it are left to the server.
 */
function overlay(
  server: RunOut,
  stateOfServer: RunState,
  queuedTaps: readonly QueuedRunEvent[],
  lapTypes: readonly LapType[] | null,
): RunState {
  let base = stateOfServer;
  let mine = queuedTaps;
  const reopenAt = mine.findIndex(
    (i) =>
      i.payload.event.type === 'reopen' &&
      !stateOfServer.effects[lc(i.id)] &&
      stateOfServer.status === 'stopped' &&
      (i.payload.event.target == null || lc(i.payload.event.target) === stateOfServer.terminal_id),
  );
  const reopenItem = mine[reopenAt];
  if (reopenItem) {
    base = reopenState(stateOfServer, queuedEvent(reopenItem), null, lapTypes);
    mine = mine.slice(reopenAt + 1);
  }
  const effects: Record<string, Effect> = { ...base.effects };
  const segments: Segment[] = [...base.segments];
  const pauses: Pause[] = [...base.pauses];
  let {
    status,
    ended_at: endedAt,
    open,
    next_step: nextStep,
    paused_since: pausedSince,
    next_lap_type: nextLapType,
    terminal_id: terminalId,
  } = base;
  // The event that opened the open segment: the start's for the first, else not known here
  // for the server's (its state doesn't name it), and this device's lap for one it opened.
  let opener: [string | null, OpenedBy | null] =
    base.open?.index === 0 ? [null, 'start'] : [null, null];
  // The server's open pause, which a resume must name: the applied pause that began it.
  let pauseId: string | null = null;
  if (pausedSince !== null) {
    for (const e of server.events.map(serverEvent)) {
      if (e.type === 'pause' && e.at === pausedSince && applied(base, e.id)) pauseId = e.id;
    }
  }
  const close = (seg: OpenSegment, at: number) => {
    const paused = overlap(seg.started_at, at, pauses, pausedSince);
    segments.push({
      kind: seg.kind,
      step: seg.step,
      label: seg.label,
      started_at: seg.started_at,
      ended_at: at,
      active_ms: at - seg.started_at - paused,
      paused_ms: paused,
      lap_type: seg.lap_type,
      event_id: opener[0],
      opened_by: opener[1],
    });
  };
  // A tap before the server's open segment began would close it with negative time.
  const openedAt = base.open?.started_at ?? -Infinity;
  /** A stop or discard: the run's terminal (the first valid one, in outbox order). */
  const terminalReason = (e: RunEvent, terminal: RunEvent | null): VoidReason | null => {
    if (base.open === null || terminal !== null) return 'already_closed';
    if (e.type === 'stop' && e.at < base.started_at) return 'before_start';
    if (e.type === 'stop' && e.at > base.started_at + MAX_RUN_MS) return 'too_long';
    if (e.type === 'stop' && e.at < openedAt) return 'stale';
    return null;
  };
  const apply = (e: RunEvent): VoidReason | null => {
    if (open === null) return 'after_stop';
    if (e.type !== 'resume' && e.at < openedAt) return 'stale';
    if (e.type === 'lap') {
      if (e.seg !== open.index) return 'stale';
      close(open, e.at);
      const laps = segments.filter((x) => x.kind === 'lap').length;
      const [lapType, label] = lapTyping(laps + 1, lapTypes ?? []);
      open = {
        index: open.index + 1,
        kind: 'lap',
        step: null,
        label,
        started_at: e.at,
        lap_type: lapType,
      };
      opener = [e.id, 'lap'];
      nextLapType = lapTypes?.length ? lapTyping(laps + 2, lapTypes)[0] : null;
      return null;
    }
    if (e.type === 'pause') {
      if (pausedSince !== null) return 'already_paused';
      pausedSince = e.at;
      pauseId = e.id;
      status = 'paused';
      return null;
    }
    if (pausedSince === null) return 'not_paused';
    if (e.pause_id !== pauseId) return 'stale';
    // A resume before its pause began would make a negative pause.
    if (e.at < pausedSince) return 'stale';
    pauses.push({ start: pausedSince, end: e.at, id: pauseId });
    pausedSince = null;
    pauseId = null;
    status = 'running';
    return null;
  };
  const decide = (e: RunEvent, reason: VoidReason | null) => {
    effects[e.id] =
      reason === null ? { effect: 'applied', reason: null } : { effect: 'void', reason };
  };
  // As the fold: the terminal by arrival (outbox) order, then the other taps by (at, id),
  // none later than the terminal (the fold's `timeOrder`). Taps the server lists already (acked) are skipped.
  const taps = mine.map(queuedEvent).filter((e) => !effects[e.id]);
  let terminal: RunEvent | null = null;
  for (const e of taps) {
    if (e.type !== 'stop' && e.type !== 'discard') continue;
    const reason = terminalReason(e, terminal);
    if (reason === null) terminal = e;
    decide(e, reason);
  }
  const rest = taps.filter((e) => e.type === 'pause' || e.type === 'resume' || e.type === 'lap');
  rest.sort(timeOrder(rest));
  for (const e of rest)
    decide(e, terminal !== null && e.at > terminal.at ? 'after_stop' : apply(e));
  if (terminal !== null && open !== null) {
    if (terminal.type === 'stop') {
      if (pausedSince !== null) pauses.push({ start: pausedSince, end: terminal.at, id: pauseId });
      pausedSince = null;
      close(open, terminal.at);
      endedAt = terminal.at;
      terminalId = terminal.id;
    }
    status = terminal.type === 'stop' ? 'stopped' : 'discarded';
    open = null;
    nextStep = null;
    nextLapType = null;
    pausedSince = null;
  }
  return {
    status,
    started_at: base.started_at,
    ended_at: endedAt,
    open,
    next_step: nextStep,
    paused_since: pausedSince,
    segments,
    skipped: base.skipped,
    pauses,
    effects,
    terminal_id: terminalId,
    next_lap_type: nextLapType,
    lap_count: segments.filter((x) => x.kind === 'lap').length,
  };
}

function buildRun(
  id: string,
  server: RunOut | null,
  queued: readonly QueuedRunEvent[],
  acked: readonly QueuedRunEvent[],
): LocalRun | null {
  // This device's events: acked ones (sent before anything still queued), then queued.
  const mine = [...acked, ...queued];
  const events = [...(server?.events.map(serverEvent) ?? []), ...mine.map(queuedEvent)];
  // Fold over the run's pinned version only (a payload made for another version can't
  // fold this run); the latest tap knows it best.
  const fitting = server ? mine.filter((i) => i.payload.version === server.version) : mine;
  const meta = fitting.at(-1)?.payload;
  // A reminder's Start may not know the steps (null): another item's, else the server's.
  const known = fitting.findLast((i) => i.payload.steps !== null)?.payload;
  const steps = known?.steps ?? null;
  const laps = fitting.findLast((i) => i.payload.laps != null)?.payload.laps ?? null;
  const timer = { steps: steps ?? [], laps: laps ?? [] };
  let state: RunState;
  if (mine.length === 0 && server) {
    state = stateFromWire(server.state);
  } else if (steps) {
    try {
      state = fold(id, timer, events);
    } catch (err) {
      // Not foldable (no start yet, say): the server's state, if there is one.
      if (!server) return null;
      console.error('[runs] could not fold the local view', err);
      state = stateFromWire(server.state);
    }
  } else if (server) {
    // The pinned version's steps aren't known here: the server's labels, with this
    // device's step-independent taps on top.
    state = overlay(server, stateFromWire(server.state), mine, laps);
  } else if (mine.some((i) => i.payload.event.type === 'start')) {
    // This device's start that didn't know the steps (a reminder's, nothing cached, §10.2):
    // fold over none, so the run shows its clock and can be stopped offline. `steps` stays
    // null: there is no step list yet.
    try {
      state = fold(id, timer, events);
    } catch (err) {
      console.error('[runs] could not fold the local view', err);
      return null;
    }
  } else {
    return null;
  }
  const topicId = server?.topic_id ?? meta?.topic.id;
  if (topicId === undefined) return null;
  const aliases = new Set([
    ...(server?.aliases.map(lc) ?? []),
    ...mine.map((i) => lc(i.payload.run_id)),
  ]);
  aliases.delete(id);
  const entry = reopenedWithEntry(server, state, events, mine, known?.requires_answers ?? null);
  return {
    id,
    topic_id: topicId,
    topic: meta?.topic ?? null,
    version: server?.version ?? meta?.version ?? 0,
    status: statusOf(
      server,
      state,
      events,
      mine,
      known?.requires_answers ?? false,
      entry !== false,
    ),
    state,
    events,
    aliases: [...aliases],
    server,
    queued,
    steps,
    requires_answers: known?.requires_answers ?? null,
    laps,
    resuming: false,
    has_entry: entry,
  };
}

/**
 * Whether a reopened run (applied, or reverted since) has its entry ({@link hasEntry}):
 * false for a run never reopened, null when it hinges on a required question not known here.
 */
function reopenedWithEntry(
  server: RunOut | null,
  state: RunState,
  events: readonly RunEvent[],
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean | null,
): boolean | null {
  return reopened(state, events) && hasEntry(server, events, mine, requiresAnswers);
}

/**
 * A run that only a reopen enqueued from its entry knows (timers2.md §5.3): no run row here,
 * no start. Projected from the entry's timing as the reopen leaves it, "resuming" until the
 * ack replaces it with the server's run. A discard queued after it reverts it: the entry's
 * state again, stopped. Other taps aren't offered on it ({@link tapRun}).
 */
function resumingRun(id: string, queued: readonly QueuedRunEvent[]): LocalRun | null {
  const at = queued.findIndex(
    (i) => i.payload.event.type === 'reopen' && i.payload.entry !== undefined,
  );
  const item = queued[at];
  const entry = item?.payload.entry;
  if (!item || !entry) return null;
  // This device's removes of the entry queued before the reopen apply first (§5.3, R26):
  // the server folds them before it, and the entry's timing at the tap doesn't have them.
  const timing = queued
    .slice(0, at)
    .filter((i) => i.payload.event.type === 'remove' && i.payload.event.target != null)
    .reduce(
      (t, i) => removeFromTiming(t, lc(i.payload.event.target ?? ''), i.payload.laps ?? null),
      timingFromWire(entry.timing),
    );
  const closed: RunState = {
    status: 'stopped',
    started_at: timing.started_at,
    ended_at: timing.ended_at,
    open: null,
    next_step: null,
    paused_since: null,
    segments: timing.segments,
    skipped: timing.skipped,
    pauses: timing.pauses,
    effects: {},
    terminal_id: timing.terminal_id,
    next_lap_type: null,
    lap_count: timing.segments.filter((x) => x.kind === 'lap').length,
  };
  const { steps, laps } = item.payload;
  const reopen = queuedEvent(item);
  const discard = queued.slice(at + 1).find((i) => i.payload.event.type === 'discard');
  let state = reopenState(closed, reopen, steps, laps ?? null);
  if (discard) {
    state = {
      ...closed,
      effects: {
        [reopen.id]: { effect: 'void', reason: 'reverted' },
        [lc(discard.id)]: { effect: 'applied', reason: null },
      },
    };
  }
  return {
    id,
    topic_id: item.payload.topic.id,
    topic: item.payload.topic,
    version: item.payload.version,
    status: state.status,
    state,
    events: queued.map(queuedEvent),
    aliases: [],
    server: null,
    queued,
    steps,
    requires_answers: item.payload.requires_answers,
    laps: laps ?? null,
    resuming: !discard,
    has_entry: true,
  };
}

/**
 * Every run in the local view: each server run (open or finishing, from `listRuns` and
 * this device's own responses) with its queued items, then each run that only this
 * device's start knows (queued, or acked but not yet in `listRuns`). `acked` are the
 * acked-runs record's items (`acked.ts`): folded in like queued ones, but never
 * projected as optimistic entries. Items of a run that is in neither (it closed, and the
 * server will decide their late merge, §4.4) make no run.
 */
export function localRuns(
  serverRuns: readonly RunOut[],
  items: readonly OutboxItem[],
  acked: readonly OutboxItem<RunEventPayload>[] = [],
): LocalRun[] {
  const target = new Map<string, string>();
  for (const r of serverRuns) {
    target.set(lc(r.id), lc(r.id));
    for (const a of r.aliases) target.set(lc(a), lc(r.id));
  }
  const group = (list: readonly QueuedRunEvent[]) => {
    const out = new Map<string, QueuedRunEvent[]>();
    for (const item of [...list].sort(outboxOrder)) {
      const key = target.get(lc(item.payload.run_id)) ?? lc(item.payload.run_id);
      out.set(key, [...(out.get(key) ?? []), item]);
    }
    return out;
  };
  const active = items.filter(isRunEvent).filter((i) => i.status === 'pending');
  const inQueue = new Set(items.map((i) => i.id));
  const queued = group(active);
  const sent = group(acked.filter((i) => !inQueue.has(i.id)));
  const out: LocalRun[] = [];
  for (const r of serverRuns) {
    const id = lc(r.id);
    const run = buildRun(id, r, queued.get(id) ?? [], sent.get(id) ?? []);
    queued.delete(id);
    sent.delete(id);
    if (run) out.push(run);
  }
  for (const id of new Set([...queued.keys(), ...sent.keys()])) {
    const q = queued.get(id) ?? [];
    const a = sent.get(id) ?? [];
    const run = [...a, ...q].some((i) => lc(i.id) === id && i.payload.event.type === 'start')
      ? buildRun(id, null, q, a)
      : resumingRun(id, q);
    if (run) out.push(run);
  }
  return out;
}

export const isOpen = (run: Pick<LocalRun, 'status'>): boolean =>
  run.status === 'running' || run.status === 'paused';

/** The topic's open run (running or paused) in the view, if any: one per topic (§5). */
export function openRunOf(runs: readonly LocalRun[], topicId: string): LocalRun | undefined {
  return runs.find((r) => r.topic_id === topicId && isOpen(r));
}

/** The run that `runId` (its own id or an alias) routes to. */
export function runById(runs: readonly LocalRun[], runId: string): LocalRun | undefined {
  const id = lc(runId);
  return runs.find((r) => r.id === id || r.aliases.includes(id));
}

/**
 * Ids of the topics with an open run, for `dueCount` (timers.md §11.1). A finishing run
 * isn't open: its topic keeps its due state.
 */
export function openRunTopics(runs: readonly LocalRun[]): ReadonlySet<string> {
  return new Set(runs.filter(isOpen).map((r) => r.topic_id));
}

/** The id of the pause a resume would end: the latest applied pause, while paused. */
export function openPauseId(run: LocalRun): string | null {
  if (run.state.paused_since === null) return null;
  let latest: RunEvent | null = null;
  for (const e of run.events) {
    if (e.type !== 'pause' || !applied(run.state, e.id)) continue;
    if (latest === null || e.at > latest.at || (e.at === latest.at && e.id > latest.id)) latest = e;
  }
  return latest?.id ?? null;
}

/**
 * Entries that queued taps will make (§8.3): a stop that won't leave the run finishing,
 * or the finish of a finishing run, until the server answers. The answers and notes are
 * the finish's, else the stop's.
 */
export function optimisticEntries(runs: readonly LocalRun[]): OptimisticEntry[] {
  const out: OptimisticEntry[] = [];
  for (const run of runs) {
    if (run.status !== 'stopped' || run.server?.status === 'stopped' || !run.steps) continue;
    if (!run.queued.some((i) => i.payload.makes_entry)) continue;
    const carrier =
      run.queued.findLast((i) => i.payload.event.type === 'finish') ??
      run.queued.find((i) => i.payload.event.type === 'stop');
    const event = carrier?.payload.event;
    const timing = projectTiming(run.state, { steps: run.steps });
    out.push({
      id: run.id,
      topic_id: run.topic_id,
      topic: run.topic,
      version: run.version,
      captured_at: timing.ended_at,
      timing,
      answers: event?.answers ?? {},
      notes: event?.notes ?? '',
      meta: event?.meta ?? {},
      sync_state: 'pending',
    });
  }
  return out;
}

/**
 * Ids of the entries not to show as entries (timers2.md §5.3, OQ-14): an entry whose id is
 * a locally open or finishing run (a reopen, here or elsewhere); the run represents it.
 * Counts, due state, stats and CSV still count it.
 */
export function hiddenEntryIds(runs: readonly LocalRun[]): ReadonlySet<string> {
  return new Set(runs.filter((r) => isOpen(r) || r.status === 'finishing').map((r) => r.id));
}

/**
 * An entry's timing with this device's pending `remove`s of its run applied (timers2.md
 * §5.3, A14): a removed pause's time becomes active, a removed lap boundary joins its
 * segment to the previous one and later laps renumber (and so flip type, §3.2). `pending`
 * marks it until the ack, when the server's entry (its revision bumped) replaces it; the
 * entry's revision is unchanged here. A remove whose target isn't in the timing changes
 * nothing (the server answers `no_target`).
 */
export function projectedEntryTiming(
  entry: { id: string; timing: Timing },
  items: readonly OutboxItem[],
): { timing: Timing; pending: boolean } {
  const id = lc(entry.id);
  const removes = items
    .filter(isRunEvent)
    .filter(
      (i) =>
        i.status === 'pending' &&
        i.payload.event.type === 'remove' &&
        i.payload.event.target != null &&
        lc(i.payload.run_id) === id,
    )
    .sort(outboxOrder);
  let timing = entry.timing;
  for (const item of removes) {
    const laps = item.payload.laps ?? null;
    timing = removeFromTiming(timing, lc(item.payload.event.target ?? ''), laps);
  }
  return { timing, pending: removes.length > 0 };
}

function removeFromTiming(timing: Timing, target: string, laps: readonly LapType[] | null): Timing {
  const pause = timing.pauses.find((p) => p.id !== null && lc(p.id) === target);
  if (pause) {
    const ms = pause.end - pause.start;
    const segments = timing.segments.map((x) => {
      const covered = Math.max(
        0,
        Math.min(x.ended_at, pause.end) - Math.max(x.started_at, pause.start),
      );
      return covered
        ? { ...x, active_ms: x.active_ms + covered, paused_ms: x.paused_ms - covered }
        : x;
    });
    return {
      ...timing,
      active_ms: timing.active_ms + ms,
      paused_ms: timing.paused_ms - ms,
      segments,
      pauses: timing.pauses.filter((p) => p !== pause),
    };
  }
  const at = timing.segments.findIndex(
    (x, i) => i > 0 && x.event_id !== null && lc(x.event_id) === target && x.opened_by === 'lap',
  );
  const prev = timing.segments[at - 1];
  const removed = timing.segments[at];
  if (at < 1 || !prev || !removed) return timing;
  const merged: Segment = {
    ...prev,
    ended_at: removed.ended_at,
    active_ms: prev.active_ms + removed.active_ms,
    paused_ms: prev.paused_ms + removed.paused_ms,
  };
  const joined = [...timing.segments.slice(0, at - 1), merged, ...timing.segments.slice(at + 1)];
  // Relabel the laps in order (§3.2). Without the lap types, typed laps keep their labels.
  const typed = joined.some((x) => x.kind === 'lap' && x.lap_type !== null);
  if (laps === null && typed) return { ...timing, segments: joined };
  let n = 0;
  const segments = joined.map((x) => {
    if (x.kind !== 'lap') return x;
    n += 1;
    const [lapType, label] = lapTyping(n, laps ?? []);
    return { ...x, lap_type: lapType, label };
  });
  return { ...timing, segments };
}
