/**
 * Recording entries through the durable outbox.
 *
 * The item is written to IndexedDB *before* any network traffic, so an entry is never
 * lost to a dead connection, a killed app or a reload. Online, we wait briefly for the
 * server so validation errors can still be shown on the form; offline (or slow), the
 * form resets at once and the outbox syncs in the background.
 */
import { useCallback } from 'react';

import type { SessionCreate, SessionOut } from '../client';
import { zSessionOut } from '../client/zod.gen';
import { isOnline, outbox } from '../lib/outbox/client';
import { ENTRY_CREATE, type EntryCreatePayload } from '../lib/outbox/kinds';
import type { OutboxItem } from '../lib/outbox/types';

/** How long the record screen waits for the server before saying "saved on device". */
export const RECORD_WAIT_MS = 5_000;

export type RecordResult =
  | { status: 'sent'; session: SessionOut | null }
  | { status: 'queued'; itemId: string }
  /** Rejected by the server (4xx). `error` is the Problem body when there is one. */
  | { status: 'failed'; error: unknown; itemId: string };

function errorOf(item: OutboxItem): unknown {
  return item.last_error?.body ?? new Error(item.last_error?.message ?? 'Request failed');
}

export interface RecordOptions {
  /** Re-submit an existing outbox item (the "fix" flow) instead of creating a new one. */
  fixItemId?: string | undefined;
  waitMs?: number;
}

export function useRecordEntry() {
  return useCallback(
    async (
      topic: EntryCreatePayload['topic'],
      body: SessionCreate,
      { fixItemId, waitMs = RECORD_WAIT_MS }: RecordOptions = {},
    ): Promise<RecordResult> => {
      const payload: EntryCreatePayload = { topic, body };
      let item: OutboxItem<EntryCreatePayload> | undefined;
      if (fixItemId) item = await outbox.update(fixItemId, payload);
      item ??= await outbox.enqueue(ENTRY_CREATE, payload);

      // Offline: don't burn an attempt; the `online` trigger / Background Sync sends it.
      if (!isOnline()) {
        return { status: 'queued', itemId: item.id };
      }
      const r = await outbox.sendNow(item.id, waitMs);
      switch (r.status) {
        case 'sent': {
          const parsed = zSessionOut.safeParse(r.data);
          return { status: 'sent', session: parsed.success ? parsed.data : null };
        }
        case 'failed':
          // A brand-new entry the user is still looking at: hand the errors back to the
          // form and drop the queued copy. A fix keeps its item (discard is explicit).
          if (!fixItemId) await outbox.discard(item.id);
          return { status: 'failed', error: errorOf(r.item), itemId: item.id };
        case 'discarded':
        case 'queued':
          return { status: 'queued', itemId: item.id };
      }
    },
    [],
  );
}
