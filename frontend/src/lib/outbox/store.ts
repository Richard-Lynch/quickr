import { clear, createStore, del, get, set, values, type UseStore } from 'idb-keyval';

import type { OutboxItem } from './types';

/** Persistence for outbox items. The IndexedDB one is used in the app and the SW. */
export interface OutboxStore {
  all(): Promise<OutboxItem[]>;
  get(id: string): Promise<OutboxItem | undefined>;
  put(item: OutboxItem): Promise<void>;
  delete(id: string): Promise<void>;
  clear(): Promise<void>;
}

export const OUTBOX_DB = 'quickr-outbox';
export const OUTBOX_STORE = 'items';

/** IndexedDB store (one DB, one object store, keyed by item id). Opened lazily. */
export function idbOutboxStore(dbName = OUTBOX_DB, storeName = OUTBOX_STORE): OutboxStore {
  let store: UseStore | null = null;
  const s = () => (store ??= createStore(dbName, storeName));
  return {
    all: () => values<OutboxItem>(s()),
    get: (id) => get<OutboxItem>(id, s()),
    put: (item) => set(item.id, item, s()),
    delete: (id) => del(id, s()),
    clear: () => clear(s()),
  };
}

/** In-memory store for tests and environments without IndexedDB. */
export function memoryOutboxStore(): OutboxStore {
  const map = new Map<string, OutboxItem>();
  const clone = (i: OutboxItem): OutboxItem => structuredClone(i);
  return {
    all: () => Promise.resolve([...map.values()].map(clone)),
    get: (id) => {
      const item = map.get(id);
      return Promise.resolve(item ? clone(item) : undefined);
    },
    put: (item) => {
      map.set(item.id, clone(item));
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
