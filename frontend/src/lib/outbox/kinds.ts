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
import type { EntryCreate, RunEventIn } from '../../client/types.gen';
import type { TimerStep } from '../runs/types';
import type { OutboxItem, OutboxKind } from './types';

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
   * (timers.md §8.3), and a stop without answers leaves such a run finishing (§3.5).
   */
  version: number;
  steps: TimerStep[];
  requires_answers: boolean;
  /**
   * The tap makes the run's entry: a stop that won't leave the run finishing, or a finish
   * of a finishing run. Its entry is projected optimistically until the server answers.
   */
  makes_entry: boolean;
  /** Body for `POST /runs/{run_id}/events` minus `id`: the item id *is* the event id. */
  event: Omit<RunEventIn, 'id'>;
}

const runEvent: OutboxKind<RunEventPayload> = {
  /**
   * 409 `run_deleted`: the run's topic was deleted; nothing can come of it (timers.md §8.1).
   * 409 `run_open` on a finish: this device's stop isn't in yet; keep the answers and send
   * them again (§3.6). Everything else, a 404 included, is the default classification.
   */
  classify(status, body, item) {
    if (status !== 409) return undefined;
    const code = problemCode(body);
    if (code === 'run_deleted') return 'retired';
    if (code === 'run_open' && item.payload.event.type === 'finish') return 'retry';
    return undefined;
  },
  /** The one ordering rule (§8.2): an event waits for its run's start, nothing else. */
  waitsFor(item) {
    return item.payload.event.type === 'start' ? [] : [item.payload.run_id];
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
    };
  },
};

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
