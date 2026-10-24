/**
 * The PWA's server-time offset (timers.md §5.1 item 2): kept in memory and in
 * `localStorage`, fed by every API response's `X-QuickR-Server-Time`.
 *
 * {@link timedFetch} wraps the `fetch` of the generated client and of the outbox, so every
 * `/api/v1` response, errors included, is a sample. The pure rules live in `clock.ts`.
 *
 * The service worker has no `localStorage`, so every sample is also copied to IndexedDB,
 * which both contexts can read: the service worker loads it ({@link loadServerOffset})
 * before stamping a reminder's Start (timers.md §10.2), so it uses the page's latest offset.
 */
import { createStore, get, set, type UseStore } from 'idb-keyval';

import { FROM_CACHE_HEADER } from '../../api/constants';
import {
  INITIAL_OFFSET_MS,
  SERVER_TIME_HEADER,
  nextOffset,
  offsetSample,
  parseServerTime,
} from './clock';

export const SERVER_OFFSET_KEY = 'quickr.serverOffsetMs';

let memory: number = INITIAL_OFFSET_MS;

// ---- the IndexedDB copy (the service worker's view) ---------------------------------

const IDB_NAME = 'quickr-server-clock';
const IDB_KEY = 'offset_ms';
let idb: UseStore | null = null;

function offsetStore(): UseStore | null {
  try {
    if (typeof indexedDB === 'undefined') return null;
    return (idb ??= createStore(IDB_NAME, 'kv'));
  } catch {
    return null;
  }
}

/** Copy a sample to IndexedDB; best effort (the in-context offset doesn't wait for it). */
export async function persistServerOffset(offset: number): Promise<void> {
  const store = offsetStore();
  if (!store) return;
  try {
    await set(IDB_KEY, offset, store);
  } catch {
    // blocked storage: this context's memory still has it
  }
}

/**
 * Read the latest sample any context copied to IndexedDB into this context's memory, and
 * return the offset now in effect. For the service worker, which has no `localStorage`;
 * a page's `localStorage` still wins in {@link serverOffset}.
 */
export async function loadServerOffset(): Promise<number> {
  const store = offsetStore();
  if (store) {
    try {
      const stored: unknown = await get(IDB_KEY, store);
      if (typeof stored === 'number' && Number.isSafeInteger(stored)) memory = stored;
    } catch {
      // nothing readable: memory as it is
    }
  }
  return serverOffset();
}

/** The part of `Storage` used here (the service worker's lib has no DOM types). */
interface OffsetStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function storage(): OffsetStorage | null {
  try {
    return (globalThis as { localStorage?: OffsetStorage }).localStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * The current offset, `server time − device time` in ms; 0 before the first sample. Read
 * from `localStorage` when it can be, so every tab uses the latest sample of any of them.
 */
export function serverOffset(): number {
  try {
    const raw = storage()?.getItem(SERVER_OFFSET_KEY);
    if (raw != null) {
      const n = Number(raw);
      if (Number.isSafeInteger(n)) return n;
    }
  } catch {
    // blocked storage: memory below
  }
  return memory;
}

/** Record one response's sample (§5.1 item 2: the latest qualifying one wins). */
export function recordServerTime(header: string | null, tSend: number, tRecv: number): number {
  const serverTime = parseServerTime(header);
  const next = nextOffset(serverOffset(), serverTime, tSend, tRecv);
  memory = next;
  try {
    storage()?.setItem(SERVER_OFFSET_KEY, String(next));
  } catch {
    // memory only
  }
  // Only a real sample: the service worker's memory may be stale, and must not overwrite
  // the page's copy with it.
  if (serverTime !== null && offsetSample(serverTime, tSend, tRecv) !== null) {
    void persistServerOffset(next);
  }
  return next;
}

/**
 * Whether a response came from a cache, so its server time is old: the service worker's
 * (it marks them, and strips the time from what it stores) or an HTTP cache (`Age`).
 */
export function isCachedResponse(res: Response): boolean {
  return res.headers.has(FROM_CACHE_HEADER) || res.headers.has('Age');
}

/**
 * `fetch` that records each fresh response's server time. `base` is read at call time, so
 * a stubbed `globalThis.fetch` (tests) is used, and `window.fetch` keeps its receiver.
 */
export function timedFetch(base?: typeof fetch): typeof fetch {
  return async (input, init) => {
    const tSend = Date.now();
    const res = await (base ?? globalThis.fetch)(input, init);
    const tRecv = Date.now();
    if (!isCachedResponse(res)) recordServerTime(res.headers.get(SERVER_TIME_HEADER), tSend, tRecv);
    return res;
  };
}

/** Tests: forget every sample. */
export function resetServerOffset(): void {
  memory = INITIAL_OFFSET_MS;
  try {
    storage()?.removeItem(SERVER_OFFSET_KEY);
  } catch {
    // nothing stored
  }
}
