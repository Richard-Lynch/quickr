/**
 * Persist the TanStack Query cache to IndexedDB so the last-seen topics, topic
 * details, questions and recent entries render instantly on launch — and offline.
 */
import type { PersistedClient, Persister } from '@tanstack/react-query-persist-client';
import type { PersistQueryClientOptions } from '@tanstack/react-query-persist-client';
import { createStore, del, get, set, type UseStore } from 'idb-keyval';

import { keyMeta } from './cache';
import { CACHE_GC_TIME } from './queryClient';

export const CACHE_DB = 'quickr-cache';
const CACHE_STORE = 'kv';
const CACHE_KEY = 'react-query';

/** Discard a persisted snapshot older than this (must be ≤ the queries' gcTime). */
export const CACHE_MAX_AGE = CACHE_GC_TIME;

/**
 * A new app version or a regenerated API client invalidates the snapshot (its data may
 * not match the new types).
 */
export const CACHE_BUSTER = `${__APP_VERSION__}+${__API_HASH__}`;

/** Never persisted (large or pointless offline). */
const SKIP_OPERATIONS = new Set(['exportEntriesCsv', 'health']);

let store: UseStore | null = null;
const cacheStore = () => (store ??= createStore(CACHE_DB, CACHE_STORE));

/**
 * idb-keyval persister. Writes are throttled (the cache changes often) and flushed
 * when the page is hidden — iOS may kill a backgrounded home-screen app without
 * further notice.
 */
export function createIdbPersister(throttleMs = 1_000): Persister {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let latest: PersistedClient | null = null;

  const write = () => {
    clearTimeout(timer);
    timer = undefined;
    const client = latest;
    latest = null;
    if (client) {
      set(CACHE_KEY, client, cacheStore()).catch((err: unknown) => {
        console.warn('[cache] could not persist the query cache', err);
      });
    }
  };

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') write();
    });
    window.addEventListener('pagehide', write);
  }

  return {
    persistClient(client) {
      latest = client;
      timer ??= setTimeout(write, throttleMs);
    },
    restoreClient: () => get<PersistedClient>(CACHE_KEY, cacheStore()),
    removeClient: () => del(CACHE_KEY, cacheStore()),
  };
}

export const persister = createIdbPersister();

export const persistOptions: Omit<PersistQueryClientOptions, 'queryClient'> = {
  persister,
  maxAge: CACHE_MAX_AGE,
  buster: CACHE_BUSTER,
  dehydrateOptions: {
    shouldDehydrateQuery: (q) =>
      q.state.status === 'success' && !SKIP_OPERATIONS.has(keyMeta(q.queryKey)?._id ?? ''),
  },
};

/** Drop the persisted snapshot (Settings → Clear local data). */
export function clearPersistedCache(): Promise<void> {
  return del(CACHE_KEY, cacheStore());
}
