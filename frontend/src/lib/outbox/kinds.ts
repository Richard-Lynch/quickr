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
import type { EntryCreate } from '../../client/types.gen';
import type { OutboxItem, OutboxKind } from './types';

/** Background Sync tag registered by the page and handled in `sw.ts`. */
export const OUTBOX_SYNC_TAG = 'quickr-outbox';

export const ENTRY_CREATE = 'entry.create';

export interface EntryCreatePayload {
  /** Enough of the topic to address the request and label the item in the UI. */
  topic: { id: string; slug: string; name: string };
  /**
   * Body for `POST /topics/{ref}/entries` as the form produced it, minus `id`: the outbox
   * item's own id *is* the entry id (added at send time by `entryCreateBody`).
   */
  body: Omit<EntryCreate, 'id'>;
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
    };
  },
};

export const OUTBOX_KINDS: Readonly<Record<string, OutboxKind>> = {
  [ENTRY_CREATE]: entryCreate,
};

export function isEntryCreate(item: OutboxItem): item is OutboxItem<EntryCreatePayload> {
  return item.kind === ENTRY_CREATE;
}
