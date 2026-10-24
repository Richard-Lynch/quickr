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
 * (`stale`, `already_paused`, `not_paused`, §4.2). Stop, discard and finish don't use it:
 * their repeats are void (`already_closed`) or idempotent.
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

async function view(deps: RunTapDeps): Promise<{ runs: LocalRun[]; items: OutboxItem[] }> {
  const items = await deps.outbox.list();
  const acked = (await deps.acked?.()) ?? [];
  return { runs: localRuns(deps.serverRuns(), items, acked), items };
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
  ctx: RunContext,
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
 * Start a run of `ctx.topic`, unless the local view already has an open run for it: then
 * the tap routes to that run and nothing is enqueued (§4.5). `id` is the run id (a
 * reminder's Start derives it from the slot, §10.1); a new one by default.
 */
export function startRun(
  deps: RunTapDeps,
  ctx: RunContext,
  opts: { id?: string; source?: string; meta?: Record<string, string> } = {},
): Promise<StartResult> {
  const tapAt = tapTime(deps);
  return serialised(async () => {
    const { runs, items } = await view(deps);
    const open = openRunOf(runs, ctx.topic.id);
    if (open) return { runId: open.id, started: false };
    const runId = (opts.id ?? uuid()).toLowerCase();
    const event: RunEventPayload['event'] = {
      type: 'start',
      at: stamp(tapAt, null, items),
      topic_id: ctx.topic.id,
      version: ctx.version,
      ...(opts.source !== undefined ? { source: opts.source } : {}),
      ...(opts.meta !== undefined ? { meta: opts.meta } : {}),
    };
    await deps.outbox.enqueue(RUN_EVENT, payloadOf(ctx, runId, false, event), { id: runId });
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
  opts: { expect?: TapExpect } = {},
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
    if (!run) {
      // A stopped run leaves the view once `listRuns` no longer lists it, but its answers
      // can still come (§3.6): the server decides a finish, so send it to the run id.
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
    const target = targetOf(run, type);
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
    return deps.outbox.enqueue(RUN_EVENT, payload);
  });
}
