/**
 * Outbox item kinds: how each queued mutation becomes an HTTP request.
 *
 * Shared by the page and the service worker (Background Sync), so keep it pure:
 * no React, no `window`, no generated SDK (only its types).
 *
 * Adding a kind (e.g. `entry.update`, `entry.delete`):
 *  1. add a payload type + `toRequest` here (and `classify` if a status means "done",
 *     e.g. 404 on delete),
 *  2. add cache effects in `src/api/outboxEffects.ts` (optimistic patch / reconcile),
 *  3. enqueue it with `useOutbox().enqueue(kind, payload)`.
 */
import { API_PREFIX } from '../../api/constants';
import type { SessionCreate } from '../../client/types.gen';
import type { OutboxItem, OutboxKind } from './types';

/** Background Sync tag registered by the page and handled in `sw.ts`. */
export const OUTBOX_SYNC_TAG = 'quickr-outbox';

export const ENTRY_CREATE = 'entry.create';

export interface EntryCreatePayload {
  /** Enough of the topic to address the request and label the item in the UI. */
  topic: { id: string; slug: string; name: string };
  /** Body for the create endpoint, exactly as the form produced it. */
  body: SessionCreate;
}

const entryCreate: OutboxKind<EntryCreatePayload> = {
  toRequest(item: OutboxItem<EntryCreatePayload>) {
    const { topic, body } = item.payload;
    return {
      method: 'POST',
      // Address the topic by id: survives a slug rename while the item waits offline.
      // TODO(api-v2): switch to `POST /api/v1/topics/{ref}/entries` and send
      //   `{ id: item.id, ...body }` so creation is idempotent by the client id (retries
      //   after a lost response can then never duplicate). The current SessionCreate
      //   model is `extra=forbid`, so the id must NOT be sent until the backend ships it.
      url: `${API_PREFIX}/topics/${encodeURIComponent(topic.id)}/sessions`,
      body,
    };
  },
};

export const OUTBOX_KINDS: Readonly<Record<string, OutboxKind>> = {
  [ENTRY_CREATE]: entryCreate,
};

export function isEntryCreate(item: OutboxItem): item is OutboxItem<EntryCreatePayload> {
  return item.kind === ENTRY_CREATE;
}
