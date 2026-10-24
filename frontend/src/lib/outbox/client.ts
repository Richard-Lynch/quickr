/**
 * The page's outbox singleton plus everything that makes it flush on its own.
 *
 * WebKit (every iOS browser, including Chrome on iOS) has no Background Sync, so the
 * in-page triggers below are the primary mechanism:
 *  - app start, `online`, `visibilitychange → visible`, `pageshow` (bfcache restore):
 *    flush everything pending, ignoring backoff (iOS freezes timers in the background);
 *  - a timer re-armed for the next item's backoff deadline while anything is pending;
 *  - Background Sync (`registration.sync.register`) where supported (Chromium): the SW
 *    flushes the same IndexedDB queue even after the tab is closed.
 */
import { CHANNEL_HEADERS } from '../../api/constants';
import { timedFetch } from '../runs/serverClock';
import { OUTBOX_KINDS, OUTBOX_SYNC_TAG } from './kinds';
import { createOutbox, type Outbox } from './outbox';
import type { OutboxItem } from './types';

export const outbox: Outbox = createOutbox({
  kinds: OUTBOX_KINDS,
  headers: CHANNEL_HEADERS,
  fetch: timedFetch(),
});

/** Longest wait between checks while items are pending. */
const MAX_POLL_MS = 60_000;

export function isOnline(): boolean {
  return typeof navigator === 'undefined' || navigator.onLine;
}

interface SyncRegistration {
  sync?: { register(tag: string): Promise<void> };
}

/** Ask the SW to flush when connectivity returns (Chromium only). Never throws. */
export async function requestBackgroundSync(): Promise<boolean> {
  try {
    if (!('serviceWorker' in navigator)) return false;
    const reg = (await navigator.serviceWorker.getRegistration()) as
      (ServiceWorkerRegistration & SyncRegistration) | undefined;
    if (!reg?.sync) return false;
    await reg.sync.register(OUTBOX_SYNC_TAG);
    return true;
  } catch {
    return false;
  }
}

// ---- snapshot store for React (useSyncExternalStore) -------------------------

export interface OutboxSnapshot {
  items: readonly OutboxItem[];
  loaded: boolean;
}

let snapshot: OutboxSnapshot = { items: [], loaded: false };
const snapshotListeners = new Set<() => void>();
let refreshing: Promise<void> | null = null;
let refreshAgain = false;

export function refreshOutboxSnapshot(): Promise<void> {
  if (refreshing) {
    refreshAgain = true;
    return refreshing;
  }
  refreshing = (async () => {
    do {
      refreshAgain = false;
      try {
        snapshot = { items: await outbox.list(), loaded: true };
      } catch (err) {
        console.error('[outbox] could not read the queue', err);
        snapshot = { items: snapshot.items, loaded: true };
      }
      snapshotListeners.forEach((l) => {
        l();
      });
      // set by concurrent callers while we awaited (TS can't see that)
      // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
    } while (refreshAgain);
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}

export function subscribeOutboxSnapshot(listener: () => void): () => void {
  snapshotListeners.add(listener);
  return () => {
    snapshotListeners.delete(listener);
  };
}

export function getOutboxSnapshot(): OutboxSnapshot {
  return snapshot;
}

// ---- automatic flushing -------------------------------------------------------

let timer: ReturnType<typeof setTimeout> | undefined;

async function schedule(): Promise<void> {
  clearTimeout(timer);
  timer = undefined;
  const due = await outbox.nextDueAt();
  if (due === null) return;
  const delay = Math.min(Math.max(due - Date.now(), 1_000), MAX_POLL_MS);
  timer = setTimeout(() => {
    if (isOnline() && document.visibilityState !== 'hidden') {
      void outbox.flush().finally(() => void schedule());
    } else {
      void schedule();
    }
  }, delay);
}

/** Flush now. `force` ignores backoff (used when conditions just changed for the better). */
export function kickOutbox(force = true): Promise<void> {
  if (!isOnline()) return schedule();
  return outbox
    .flush({ force })
    .then(() => undefined)
    .catch((err: unknown) => {
      console.error('[outbox] flush failed', err);
    })
    .finally(() => void schedule());
}

let started = false;

/** Wire the triggers once (idempotent). Returns a teardown for tests. */
export function startOutbox(): () => void {
  if (started) return () => undefined;
  started = true;

  const unsubscribe = outbox.subscribe((e) => {
    void refreshOutboxSnapshot();
    if (e.type === 'enqueued' || e.type === 'updated' || e.type === 'retrying') void schedule();
    // Offline or flaky: let the SW finish the job even if the app gets closed.
    if (e.type === 'retrying' || (e.type === 'enqueued' && !isOnline())) {
      void requestBackgroundSync();
    }
  });
  const onOnline = () => void kickOutbox(true);
  const onVisible = () => {
    if (document.visibilityState === 'visible') void kickOutbox(true);
  };
  const onPageShow = (e: PageTransitionEvent) => {
    if (e.persisted) void kickOutbox(true);
  };
  window.addEventListener('online', onOnline);
  document.addEventListener('visibilitychange', onVisible);
  window.addEventListener('pageshow', onPageShow);

  void refreshOutboxSnapshot();
  void kickOutbox(true);

  return () => {
    started = false;
    unsubscribe();
    clearTimeout(timer);
    window.removeEventListener('online', onOnline);
    document.removeEventListener('visibilitychange', onVisible);
    window.removeEventListener('pageshow', onPageShow);
  };
}
