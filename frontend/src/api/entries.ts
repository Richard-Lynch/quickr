/**
 * Recording entries through the durable outbox.
 *
 * The item is written to IndexedDB *before* any network traffic, so an entry is never
 * lost to a dead connection, a killed app or a reload. Online, we wait briefly for the
 * server so validation errors can still be shown on the form; offline (or slow), the
 * form resets at once and the outbox syncs in the background.
 *
 * The outbox item id doubles as the entry id (sent as `id`, creation is idempotent), so
 * an entry can be addressed — undone, opened — before the server has even seen it.
 */
import type { EntryOut } from '../client';
import { listEntriesOptions } from '../client/@tanstack/react-query.gen';
import { zEntryCreate, zEntryOut } from '../client/zod.gen';
import { isOnline, outbox } from '../lib/outbox/client';
import { ENTRY_CREATE, type EntryCreatePayload } from '../lib/outbox/kinds';
import type { OutboxItem } from '../lib/outbox/types';

/** How long the record screen waits for the server before saying "saved on device". */
export const RECORD_WAIT_MS = 5_000;

export type RecordResult =
  | { status: 'sent'; entry: EntryOut | null; itemId: string }
  | { status: 'queued'; itemId: string }
  /** Rejected by the server (4xx). `error` is the Problem body when there is one. */
  | { status: 'failed'; error: unknown; itemId: string };

function errorOf(item: OutboxItem): unknown {
  return item.last_error?.body ?? new Error(item.last_error?.message ?? 'Request failed');
}

export interface RecordOptions {
  /** Re-submit an existing outbox item (the "fix" flow) instead of creating a new one. */
  fixItemId?: string | undefined;
  /** Use this id for the new entry (default: a fresh UUID). */
  id?: string | undefined;
  waitMs?: number;
  /** Keep a rejected brand-new item in the outbox instead of discarding it. */
  keepFailed?: boolean;
}

/**
 * Queue an entry and (online) try to send it right away.
 * Throws a `ZodError` when the body doesn't match the generated `EntryCreate` schema —
 * nothing is queued then.
 */
export async function recordEntry(
  topic: EntryCreatePayload['topic'],
  body: EntryCreatePayload['body'],
  { fixItemId, id, waitMs = RECORD_WAIT_MS, keepFailed = false }: RecordOptions = {},
): Promise<RecordResult> {
  // Final check against the OpenAPI contract before anything becomes durable.
  zEntryCreate.parse(body);
  const payload: EntryCreatePayload = { topic, body };
  let item: OutboxItem<EntryCreatePayload> | undefined;
  if (fixItemId) item = await outbox.update(fixItemId, payload);
  item ??= await outbox.enqueue(ENTRY_CREATE, payload, id ? { id } : undefined);

  // Offline: don't burn an attempt; the `online` trigger / Background Sync sends it.
  if (!isOnline()) {
    return { status: 'queued', itemId: item.id };
  }
  const r = await outbox.sendNow(item.id, waitMs);
  switch (r.status) {
    case 'sent': {
      const parsed = zEntryOut.safeParse(r.data);
      return { status: 'sent', entry: parsed.success ? parsed.data : null, itemId: item.id };
    }
    case 'failed':
      // A brand-new entry the user is still looking at: hand the errors back to the
      // form and drop the queued copy. A fix keeps its item (discard is explicit).
      if (!fixItemId && !keepFailed) await outbox.discard(item.id);
      return { status: 'failed', error: errorOf(r.item), itemId: item.id };
    case 'discarded':
    case 'queued':
      return { status: 'queued', itemId: item.id };
  }
}

/** The latest entry of a topic (tiles' "Last …", number prefill, "Same as last time"). */
export function lastEntryOptions(slug: string) {
  return listEntriesOptions({ path: { ref: slug }, query: { limit: 1, order: '-captured_at' } });
}

/** Hook form for components (the function is stable; no React state involved). */
export function useRecordEntry(): typeof recordEntry {
  return recordEntry;
}
