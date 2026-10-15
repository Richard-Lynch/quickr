/**
 * Page-side reactions to outbox events: optimistic cache patches when an item is
 * queued, reconciliation when the server confirms it, rollback when it fails or is
 * discarded. Events from other tabs and from the service worker (Background Sync)
 * arrive here too, so every open tab's cache stays in step.
 *
 * Seam for new kinds: add an entry to `EFFECTS` keyed by the kind name.
 */
import type { QueryClient } from '@tanstack/react-query';

import { getEntryQueryKey } from '../client/@tanstack/react-query.gen';
import { zEntryOut } from '../client/zod.gen';
import { ENTRY_CREATE, type EntryCreatePayload } from '../lib/outbox/kinds';
import type { Outbox } from '../lib/outbox/outbox';
import type { OutboxEvent, OutboxItem } from '../lib/outbox/types';
import { patchTopics, prependEntry, topicIs } from './cache';
import { invalidateOperations, invalidateEntryData } from './queryClient';

export interface KindEffects<P> {
  /** Optimistic patch (the item is already durable in IndexedDB). */
  onEnqueue?(qc: QueryClient, item: OutboxItem<P>): void;
  /** Server confirmed: reconcile with its response, then refetch what depends on it. */
  onSent?(qc: QueryClient, item: OutboxItem<P>, data: unknown): void;
  /** Terminal failure: roll back the optimistic patch (the item stays for fix/discard). */
  onFailed?(qc: QueryClient, item: OutboxItem<P>): void;
  /** Removed without being sent. `item.status` is its status before removal. */
  onDiscard?(qc: QueryClient, item: OutboxItem<P>): void;
}

function laterIso(a: string | null, b: string | null | undefined): string | null {
  if (!b) return a;
  if (!a) return b;
  return Date.parse(b) > Date.parse(a) ? b : a;
}

function bumpTopic(qc: QueryClient, item: OutboxItem<EntryCreatePayload>, delta: 1 | -1): void {
  const capturedAt = item.payload.body.captured_at ?? item.created_at;
  patchTopics(qc, topicIs(item.payload.topic), (t) => ({
    entry_count: Math.max(0, t.entry_count + delta),
    ...(delta > 0 ? { last_captured_at: laterIso(t.last_captured_at, capturedAt) } : {}),
  }));
}

const entryCreate: KindEffects<EntryCreatePayload> = {
  onEnqueue(qc, item) {
    bumpTopic(qc, item, 1);
  },
  onSent(qc, item, data) {
    const parsed = zEntryOut.safeParse(data);
    if (parsed.success) {
      prependEntry(qc, item.payload.topic, parsed.data);
      qc.setQueryData(getEntryQueryKey({ path: { entry_id: parsed.data.id } }), parsed.data);
    }
    void invalidateEntryData(qc);
  },
  onFailed(qc, item) {
    bumpTopic(qc, item, -1);
    void invalidateOperations(qc, ['listTopics', 'getTopic']);
  },
  onDiscard(qc, item) {
    if (item.status === 'pending') bumpTopic(qc, item, -1);
    void invalidateOperations(qc, ['listTopics', 'getTopic']);
  },
};

// Each kind's effects are typed against its own payload; the dispatcher only routes.
const EFFECTS: Readonly<Record<string, KindEffects<never>>> = {
  [ENTRY_CREATE]: entryCreate,
};

/** Route outbox events (local and cross-context) to per-kind cache effects. */
export function connectOutboxEffects(qc: QueryClient, outbox: Outbox): () => void {
  return outbox.subscribe((e: OutboxEvent) => {
    if (e.type === 'cleared') {
      void invalidateEntryData(qc);
      return;
    }
    const fx = EFFECTS[e.item.kind] as KindEffects<unknown> | undefined;
    if (!fx) return;
    try {
      if (e.type === 'enqueued') fx.onEnqueue?.(qc, e.item);
      else if (e.type === 'sent') fx.onSent?.(qc, e.item, e.data);
      else if (e.type === 'failed') fx.onFailed?.(qc, e.item);
      else if (e.type === 'discarded') fx.onDiscard?.(qc, e.item);
    } catch (err) {
      console.error('[outbox] cache effect failed', err);
    }
  });
}
