import { useMemo, useSyncExternalStore } from 'react';

import { useOnline } from '../network';
import { getOutboxSnapshot, kickOutbox, outbox, subscribeOutboxSnapshot } from './client';
import type { OutboxItem, SendNowResult } from './types';

export interface UseOutbox {
  /** Every queued item, oldest first. */
  items: readonly OutboxItem[];
  /** Waiting to be (re)sent automatically. */
  pending: readonly OutboxItem[];
  /** Terminal failures: the user must fix or discard them. */
  failed: readonly OutboxItem[];
  pendingCount: number;
  failedCount: number;
  /** False until the queue has been read from IndexedDB once. */
  loaded: boolean;
  online: boolean;
  enqueue: <P>(kind: string, payload: P, opts?: { id?: string }) => Promise<OutboxItem<P>>;
  /** Enqueue-then-send helper: flush and wait up to `timeoutMs` for this item's outcome. */
  sendNow: (id: string, timeoutMs?: number) => Promise<SendNowResult>;
  update: <P>(id: string, payload: P) => Promise<OutboxItem<P> | undefined>;
  retry: (id: string) => Promise<unknown>;
  discard: (id: string) => Promise<OutboxItem | undefined>;
  /** Try everything pending right now (ignores backoff). */
  syncNow: () => Promise<void>;
}

/** Live view of the durable outbox + actions. Works without any provider. */
export function useOutbox(): UseOutbox {
  const snap = useSyncExternalStore(subscribeOutboxSnapshot, getOutboxSnapshot, getOutboxSnapshot);
  const online = useOnline();
  return useMemo(() => {
    const pending = snap.items.filter((i) => i.status === 'pending');
    const failed = snap.items.filter((i) => i.status === 'failed');
    return {
      items: snap.items,
      pending,
      failed,
      pendingCount: pending.length,
      failedCount: failed.length,
      loaded: snap.loaded,
      online,
      enqueue: (kind, payload, opts) => outbox.enqueue(kind, payload, opts),
      sendNow: (id, timeoutMs) => outbox.sendNow(id, timeoutMs),
      update: (id, payload) => outbox.update(id, payload),
      retry: (id) => outbox.retry(id),
      discard: (id) => outbox.discard(id),
      syncNow: () => kickOutbox(true),
    };
  }, [snap, online]);
}
