/**
 * Enqueueing run taps (timers.md §5.1, §8.2, §8.3).
 *
 * Every tap is one `run.event` outbox item. Its `at` is device now + the server offset,
 * truncated and clamped to just after the run's latest `at` in the local view, so a
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
import { stampRunEvent } from './clock';
import { formatInstant, parseInstant } from './instant';
import { isOpen, localRuns, openPauseId, openRunOf, runById, type LocalRun } from './localView';
import { serverOffset } from './serverClock';
import type { RunEventType, TimerStep } from './types';

/** Web Lock name for run taps; the service worker's Start action takes it too. */
export const RUN_TAP_LOCK = 'quickr-run-tap';

/** The run's topic and version, as the tapping screen knows them. */
export interface RunContext {
  topic: RunEventPayload['topic'];
  version: number;
  steps: TimerStep[];
  /** The version has a required question: a stop without answers leaves it finishing. */
  requires_answers: boolean;
}

export interface RunTapDeps {
  outbox: Outbox;
  /** The server's runs as last known (the cached `listRuns` answer). Read inside the lock. */
  serverRuns: () => readonly RunOut[];
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

async function view(deps: RunTapDeps): Promise<{ runs: LocalRun[]; items: OutboxItem[] }> {
  const items = await deps.outbox.list();
  return { runs: localRuns(deps.serverRuns(), items), items };
}

/** The `at` for a new event of `run`: stamped, then after every `at` it has here (§5.1). */
function stamp(deps: RunTapDeps, run: LocalRun | null, items: readonly OutboxItem[]): string {
  const ats = run ? run.events.map((e) => e.at) : [];
  if (run) {
    // Failed items too: they may be retried, and must stay in tap order.
    const ids = new Set([run.id, ...run.aliases]);
    for (const i of items) {
      if (isRunEvent(i) && ids.has(i.payload.run_id.toLowerCase()))
        ats.push(parseInstant(i.payload.event.at));
    }
  }
  const at = stampRunEvent((deps.now ?? Date.now)(), (deps.offset ?? serverOffset)(), ats);
  return formatInstant(at);
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
  return serialised(async () => {
    const { runs, items } = await view(deps);
    const open = openRunOf(runs, ctx.topic.id);
    if (open) return { runId: open.id, started: false };
    const runId = (opts.id ?? uuid()).toLowerCase();
    const event: RunEventPayload['event'] = {
      type: 'start',
      at: stamp(deps, null, items),
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
 * null when the run isn't in the local view or its state has no target for the tap. A
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
  return serialised(async () => {
    const { runs, items } = await view(deps);
    const run = runById(runs, runId);
    if (!run) return null;
    const target = targetOf(run, type);
    if (target === null) return null;
    const carries = type === 'stop' || type === 'finish';
    const event: RunEventPayload['event'] = {
      type,
      at: stamp(deps, run, items),
      ...target,
      ...(carries && body.answers != null ? { answers: body.answers } : {}),
      ...(carries && body.notes != null ? { notes: body.notes } : {}),
      ...(body.meta != null ? { meta: body.meta } : {}),
    };
    const payload = payloadOf(ctx, run.id, makesEntry(run, ctx, type, body), event);
    return deps.outbox.enqueue(RUN_EVENT, payload);
  });
}
