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
  lapLabel,
  MAX_RUN_MS,
  overlap,
  projectTiming,
  stateFromWire,
  timeOrder,
} from './fold';
import { parseInstant } from './instant';
import type {
  Effect,
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
  });
}

const applied = (state: RunState, id: string) => state.effects[lc(id)]?.effect === 'applied';

/**
 * Whether the run's stop leaves it `finishing` (§3.5): the server says so, or the stop is
 * this device's (queued or just acked), carries no answers, and the version has a
 * required question.
 */
function stopLeavesFinishing(
  server: RunOut | null,
  state: RunState,
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean,
): boolean {
  if (server?.status === 'finishing') return true;
  if (server?.status === 'stopped') return false;
  const stop = mine.find((i) => i.payload.event.type === 'stop' && applied(state, i.id));
  if (!stop) return false;
  return stop.payload.event.answers == null && requiresAnswers;
}

function statusOf(
  server: RunOut | null,
  state: RunState,
  mine: readonly QueuedRunEvent[],
  requiresAnswers: boolean,
): RunStatus {
  if (state.status !== 'stopped') return state.status;
  if (!stopLeavesFinishing(server, state, mine, requiresAnswers)) return 'stopped';
  // A finishing run's discard and finish are decided outside the fold (§3.6, §3.7).
  if (mine.some((i) => i.payload.event.type === 'discard')) return 'discarded';
  if (mine.some((i) => i.payload.event.type === 'finish')) return 'stopped';
  return 'finishing';
}

/**
 * The server's state with this device's taps that need no step list applied on top, in
 * outbox order (§8.3): pause, resume, lap, stop and discard, with the fold's rules. A Next
 * or Skip needs the steps: it shows once the server answers. For a run whose pinned
 * version's steps this device doesn't know, so an offline Pause or Stop still shows.
 */
function overlay(server: RunOut, base: RunState, mine: readonly QueuedRunEvent[]): RunState {
  const effects: Record<string, Effect> = { ...base.effects };
  const segments: Segment[] = [...base.segments];
  const pauses: Pause[] = [...base.pauses];
  let { status, ended_at: endedAt, open, next_step: nextStep, paused_since: pausedSince } = base;
  // The server's open pause, which a resume must name.
  let pauseId: string | null = null;
  if (pausedSince !== null) {
    for (const e of server.events) {
      if (e.type === 'pause' && effects[lc(e.id)]?.effect === 'applied') pauseId = lc(e.id);
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
      open = {
        index: open.index + 1,
        kind: 'lap',
        step: null,
        label: lapLabel(laps + 1),
        started_at: e.at,
      };
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
    pauses.push({ start: pausedSince, end: e.at });
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
      if (pausedSince !== null) pauses.push({ start: pausedSince, end: terminal.at });
      pausedSince = null;
      close(open, terminal.at);
      endedAt = terminal.at;
    }
    status = terminal.type === 'stop' ? 'stopped' : 'discarded';
    open = null;
    nextStep = null;
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
  let state: RunState;
  if (mine.length === 0 && server) {
    state = stateFromWire(server.state);
  } else if (steps) {
    try {
      state = fold(id, steps, events);
    } catch (err) {
      // Not foldable (no start yet, say): the server's state, if there is one.
      if (!server) return null;
      console.error('[runs] could not fold the local view', err);
      state = stateFromWire(server.state);
    }
  } else if (server) {
    // The pinned version's steps aren't known here: the server's labels, with this
    // device's step-independent taps on top.
    state = overlay(server, stateFromWire(server.state), mine);
  } else if (mine.some((i) => i.payload.event.type === 'start')) {
    // This device's start that didn't know the steps (a reminder's, nothing cached, §10.2):
    // fold over none, so the run shows its clock and can be stopped offline. `steps` stays
    // null: there is no step list yet.
    try {
      state = fold(id, [], events);
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
  return {
    id,
    topic_id: topicId,
    topic: meta?.topic ?? null,
    version: server?.version ?? meta?.version ?? 0,
    status: statusOf(server, state, mine, known?.requires_answers ?? false),
    state,
    events,
    aliases: [...aliases],
    server,
    queued,
    steps,
    requires_answers: known?.requires_answers ?? null,
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
    if (![...a, ...q].some((i) => lc(i.id) === id && i.payload.event.type === 'start')) continue;
    const run = buildRun(id, null, q, a);
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
    const timing = projectTiming(run.state, run.steps);
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
