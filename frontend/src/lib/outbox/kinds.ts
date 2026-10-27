/**
 * Outbox item kinds: how each queued mutation becomes an HTTP request.
 *
 * Shared by the page and the service worker (Background Sync), so keep it pure:
 * no React, no `window`, no generated SDK (only its types).
 *
 * Adding a kind (e.g. `entry.update`, `entry.delete`):
 *  1. add a payload type + `toRequest` here (and `classify` if a status means "done",
 *     e.g. 404 on delete, or "retired", e.g. 409 `entry_deleted` on create),
 *  2. add cache effects in `src/api/outboxEffects.ts` (optimistic patch / reconcile),
 *  3. enqueue it with `useOutbox().enqueue(kind, payload)`.
 */
import { API_PREFIX } from '../../api/constants';
import type { EntryCreate, RunEventIn, RunEventResult, RunOut } from '../../client/types.gen';
import { recordAcked } from '../runs/acked';
import { parseInstant } from '../runs/instant';
import type { TimerStep } from '../runs/types';
import { classifyStatus, errorMessageFor } from './classify';
import type { OutboxError, OutboxItem, OutboxKind } from './types';

/** Background Sync tag registered by the page and handled in `sw.ts`. */
export const OUTBOX_SYNC_TAG = 'quickr-outbox';

export const ENTRY_CREATE = 'entry.create';
export const RUN_EVENT = 'run.event';

/** The F10 identity precondition (docs/ios/specs/sync-protocol.md §1.3). */
export const EXPECT_SERVER_ID_HEADER = 'X-QuickR-Expect-Server-Id';

export interface EntryCreatePayload {
  /** Enough of the topic to address the request and label the item in the UI. */
  topic: { id: string; slug: string; name: string };
  /**
   * Body for `POST /topics/{ref}/entries` as the form produced it, minus `id`: the outbox
   * item's own id *is* the entry id (added at send time by `entryCreateBody`).
   */
  body: Omit<EntryCreate, 'id'>;
  /**
   * The server the entry is meant for (a notification action's `server_id`). Sent as the
   * `X-QuickR-Expect-Server-Id` precondition, so if this origin now serves another quickR
   * server the create is refused (409 `server_mismatch`) and nothing is written.
   */
  expect_server_id?: string;
}

/** The body actually sent. The client id makes creation idempotent. */
export function entryCreateBody(item: OutboxItem<EntryCreatePayload>): EntryCreate {
  return { ...item.payload.body, id: item.id };
}

/** The `code` of a `Problem` error body, if `body` is one. */
export function problemCode(body: unknown): string | undefined {
  if (typeof body !== 'object' || body === null || !('code' in body)) return undefined;
  return typeof body.code === 'string' ? body.code : undefined;
}

const entryCreate: OutboxKind<EntryCreatePayload> = {
  /**
   * 409 `entry_deleted`: the id was deleted (e.g. undone on another device, or this send
   * lost a race with its own undo). The entry must never appear: retire the item.
   */
  classify(status, body) {
    return status === 409 && problemCode(body) === 'entry_deleted' ? 'retired' : undefined;
  },
  toRequest(item: OutboxItem<EntryCreatePayload>) {
    return {
      method: 'POST',
      // Address the topic by id: survives a slug rename while the item waits offline.
      url: `${API_PREFIX}/topics/${encodeURIComponent(item.payload.topic.id)}/entries`,
      // A retry after a lost response returns the stored entry (201), never a duplicate.
      body: entryCreateBody(item),
      ...(item.payload.expect_server_id
        ? { headers: { [EXPECT_SERVER_ID_HEADER]: item.payload.expect_server_id } }
        : {}),
    };
  },
};

export interface RunEventPayload {
  /** Enough of the topic to label the item and its notices. */
  topic: { id: string; slug: string; name: string };
  /** The run the event is for (lowercase): its start's id, or an id the server answered. */
  run_id: string;
  /**
   * The run's version, its steps, and whether it has a required question, as the device
   * knew them at the tap: the local view folds queued events over these steps
   * (timers.md §8.3), and a stop without answers leaves such a run finishing (§3.5). Null
   * when the device didn't know them (a reminder's Start with nothing cached, §10.2): the
   * local view then takes them from another of the run's items, or defers to the server.
   */
  version: number;
  steps: TimerStep[] | null;
  requires_answers: boolean | null;
  /**
   * The tap makes the run's entry: a stop that won't leave the run finishing, or a finish
   * of a finishing run. Its entry is projected optimistically until the server answers.
   */
  makes_entry: boolean;
  /** Body for `POST /runs/{run_id}/events` minus `id`: the item id *is* the event id. */
  event: Omit<RunEventIn, 'id'>;
  /**
   * A finish: the other run ids that routed to its run in the local view at the tap (its
   * aliases), so it also waits for a stop queued under one of them ({@link waitsFor}).
   */
  run_aliases?: string[];
  /**
   * The server a reminder's Start came from (`X-QuickR-Expect-Server-Id`, as for
   * `entry.create`): another server refuses it with 409 `server_mismatch`.
   */
  expect_server_id?: string;
}

const runEvent: OutboxKind<RunEventPayload> = {
  /**
   * 409 `run_deleted`: the run's topic was deleted; nothing can come of it (timers.md §8.1).
   * Everything else, a 404 included, is the default classification. That includes 409
   * `run_open` on a finish: it is sent only once this device's stop is in ({@link
   * waitsFor}), so the run has no stop the server knows of (none was tapped here, or it
   * failed or was discarded). It fails with its answers kept, for the user to fix.
   */
  classify(status, body) {
    return status === 409 && problemCode(body) === 'run_deleted' ? 'retired' : undefined;
  },
  /**
   * The ordering rule (§8.2): an event waits for its run's start, pending or failed. A
   * finish also waits for its run's pending stops, those queued under an alias of its run
   * included, so it doesn't reach the server before them (a failed stop doesn't hold it:
   * the finish goes, and fails on `run_open`).
   *
   * A start waits for the pending stops and discards of the topic's other runs enqueued
   * before it (§8.1): the local view has that run closed, but the server, still having it
   * open, would merge the new run into it. A failed one doesn't hold it: the start goes,
   * and the server merges it if the run is still open there. So does a close of a run whose
   * start failed.
   */
  waitsFor(item, queue) {
    const { event, run_id: runId } = item.payload;
    if (event.type === 'start') {
      // A run whose start failed isn't open on the server: its close (held by that start
      // until it is retried or discarded) doesn't hold another run's start.
      const failedStart = (id: string) => queue.some((i) => i.id === id && i.status === 'failed');
      const closes = queue.filter(
        (i) =>
          isRunEvent(i) &&
          i.payload.topic.id === item.payload.topic.id &&
          i.payload.run_id !== runId &&
          (i.payload.event.type === 'stop' || i.payload.event.type === 'discard') &&
          i.status === 'pending' &&
          !failedStart(i.payload.run_id) &&
          enqueuedBefore(i, item),
      );
      return closes.map((i) => i.id);
    }
    if (event.type !== 'finish') return [runId];
    const ids = new Set([runId, ...(item.payload.run_aliases ?? [])].map((id) => id.toLowerCase()));
    const stops = queue.filter(
      (i) =>
        isRunEvent(i) &&
        ids.has(i.payload.run_id.toLowerCase()) &&
        i.payload.event.type === 'stop' &&
        i.status === 'pending',
    );
    return [runId, ...stops.map((i) => i.id)];
  },
  /** A run's events can't be sent without its start (§8.1): they go when it is discarded. */
  discardedWith(item) {
    return item.payload.event.type === 'start' ? [] : [item.payload.run_id];
  },
  /**
   * Taps within one millisecond go out in tap order: their `at`s are clamped (§5.1). As
   * zero-padded epoch ms: wire strings don't sort (`…00Z` comes after `…00.001000Z`).
   */
  orderKey(item) {
    try {
      return String(parseInstant(item.payload.event.at)).padStart(16, '0');
    } catch {
      return '';
    }
  },
  /** Only a discard can coalesce (K6); no other tap waits for a flush in progress. */
  coalesces(item) {
    return item.payload.event.type === 'discard';
  },
  /**
   * A start refused with 409 `event_conflict` or `id_conflict`: the server already has its
   * id, e.g. the same reminder started on another device first (timers.md §8.1, §10.2). Read
   * the run with that id (an alias resolves), and for `id_conflict` the entry with it too:
   * - a run of the start's topic: started elsewhere. Ack with that run, as a merged start
   *   would be (its id an alias when the run is another's); the run's queued taps go to it.
   * - an entry of the start's topic: already logged. Retire the start, and fail the run's
   *   other taps (nothing to send them to) with that reason, not one by one on 404.
   * - nothing, or another topic's: the refusal stands (`failed/rejected`).
   * A read that can be retried retries the start (it didn't execute); another 4xx fails it.
   */
  async verify(item, refusal, { read, queue }) {
    const { event, run_id: runId, topic } = item.payload;
    const code = problemCode(refusal.body);
    if (event.type !== 'start' || refusal.status !== 409) return undefined;
    if (code !== 'event_conflict' && code !== 'id_conflict') return undefined;
    const id = encodeURIComponent(runId);
    const reads = [`${API_PREFIX}/runs/${id}`];
    if (code === 'id_conflict') reads.push(`${API_PREFIX}/entries/${id}`);
    const { headers } = runEvent.toRequest(item);
    for (const [i, url] of reads.entries()) {
      const res = await read(url, headers);
      if (res.status === 404) continue;
      const error: OutboxError = {
        message: errorMessageFor(res.status, res.body),
        status: res.status,
        ...(res.body !== undefined ? { body: res.body } : {}),
      };
      const outcome = res.status === null ? 'retry' : classifyStatus(res.status);
      if (outcome !== 'ok') return { outcome, error };
      if (!ofTopic(res.body, topic.id)) continue;
      if (i === 0) return { outcome: 'ok', data: knownStart(item, res.body as RunOut) };
      // Listed after the reads, so the outbox can skip a tap changed meanwhile.
      const taps = (await queue()).filter((q) => isRunEvent(q) && q.payload.run_id === runId);
      return {
        outcome: 'retired',
        error: { ...refusal, message: ALREADY_LOGGED },
        fail: { items: taps, error: { ...refusal, message: ALREADY_LOGGED } },
      };
    }
    return undefined;
  },
  /**
   * Keep the event in the local view until `listRuns` has it (`lib/runs/acked.ts`). Not a
   * start whose run the server has closed already (a start known elsewhere, §8.1): on its
   * own it would fold to an open run, holding off the next Start and the topic's due state.
   */
  onAck(item, data) {
    if (item.payload.event.type === 'start' && closedRun(data)) return Promise.resolve();
    return recordAcked(item);
  },
  /**
   * K6 (§8.1): a discard of a run the server never saw (its start and every event still
   * pending and never attempted) drops all of them, and the discard isn't stored.
   */
  coalesce(item, queue) {
    if (item.payload.event.type !== 'discard') return undefined;
    const runId = item.payload.run_id;
    const ofRun = queue.filter((i) => isRunEvent(i) && i.payload.run_id === runId);
    const unsent = ofRun.every((i) => i.status === 'pending' && i.attempts === 0);
    if (!unsent || !ofRun.some((i) => i.id === runId)) return undefined;
    return { drop: ofRun.map((i) => i.id), store: false };
  },
  toRequest(item) {
    return {
      method: 'POST',
      url: `${API_PREFIX}/runs/${encodeURIComponent(item.payload.run_id)}/events`,
      // Idempotent by event id: a retry after a lost response is a replay (§3.2).
      body: { ...item.payload.event, id: item.id } satisfies RunEventIn,
      ...(item.payload.expect_server_id
        ? { headers: { [EXPECT_SERVER_ID_HEADER]: item.payload.expect_server_id } }
        : {}),
    };
  },
};

/** Why a start's run's taps fail once its id turns out to be an entry of its topic. */
export const ALREADY_LOGGED = 'Already logged elsewhere';

/** Whether `data` is a `RunEventResult` whose run is closed (`stopped`, `discarded`). */
function closedRun(data: unknown): boolean {
  if (typeof data !== 'object' || data === null || !('run' in data)) return false;
  const run = data.run;
  if (typeof run !== 'object' || run === null || !('status' in run)) return false;
  return run.status === 'stopped' || run.status === 'discarded';
}

/** Whether `body` is a run or entry (a `topic_id`) of the topic `topicId`. */
function ofTopic(body: unknown, topicId: string): boolean {
  if (typeof body !== 'object' || body === null || !('topic_id' in body)) return false;
  return typeof body.topic_id === 'string' && body.topic_id.toLowerCase() === topicId.toLowerCase();
}

/**
 * The `RunEventResult` a start the server already has would get: its effect in the run's
 * state (void `merged` when the run doesn't list it), and the start's id among the
 * aliases when the run is another's.
 */
function knownStart(item: OutboxItem<RunEventPayload>, run: RunOut): RunEventResult {
  const runId = item.payload.run_id.toLowerCase();
  const id = item.id.toLowerCase();
  const effect = Object.entries(run.state.effects).find(([k]) => k.toLowerCase() === id)?.[1] ?? {
    effect: 'void',
    reason: 'merged',
  };
  const aliases = run.aliases.map((a) => a.toLowerCase());
  const alias = run.id.toLowerCase() !== runId && !aliases.includes(runId);
  return {
    event: { id: item.id, ...effect },
    run: alias ? { ...run, aliases: [...run.aliases, runId] } : run,
    entry: null,
  };
}

/** Whether `a` was enqueued before `b`, as the outbox orders them (`created_at`, the `at`, the id). */
function enqueuedBefore(a: OutboxItem<RunEventPayload>, b: OutboxItem<RunEventPayload>): boolean {
  const key = (i: OutboxItem<RunEventPayload>) => runEvent.orderKey?.(i) ?? '';
  return (
    (a.created_at.localeCompare(b.created_at) ||
      key(a).localeCompare(key(b)) ||
      a.id.localeCompare(b.id)) < 0
  );
}

export const OUTBOX_KINDS: Readonly<Record<string, OutboxKind>> = {
  [ENTRY_CREATE]: entryCreate,
  [RUN_EVENT]: runEvent,
};

export function isEntryCreate(item: OutboxItem): item is OutboxItem<EntryCreatePayload> {
  return item.kind === ENTRY_CREATE;
}

export function isRunEvent(item: OutboxItem): item is OutboxItem<RunEventPayload> {
  return item.kind === RUN_EVENT;
}

/** A run event that carries answers: a finish, or a stop with answers. */
export function carriesAnswers(item: OutboxItem<RunEventPayload>): boolean {
  const e = item.payload.event;
  return e.type === 'finish' || (e.type === 'stop' && e.answers != null);
}

/**
 * Whether a failed answers event offers Fix (the answers form, timers.md §8.1): only a 422,
 * and only when no attempt may have reached the server (it may already hold the answers).
 */
export function answersFixable(item: OutboxItem<RunEventPayload>): boolean {
  return (
    item.status === 'failed' &&
    carriesAnswers(item) &&
    item.last_error?.status === 422 &&
    !item.maybe_delivered
  );
}
