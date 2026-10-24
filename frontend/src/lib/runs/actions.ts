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
import { formatInstant, parseInstant } from './instant';
import { isOpen, localRuns, openPauseId, openRunOf, runById, type LocalRun } from './localView';
import { serverOffset } from './serverClock';
import type { RunEventType, TimerStep } from './types';

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
  /** That version's steps. */
  steps: TimerStep[];
  /** The version has a required question: a stop without answers leaves it finishing. */
  requires_answers: boolean;
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
  /** Device time, epoch ms. */
  now?: () => number;
  /** The server-time offset (`serverClock.ts`). */
  offset?: () => number;
}

export type TapType = Exclude<RunEventType, 'start'>;

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
  ctx: StartContext,
  runId: string,
  makesEntry: boolean,
  event: RunEventPayload['event'],
): RunEventPayload {
  return {
    topic: ctx.topic,
    run_id: runId.toLowerCase(),
    version: ctx.version,
    steps: ctx.steps,
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
 * this device already knows (an item, an acked event or a run with it) was already
 * started: nothing is enqueued either.
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
    if (opts.id !== undefined && (items.some(known) || acked.some(known) || runById(runs, runId))) {
      return { runId, started: false };
    }
    const open = opts.reminder
      ? pendingOpenRun(items, ctx.topic.id)
      : (openRunOf(runs, ctx.topic.id)?.id ?? null);
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
 * step left to skip; no pause to resume; a finish of a run that isn't stopped.
 */
function targetOf(run: LocalRun, type: TapType): Partial<RunEventIn> | null {
  const open = run.state.open;
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
  }
}

/** Whether the tap makes the run's entry (`RunEventPayload.makes_entry`). */
function makesEntry(run: LocalRun, ctx: RunContext, type: TapType, body: TapBody): boolean {
  if (type === 'finish') return run.status === 'finishing';
  if (type === 'stop') return body.answers != null || !ctx.requires_answers;
  return false;
}

/**
 * Enqueue one tap on the run `runId` routes to (its id or an alias). Returns the item, or
 * null when the run isn't in the local view (after one `refresh`) or its state has no
 * target for the tap. Throws when `ctx` is for another version than the run's. A
 * discard of a run the server never saw drops the run's items instead (K6): the item is
 * returned but not stored.
 */
export function tapRun(
  deps: RunTapDeps,
  runId: string,
  ctx: RunContext,
  type: TapType,
  body: TapBody = {},
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
    if (!run) return null;
    if (run.version !== ctx.version) {
      throw new Error(`run ${run.id} is pinned to version ${run.version}, not ${ctx.version}`);
    }
    const target = targetOf(run, type);
    if (target === null) return null;
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
    return deps.outbox.enqueue(RUN_EVENT, payload);
  });
}
