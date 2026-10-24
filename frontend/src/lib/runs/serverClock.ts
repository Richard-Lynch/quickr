/**
 * The PWA's server-time offset (timers.md §5.1 item 2): kept in memory and in
 * `localStorage`, fed by every API response's `X-QuickR-Server-Time`.
 *
 * {@link timedFetch} wraps the `fetch` of the generated client and of the outbox, so every
 * `/api/v1` response, errors included, is a sample. The pure rules live in `clock.ts`.
 * The service worker has no `localStorage`: there the offset lives in memory only.
 */
import { FROM_CACHE_HEADER } from '../../api/constants';
import { INITIAL_OFFSET_MS, SERVER_TIME_HEADER, nextOffset, parseServerTime } from './clock';

export const SERVER_OFFSET_KEY = 'quickr.serverOffsetMs';

let memory: number = INITIAL_OFFSET_MS;

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
  const next = nextOffset(serverOffset(), parseServerTime(header), tSend, tRecv);
  memory = next;
  try {
    storage()?.setItem(SERVER_OFFSET_KEY, String(next));
  } catch {
    // memory only
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
