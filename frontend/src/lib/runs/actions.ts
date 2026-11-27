/**
 * Enqueueing run taps (timers.md §5.1, §8.2, §8.3).
 *
 * Every tap is one `run.event` outbox item. Its `at` is device now + the server offset,
 * read at the tap (before waiting for an earlier one), truncated, and clamped to just after the run's latest `at` in the local view, so a
 * device's own taps stay in order. Its `seg`, `step` and `pause_id` come from the local
 * view, which already includes every earlier queued tap.
 *
 * Taps are serialised (in this context, and across tabs and the service worker through a
 * Web Lock where there is one), and each reads the outbox afresh, so two quick taps never
 * see the same view. That is what makes "never enqueue a second start" (§4.5) hold on
 * one device: a start for a topic whose view already has an open run returns that run.
 */
import type { RunEventIn, RunOut } from '../../client/types.gen';
import { RUN_EVENT, isRunEvent, type RunEventPayload } from '../outbox/kinds';
import type { Outbox } from '../outbox/outbox';
import type { OutboxItem } from '../outbox/types';
import { uuid } from '../uuid';
import { clampToRun, latestAt, serverNow } from './clock';
import { timingToWire } from './fold';
import { formatInstant, parseInstant } from './instant';
import { isOpen, localRuns, openPauseId, openRunOf, runById, type LocalRun } from './localView';
import { serverOffset } from './serverClock';
import type { LapType, RunEventType, TimerStep, Timing } from './types';

/** Web Lock name for run taps; the service worker's Start action takes it too. */
export const RUN_TAP_LOCK = 'quickr-run-tap';

/**
 * The run's topic and **the run's own version** (the one it is pinned to, not
 * necessarily the topic's current one), as the tapping screen knows them. For a start, the
 * version the run will be pinned to.
 */
export interface RunContext {
  topic: RunEventPayload['topic'];
  version: number;
  /** That version's steps; null when this device doesn't know them yet (no step list). */
  steps: TimerStep[] | null;
  /**
   * That version's lap types (timers2.md §3.2), so laps tapped here are labelled at once;
   * absent or null when not known (they show "Lap n" until the server answers).
   */
  laps?: LapType[] | null;
  /**
   * The version has a required question: a stop without answers leaves it finishing. Null
   * when not known: a stop then projects no entry (the server decides, §3.5).
   */
  requires_answers: boolean | null;
}

/** A start's context: a reminder's Start may not know the version's steps and questions. */
export type StartContext = Omit<RunContext, 'steps' | 'requires_answers'> & {
  steps: TimerStep[] | null;
  requires_answers: boolean | null;
};

export interface RunTapDeps {
  outbox: Outbox;
  /** The server's runs as last known (the cached `listRuns` answer). Read inside the lock. */
  serverRuns: () => readonly RunOut[];
  /** The acked-runs record (`acked.ts`), read inside the lock; none by default. */
  acked?: () => Promise<readonly OutboxItem<RunEventPayload>[]>;
  /**
   * Fetch `listRuns` once more, so `serverRuns` is current. A tap whose run isn't in the
   * view tries again after it before giving up.
   */
  refresh?: () => Promise<void>;
  /**
   * Whether a run id is known here other than as an item, acked event or run: an entry
   * with it (its run stopped, §3.3). A reminder's Start with such an id was made already.
   */
  knownId?: (id: string) => Promise<boolean>;
  /** Device time, epoch ms. */
  now?: () => number;
  /** The server-time offset (`serverClock.ts`). */
  offset?: () => number;
}

/** A tap after the start, `reopen` and `remove` included (timers2.md §3.4). */
export type TapType = Exclude<RunEventType, 'start'>;

/**
 * The entry a reopen or remove is tapped from (timers2.md §5.3): its id (the run's), its
 * timing (`timingFromWire` of the served one) and revision. Used when no run row is local
 * (after a relaunch, on another device, past the acked window): the targets come from the
 * timing's ids, and the local view projects from it.
 */
export interface EntryRef {
  id: string;
  timing: Timing;
  revision: number;
}

/** What a reopen or remove is aimed at: the chosen event id, and the entry tapped from. */
export interface TapOptions {
  expect?: TapExpect;
  /** A remove's target: the id of the pause, lap or reopened stop to remove. */
  target?: string;
  /** The entry the tap is made from, for a run not in the local view. */
  entry?: EntryRef;
}

/** `tapRun` was given the context of another version than the run's own. */
export class RunVersionMismatch extends Error {
  readonly runId: string;
  readonly runVersion: number;

  constructor(runId: string, runVersion: number, ctxVersion: number) {
    super(`run ${runId} is pinned to version ${String(runVersion)}, not ${String(ctxVersion)}`);
    this.name = 'RunVersionMismatch';
    this.runId = runId;
    this.runVersion = runVersion;
  }
}

/**
 * What the user saw when they tapped: the open segment, the step a Skip named, and whether
 * the run was paused (and by which pause). A tap whose target has moved since (a double
 * tap, read after the first was queued) is dropped here, as the fold would void it
 * (`stale`, `already_paused`, `not_paused`, §4.2). Stop, discard, finish, reopen and
 * remove don't use it: their repeats are void (`already_closed`, `not_stopped`,
 * `no_target`) or idempotent.
 */
export interface TapExpect {
  seg: number | null;
  step: string | null;
  paused: boolean;
  pauseId: string | null;
}

function moved(run: LocalRun, type: TapType, target: Partial<RunEventIn>, e: TapExpect): boolean {
  switch (type) {
    case 'next':
    case 'lap':
      return target.seg !== e.seg;
    case 'skip':
      return target.seg !== e.seg || target.step !== e.step;
    case 'pause':
      return e.paused || run.state.paused_since !== null;
    case 'resume':
      return !e.paused || target.pause_id !== e.pauseId;
    default:
      return false;
  }
}

/** What a stop or finish carries (§3.5, §3.6). */
export type TapBody = Pick<RunEventIn, 'answers' | 'notes' | 'meta'>;

let tail: Promise<unknown> = Promise.resolve();

function serialised<T>(fn: () => Promise<T>): Promise<T> {
  const locks = (globalThis as { navigator?: { locks?: LockManager } }).navigator?.locks;
  const run = tail.then(() => (locks ? locks.request(RUN_TAP_LOCK, fn) : fn()));
  tail = run.catch(() => undefined);
  return run;
}

async function view(
  deps: RunTapDeps,
): Promise<{ runs: LocalRun[]; items: OutboxItem[]; acked: readonly OutboxItem[] }> {
  const items = await deps.outbox.list();
  const acked = (await deps.acked?.()) ?? [];
  return { runs: localRuns(deps.serverRuns(), items, acked), items, acked };
}

/**
 * The tap's own time: device now + offset, truncated, read when the user tapped, before
 * waiting for an earlier tap (§5.1 item 3).
 */
function tapTime(deps: RunTapDeps): number {
  return serverNow((deps.now ?? Date.now)(), (deps.offset ?? serverOffset)());
}

/**
 * The `at` for a new event of `run`: the tap's time, clamped to just after every `at` the
 * run has here (§5.1 item 4).
 */
function stamp(tapAt: number, run: LocalRun | null, items: readonly OutboxItem[]): string {
  const ats = run ? run.events.map((e) => e.at) : [];
  if (run) {
    // Failed items too: they may be retried, and must stay in tap order.
    const ids = new Set([run.id, ...run.aliases]);
    for (const i of items) {
      if (isRunEvent(i) && ids.has(i.payload.run_id.toLowerCase()))
        ats.push(parseInstant(i.payload.event.at));
    }
  }
  return formatInstant(clampToRun(tapAt, latestAt(ats)));
}

function payloadOf(
  ctx: StartContext & Pick<RunContext, 'laps'>,
  runId: string,
  makesEntry: boolean,
  event: RunEventPayload['event'],
): RunEventPayload {
  return {
    topic: ctx.topic,
    run_id: runId.toLowerCase(),
    version: ctx.version,
    steps: ctx.steps,
    ...(ctx.laps !== undefined ? { laps: ctx.laps } : {}),
    requires_answers: ctx.requires_answers,
    makes_entry: makesEntry,
    event,
  };
}

export interface StartResult {
  /** The run the tap went to: the new one, or the topic's open run. */
  runId: string;
  /** False when the topic already had an open run here: nothing was enqueued. */
  started: boolean;
}

/**
 * The run of `topicId` this device's **pending** items open: a pending start with no pending
 * stop or discard. No fold: a reminder's Start may not know the steps.
 */
function pendingOpenRun(items: readonly OutboxItem[], topicId: string): string | null {
  const pending = items.filter(
    (i): i is OutboxItem<RunEventPayload> => isRunEvent(i) && i.status === 'pending',
  );
  for (const start of pending) {
    const { event, run_id: runId } = start.payload;
    if (event.type !== 'start' || event.topic_id !== topicId) continue;
    const closed = pending.some(
      (i) =>
        i.payload.run_id === runId &&
        (i.payload.event.type === 'stop' || i.payload.event.type === 'discard'),
    );
    if (!closed) return runId;
  }
  return null;
}

/**
 * Start a run of `ctx.topic`, unless the local view already has an open run for it: then
 * the tap routes to that run and nothing is enqueued (§4.5). `id` is the run id (a
 * reminder's Start derives it from the slot, §10.2); a new one by default. A given `id`
 * this device already knows (an item, an acked event, a run, or `deps.knownId`'s entry
 * with it) was already started: nothing is enqueued either.
 *
 * A reminder's Start (`reminder`, from the service worker) sees no `listRuns` and nothing
 * prunes its acked record, so only this device's **pending** items count as an open run
 * there; acked and failed ones only count as a known id. A start for a topic whose run is
 * open on the server is merged by the server (§4.5).
 */
export function startRun(
  deps: RunTapDeps,
  ctx: StartContext,
  opts: {
    id?: string;
    source?: string;
    meta?: Record<string, string>;
    /** A reminder's Start: the server it came from (`RunEventPayload.expect_server_id`). */
    expectServerId?: string;
    /** A reminder's Start: an open run is one this device's pending items make. */
    reminder?: boolean;
  } = {},
): Promise<StartResult> {
  const tapAt = tapTime(deps);
  return serialised(async () => {
    const { runs, items, acked } = await view(deps);
    const runId = (opts.id ?? uuid()).toLowerCase();
    const known = (i: OutboxItem) => i.id.toLowerCase() === runId;
    if (
      opts.id !== undefined &&
      (items.some(known) ||
        acked.some(known) ||
        runById(runs, runId) ||
        (await deps.knownId?.(runId).catch(() => false)))
    ) {
      return { runId, started: false };
    }
    // The page also checks the pending items: a run only they open may not fold (§8.3).
    const open = opts.reminder
      ? pendingOpenRun(items, ctx.topic.id)
      : (openRunOf(runs, ctx.topic.id)?.id ?? pendingOpenRun(items, ctx.topic.id));
    if (open !== null) return { runId: open, started: false };
    const event: RunEventPayload['event'] = {
      type: 'start',
      at: stamp(tapAt, null, items),
      topic_id: ctx.topic.id,
      version: ctx.version,
      ...(opts.source !== undefined ? { source: opts.source } : {}),
      ...(opts.meta !== undefined ? { meta: opts.meta } : {}),
    };
    const payload: RunEventPayload = {
      ...payloadOf(ctx, runId, false, event),
      ...(opts.expectServerId !== undefined ? { expect_server_id: opts.expectServerId } : {}),
    };
    await deps.outbox.enqueue(RUN_EVENT, payload, { id: runId });
    return { runId, started: true };
  });
}

/**
 * The fields a tap of `type` needs from the run's current state (§3.2), or null when the
 * run's state has no target for it: no open segment for next, lap, skip or pause; no
 * step left to skip; no pause to resume; a finish of a run that isn't stopped; a reopen of
 * a run that isn't stopped or finishing; a remove whose `target` isn't a pause, lap or
 * reopened stop of the run. A run "resuming" from its entry (timers2.md §5.3) takes only a
 * discard (its revert) until the ack.
 */
function targetOf(run: LocalRun, type: TapType, opts: TapOptions): Partial<RunEventIn> | null {
  const open = run.state.open;
  if (run.resuming && type !== 'discard') return null;
  switch (type) {
    case 'next':
    case 'lap':
      return open ? { seg: open.index } : null;
    case 'skip': {
      if (!open) return null;
      const step = open.kind === 'step' ? open.step : run.state.next_step;
      return step === null ? null : { seg: open.index, step };
    }
    case 'pause':
      return open ? {} : null;
    case 'resume': {
      const pauseId = openPauseId(run);
      return pauseId === null ? null : { pause_id: pauseId };
    }
    case 'stop':
      return isOpen(run) ? {} : null;
    case 'discard':
      return isOpen(run) || run.status === 'finishing' ? {} : null;
    case 'finish':
      return run.status === 'finishing' || run.status === 'stopped' ? {} : null;
    case 'reopen':
      // The stop that closed it (§4.2: the ordering rule keys on it); null when not known.
      if (run.status !== 'stopped' && run.status !== 'finishing') return null;
      return { target: run.state.terminal_id ?? opts.entry?.timing.terminal_id ?? null };
    case 'remove': {
      const target = opts.target?.toLowerCase();
      if (target === undefined) return null;
      const named = run.events.some(
        (e) => e.id === target && (e.type === 'pause' || e.type === 'lap'),
      );
      const gap = run.state.pauses.some((p) => p.id === target);
      return named || gap || entryIds(opts.entry).has(target) ? { target } : null;
    }
  }
}

/**
 * For a remove of a reopened stop of the run, its gap pause's take-over
 * (`RunEventPayload.gap`): the user pause open at the stop, whose time the gap pause starts
 * at (timers2.md §3.4, "the gap owns the open pause"). Null for any other target.
 */
function gapOf(run: LocalRun, target: string): RunEventPayload['gap'] | null {
  const stop = run.events.find((e) => e.id === target && e.type === 'stop');
  const pause = run.state.pauses.find((p) => p.id === target);
  if (!stop || !pause) return null;
  if (pause.start >= stop.at) return { absorbs: null };
  const user = run.events.find(
    (e) =>
      e.type === 'pause' && e.at === pause.start && run.state.effects[e.id]?.effect === 'applied',
  );
  return user ? { absorbs: user.id } : null;
}

/** The ids a remove can name in an entry's timing (§3.3): laps' event ids and pause ids. */
function entryIds(entry: EntryRef | undefined): Set<string> {
  if (!entry) return new Set();
  const laps = entry.timing.segments
    .filter((x) => x.opened_by === 'lap' && x.event_id !== null)
    .map((x) => x.event_id ?? '');
  const pauses = entry.timing.pauses.map((p) => p.id ?? '').filter((id) => id !== '');
  return new Set([...laps, ...pauses].map((id) => id.toLowerCase()));
}

/**
 * Whether the tap makes the run's entry (`RunEventPayload.makes_entry`). A re-stop of a
 * run that has its entry updates that entry (timers2.md §4.1): it makes none.
 */
function makesEntry(run: LocalRun, ctx: RunContext, type: TapType, body: TapBody): boolean {
  if (type === 'finish') return run.status === 'finishing';
  if (type === 'stop') {
    // Not known from the items: the reopened stop left the run finishing (no entry) only
    // if the version has a required question.
    const required = ctx.requires_answers;
    const entry = run.has_entry ?? required !== true;
    return !entry && (body.answers != null || required === false);
  }
  return false;
}

/**
 * A reopen or remove of a run that isn't in the local view, from its entry (timers2.md
 * §5.3): the targets are the timing's ids (a reopen's `terminal_id`, null on a pre-v2
 * timing, which the server resolves, A12); the entry rides along for the projection. Its
 * `at` is clamped after the entry's end.
 */
function fromEntry(
  tapAt: number,
  runId: string,
  ctx: RunContext,
  type: 'reopen' | 'remove',
  entry: EntryRef,
  target: string | undefined,
): RunEventPayload | null {
  let named: string | null;
  if (type === 'reopen') named = entry.timing.terminal_id?.toLowerCase() ?? null;
  else {
    named = target?.toLowerCase() ?? null;
    if (named === null || !entryIds(entry).has(named)) return null;
  }
  const event: RunEventPayload['event'] = {
    type,
    at: formatInstant(clampToRun(tapAt, entry.timing.ended_at)),
    target: named,
  };
  return {
    ...payloadOf(ctx, runId, false, event),
    entry: { timing: timingToWire(entry.timing), revision: entry.revision },
  };
}

/**
 * Enqueue one tap on the run `runId` routes to (its id or an alias). Returns the item, or
 * null when the run isn't in the local view (after one `refresh`) or its state has no
 * target for the tap, or (with `opts.expect`) the target moved since the user saw it. A finish of a run that isn't in the view is still enqueued: a
 * stopped run drops out of `listRuns`, and the server applies or voids the finish. Throws
 * {@link RunVersionMismatch} when `ctx` is for another version than the run's. A
 * discard of a run the server never saw drops the run's items instead (K6): the item is
 * returned but not stored.
 */
export function tapRun(
  deps: RunTapDeps,
  runId: string,
  ctx: RunContext,
  type: TapType,
  body: TapBody = {},
  opts: TapOptions = {},
): Promise<OutboxItem<RunEventPayload> | null> {
  const tapAt = tapTime(deps);
  return serialised(async () => {
    let { runs, items } = await view(deps);
    let run = runById(runs, runId);
    if (!run && deps.refresh) {
      // The cache may not have caught up with an ack yet: look once more.
      await deps.refresh();
      ({ runs, items } = await view(deps));
      run = runById(runs, runId);
    }
    // A reopen while the topic has another open run is refused by the server (409
    // `conflict`, A15): the intent would be lost, so it isn't queued.
    const other = openRunOf(runs, ctx.topic.id);
    if (type === 'reopen' && other && other.id !== run?.id) return null;
    if (!run) {
      // A stopped run leaves the view once `listRuns` no longer lists it, but its answers
      // can still come (§3.6): the server decides a finish, so send it to the run id.
      if ((type === 'reopen' || type === 'remove') && opts.entry) {
        const payload = fromEntry(tapAt, runId, ctx, type, opts.entry, opts.target);
        return payload ? deps.outbox.enqueue(RUN_EVENT, payload) : null;
      }
      if (type !== 'finish') return null;
      const event: RunEventPayload['event'] = {
        type,
        // A finish isn't folded: its `at` needs no clamp.
        at: stamp(tapAt, null, items),
        ...(body.answers != null ? { answers: body.answers } : {}),
        ...(body.notes != null ? { notes: body.notes } : {}),
        ...(body.meta != null ? { meta: body.meta } : {}),
      };
      return deps.outbox.enqueue(RUN_EVENT, payloadOf(ctx, runId, false, event));
    }
    if (run.version !== ctx.version) throw new RunVersionMismatch(run.id, run.version, ctx.version);
    const target = targetOf(run, type, opts);
    if (target === null) return null;
    if (opts.expect && moved(run, type, target, opts.expect)) return null;
    const carries = type === 'stop' || type === 'finish';
    const event: RunEventPayload['event'] = {
      type,
      at: stamp(tapAt, run, items),
      ...target,
      ...(carries && body.answers != null ? { answers: body.answers } : {}),
      ...(carries && body.notes != null ? { notes: body.notes } : {}),
      ...(body.meta != null ? { meta: body.meta } : {}),
    };
    const payload = payloadOf(ctx, run.id, makesEntry(run, ctx, type, body), event);
    if (type === 'remove' && target.target != null) {
      const gap = gapOf(run, target.target);
      if (gap) payload.gap = gap;
    }
    // A finish waits for a stop, and any tap for a reopen, queued under any id of its run
    // (`waitsFor`).
    if (run.aliases.length > 0) payload.run_aliases = [...run.aliases];
    return deps.outbox.enqueue(RUN_EVENT, payload);
  });
}
