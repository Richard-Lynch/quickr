/**
 * Acked run events: a short-lived record of the `run.event` items the server accepted
 * (timers.md §8.3).
 *
 * Once an item is acked it leaves the outbox, but the cached `listRuns` answer may not
 * have the run yet: the response could not be read, the service worker sent it with no
 * page open, or a list fetched before the ack lands afterwards. Without this record the
 * run would drop out of the local view for a while, and a tap could be lost or a second
 * start enqueued. The outbox writes the record before it deletes the item (the kind's
 * `onAck`), and the local view folds these events in until a `listRuns` fetch that began
 * after the ack has answered.
 *
 * IndexedDB (no `window`), so the service worker writes it too.
 */
import { clear, createStore, del, entries, set, type UseStore } from 'idb-keyval';

import type { RunEventPayload } from '../outbox/kinds';
import type { OutboxItem } from '../outbox/types';

export interface AckedRunEvent {
  item: OutboxItem<RunEventPayload>;
  /** Device epoch ms of the ack. */
  acked_at: number;
}

/** Kept at most this long, whatever `listRuns` does. */
export const ACKED_MAX_AGE_MS = 10 * 60_000;

export interface AckedStore {
  all(): Promise<AckedRunEvent[]>;
  put(record: AckedRunEvent): Promise<void>;
  delete(id: string): Promise<void>;
  clear(): Promise<void>;
}

export function idbAckedStore(dbName = 'quickr-runs-acked', storeName = 'items'): AckedStore {
  let store: UseStore | null = null;
  const s = () => (store ??= createStore(dbName, storeName));
  return {
    all: async () => (await entries<string, AckedRunEvent>(s())).map(([, v]) => v),
    put: (r) => set(r.item.id, r, s()),
    delete: (id) => del(id, s()),
    clear: () => clear(s()),
  };
}

export function memoryAckedStore(): AckedStore {
  const map = new Map<string, AckedRunEvent>();
  return {
    all: () => Promise.resolve([...map.values()].map((r) => structuredClone(r))),
    put: (r) => {
      map.set(r.item.id, structuredClone(r));
      return Promise.resolve();
    },
    delete: (id) => {
      map.delete(id);
      return Promise.resolve();
    },
    clear: () => {
      map.clear();
      return Promise.resolve();
    },
  };
}

let store: AckedStore = idbAckedStore();

/** Tests: use another store (and forget the snapshot). */
export function setAckedStore(next: AckedStore): void {
  store = next;
  snapshot = [];
}

export async function recordAcked(
  item: OutboxItem<RunEventPayload>,
  now: number = Date.now(),
): Promise<void> {
  await store.put({ item, acked_at: now });
}

/**
 * Forget what a `listRuns` answer covers: records acked before `fetchStartedAt` (the
 * fetch began after them, so the server's list includes them), and any older than
 * {@link ACKED_MAX_AGE_MS}.
 */
export async function pruneAcked(fetchStartedAt: number, now: number = Date.now()): Promise<void> {
  for (const r of await store.all()) {
    if (r.acked_at < fetchStartedAt || now - r.acked_at > ACKED_MAX_AGE_MS) {
      await store.delete(r.item.id);
    }
  }
  await refreshAckedSnapshot();
}

/**
 * The acked items now, read afresh (for taps, inside their lock). With `now`, those older
 * than {@link ACKED_MAX_AGE_MS} are left out: the service worker's view, where nothing
 * prunes the record (it fetches no `listRuns`), so a stale one must not keep a run known.
 */
export async function ackedItems(now?: number): Promise<OutboxItem<RunEventPayload>[]> {
  const records = await store.all();
  return records
    .filter((r) => now === undefined || now - r.acked_at <= ACKED_MAX_AGE_MS)
    .map((r) => r.item);
}

// ---- snapshot for the page (React and the badge) --------------------------------

let snapshot: readonly OutboxItem<RunEventPayload>[] = [];
const listeners = new Set<() => void>();

export function getAckedSnapshot(): readonly OutboxItem<RunEventPayload>[] {
  return snapshot;
}

export function subscribeAcked(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export async function refreshAckedSnapshot(): Promise<void> {
  try {
    snapshot = await ackedItems();
  } catch (err) {
    console.error('[runs] could not read acked run events', err);
  }
  listeners.forEach((l) => {
    l();
  });
}
