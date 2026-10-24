/**
 * Page-side reactions to outbox events: optimistic cache patches when an item is
 * queued, reconciliation when the server confirms it, rollback when it fails or is
 * discarded. Events from other tabs and from the service worker (Background Sync)
 * arrive here too, so every open tab's cache stays in step.
 *
 * Seam for new kinds: add an entry to `EFFECTS` keyed by the kind name.
 */
import type { QueryClient } from '@tanstack/react-query';

import type { TopicSummary } from '../client';
import { getEntryQueryKey } from '../client/@tanstack/react-query.gen';
import { zEntryOut, zRunEventResult } from '../client/zod.gen';
import {
  ENTRY_CREATE,
  RUN_EVENT,
  type EntryCreatePayload,
  type RunEventPayload,
} from '../lib/outbox/kinds';
import type { Outbox } from '../lib/outbox/outbox';
import { noticeFor, pushRunNotice } from '../lib/runs/notices';
import { dueAfterLogging } from '../lib/schedule';
import type { OutboxEvent, OutboxItem } from '../lib/outbox/types';
import { patchEntries, patchTopics, prependEntry, topicIs } from './cache';
import { invalidateOperations, invalidateEntryData } from './queryClient';
import { upsertServerRun } from './runs';

export interface KindEffects<P> {
  /** Optimistic patch (the item is already durable in IndexedDB). */
  onEnqueue?(qc: QueryClient, item: OutboxItem<P>): void;
  /** Server confirmed: reconcile with its response, then refetch what depends on it. */
  onSent?(qc: QueryClient, item: OutboxItem<P>, data: unknown): void;
  /** Terminal failure: roll back the optimistic patch (the item stays for fix/discard). */
  onFailed?(qc: QueryClient, item: OutboxItem<P>): void;
  /** Removed without being sent. `item.status` is its status before removal. */
  onDiscard?(qc: QueryClient, item: OutboxItem<P>): void;
  /** The server says it can never happen (e.g. `entry_deleted`): undo the optimistic patch. */
  onRetired?(qc: QueryClient, item: OutboxItem<P>): void;
}

function laterIso(a: string | null, b: string | null | undefined): string | null {
  if (!b) return a;
  if (!a) return b;
  return Date.parse(b) > Date.parse(a) ? b : a;
}

/**
 * Whether an entry captured at `at` plausibly satisfies the open slot. The server allows
 * logging up to 2 h early; a back-dated entry from before the slot doesn't count.
 */
function satisfiesDue(due: TopicSummary['due'], at: string): boolean {
  if (!due?.is_due) return false;
  if (!due.due_since) return true;
  return Date.parse(at) >= Date.parse(due.due_since) - 2 * 60 * 60_000;
}

function bumpTopic(qc: QueryClient, item: OutboxItem<EntryCreatePayload>, delta: 1 | -1): void {
  bumpTopicFor(qc, item.payload.topic, item.payload.body.captured_at ?? item.created_at, delta);
}

/** Count (or un-count) one entry captured at `capturedAt` on the topic's cached summaries. */
function bumpTopicFor(
  qc: QueryClient,
  topic: { id: string; slug: string },
  capturedAt: string,
  delta: 1 | -1,
): void {
  patchTopics(qc, topicIs(topic), (t) => ({
    entry_count: Math.max(0, t.entry_count + delta),
    ...(delta > 0
      ? {
          last_captured_at: laterIso(t.last_captured_at, capturedAt),
          // Logging a due topic drops it out of "Due now" at once; the refetch after the
          // send brings the server's own due status (next slot etc.).
          ...(satisfiesDue(t.due, capturedAt) ? { due: dueAfterLogging(t.due, capturedAt) } : {}),
        }
      : {}),
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
  onRetired(qc, item) {
    // Deleted on the server: never let it materialise, even from a stale cache.
    bumpTopic(qc, item, -1);
    patchEntries(qc, (e) => (e.id === item.id ? null : e));
    qc.removeQueries({ queryKey: getEntryQueryKey({ path: { entry_id: item.id } }) });
    void invalidateEntryData(qc);
  },
};

/**
 * A tap that makes the run's entry (`makes_entry`) counts it on the topic at once, as
 * `entry.create` does: due state and the badge update offline too (timers.md §8.3). The
 * captured time is the tap's; the server's entry (`captured_at` = the stop) replaces it.
 */
function bumpRun(qc: QueryClient, item: OutboxItem<RunEventPayload>, delta: 1 | -1): void {
  if (item.payload.makes_entry) bumpTopicFor(qc, item.payload.topic, item.payload.event.at, delta);
}

const runEvent: KindEffects<RunEventPayload> = {
  onEnqueue(qc, item) {
    bumpRun(qc, item, 1);
  },
  onSent(qc, item, data) {
    const parsed = zRunEventResult.safeParse(data);
    if (!parsed.success) {
      void invalidateOperations(qc, ['listRuns']);
      return;
    }
    const { run, entry } = parsed.data;
    upsertServerRun(qc, run);
    // A void tap the user should hear about (§11.4).
    const notice = noticeFor(item, parsed.data);
    if (notice) pushRunNotice(notice);
    if (entry) {
      prependEntry(qc, item.payload.topic, entry);
      qc.setQueryData(getEntryQueryKey({ path: { entry_id: entry.id } }), entry);
    }
    if (entry || item.payload.makes_entry) void invalidateEntryData(qc);
  },
  onFailed(qc, item) {
    bumpRun(qc, item, -1);
    // A 404 means the run is gone elsewhere: pull (§8.1).
    void invalidateOperations(qc, ['listRuns', 'listTopics', 'getTopic']);
  },
  onDiscard(qc, item) {
    if (item.status === 'pending') bumpRun(qc, item, -1);
    void invalidateOperations(qc, ['listRuns', 'listTopics', 'getTopic']);
  },
  onRetired(qc, item) {
    // 409 `run_deleted`: retire and pull (§8.1).
    bumpRun(qc, item, -1);
    void invalidateOperations(qc, ['listRuns']);
    void invalidateEntryData(qc);
  },
};

// Each kind's effects are typed against its own payload; the dispatcher only routes.
const EFFECTS: Readonly<Record<string, KindEffects<never>>> = {
  [ENTRY_CREATE]: entryCreate,
  [RUN_EVENT]: runEvent,
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
      else if (e.type === 'retired') fx.onRetired?.(qc, e.item);
    } catch (err) {
      console.error('[outbox] cache effect failed', err);
    }
  });
}
