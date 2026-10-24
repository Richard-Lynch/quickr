import { uuid } from '../uuid';
import { backoffMs, classifyStatus, errorMessageFor } from './classify';
import { idbOutboxStore, type OutboxStore } from './store';
import type {
  FlushResult,
  OutboxError,
  OutboxEvent,
  OutboxItem,
  OutboxKind,
  OutboxRead,
  OutboxRequest,
  Outcome,
  SendNowResult,
  Verdict,
} from './types';

export interface OutboxOptions {
  /** Registry of item kinds → request builders (see `kinds.ts`). */
  kinds: Readonly<Record<string, OutboxKind>>;
  store?: OutboxStore;
  fetch?: typeof fetch;
  now?: () => number;
  random?: () => number;
  /** Extra headers on every request (the channel header). */
  headers?: Readonly<Record<string, string>>;
  /** Abort a single request after this long (counts as a network error). */
  requestTimeoutMs?: number;
  /** Web Locks name serialising flushes across tabs and the service worker. */
  lockName?: string;
  /** BroadcastChannel for cross-context events (tabs ↔ SW); `null` disables it. */
  channelName?: string | null;
}

export type OutboxListener = (event: OutboxEvent, remote: boolean) => void;

export interface Outbox {
  /**
   * Persist a new item (status `pending`, due now). Does not send — call `flush`/`sendNow`.
   * A kind's `coalesce` may drop queued items, or the new one: it is then returned but never
   * stored (`get(id)` finds nothing).
   */
  enqueue<P>(kind: string, payload: P, opts?: { id?: string }): Promise<OutboxItem<P>>;
  /** All items, oldest first. */
  list(): Promise<OutboxItem[]>;
  get(id: string): Promise<OutboxItem | undefined>;
  /** Replace an item's payload (the "fix" flow); resets it to `pending`, due now. */
  update<P>(id: string, payload: P): Promise<OutboxItem<P> | undefined>;
  /** Make an item (pending or failed) due now and flush. */
  retry(id: string): Promise<FlushResult | undefined>;
  /** Remove an item without sending it, and every item that waits for it. */
  discard(id: string): Promise<OutboxItem | undefined>;
  /**
   * Send every due `pending` item (all of them with `force`), oldest first. Concurrent calls
   * coalesce; flushes in other tabs / the SW are serialised by a Web Lock.
   */
  flush(opts?: { force?: boolean }): Promise<FlushResult>;
  /** Flush and wait (up to `timeoutMs`) for the first outcome of one item. */
  sendNow(id: string, timeoutMs?: number): Promise<SendNowResult>;
  /** Earliest `next_attempt_at` among pending items, or null when nothing is pending. */
  nextDueAt(): Promise<number | null>;
  clear(): Promise<void>;
  subscribe(listener: OutboxListener): () => void;
  close(): void;
}

const DEFAULT_TIMEOUT_MS = 15_000;
export const OUTBOX_CHANNEL = 'quickr-outbox';
export const OUTBOX_LOCK = 'quickr-outbox';

type AttemptResult =
  { outcome: 'ok'; data: unknown } | { outcome: Exclude<Outcome, 'ok'>; error: OutboxError };

export function createOutbox(opts: OutboxOptions): Outbox {
  const store = opts.store ?? idbOutboxStore();
  const doFetch: typeof fetch = opts.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const now = opts.now ?? Date.now;
  const random = opts.random ?? Math.random;
  const iso = () => new Date(now()).toISOString();
  const listeners = new Set<OutboxListener>();

  const channel =
    opts.channelName !== null && typeof BroadcastChannel !== 'undefined'
      ? new BroadcastChannel(opts.channelName ?? OUTBOX_CHANNEL)
      : null;
  if (channel) {
    channel.onmessage = (m: MessageEvent<OutboxEvent>) => {
      emitLocal(m.data, true);
    };
  }

  function emitLocal(event: OutboxEvent, remote: boolean): void {
    for (const l of [...listeners]) {
      try {
        l(event, remote);
      } catch (err) {
        console.error('[outbox] listener failed', err);
      }
    }
  }

  function emit(event: OutboxEvent): void {
    emitLocal(event, false);
    try {
      channel?.postMessage(event);
    } catch {
      // not structured-cloneable or channel closed — local listeners already ran
    }
  }

  // Serialises lock holders in this context too (the Web Lock alone does where it exists).
  let lockTail: Promise<unknown> = Promise.resolve();

  function withLock(fn: () => Promise<void>): Promise<void> {
    const locks = (globalThis as { navigator?: { locks?: LockManager } }).navigator?.locks;
    const run = lockTail.then(() =>
      locks ? locks.request(opts.lockName ?? OUTBOX_LOCK, () => fn()) : fn(),
    );
    lockTail = run.catch(() => undefined);
    return run.then(() => undefined);
  }

  /** Whether an item it waits for (`OutboxKind.waitsFor`) is still in `queue`. */
  function isBlocked(item: OutboxItem, queue: readonly OutboxItem[]): boolean {
    const deps = opts.kinds[item.kind]?.waitsFor?.(item, queue) ?? [];
    return deps.some((d) => d !== item.id && queue.some((i) => i.id === d));
  }

  /** Enqueue order: `created_at`, then the kind's tie-break (`orderKey`), then the id. */
  function byCreated(a: OutboxItem, b: OutboxItem): number {
    const key = (i: OutboxItem) => opts.kinds[i.kind]?.orderKey?.(i) ?? '';
    return (
      a.created_at.localeCompare(b.created_at) ||
      key(a).localeCompare(key(b)) ||
      a.id.localeCompare(b.id)
    );
  }

  async function list(): Promise<OutboxItem[]> {
    return (await store.all()).sort(byCreated);
  }

  type Sent =
    | { kind: 'network' }
    | { kind: 'redirect'; status: number | null }
    | { kind: 'response'; status: number; text: string; json: unknown; parsed: boolean };

  /** One request, with the outbox's headers, timeout and fetch options. */
  async function send(
    req: Omit<OutboxRequest, 'method'> & { method: OutboxRequest['method'] | 'GET' },
  ): Promise<Sent> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => {
      ctrl.abort();
    }, opts.requestTimeoutMs ?? DEFAULT_TIMEOUT_MS);
    let res: Response;
    try {
      res = await doFetch(req.url, {
        method: req.method,
        headers: {
          Accept: 'application/json',
          ...(req.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...opts.headers,
          ...req.headers,
        },
        body: req.body === undefined ? null : JSON.stringify(req.body),
        credentials: 'same-origin',
        // An auth proxy bouncing to a login page must not look like success.
        redirect: 'manual',
        cache: 'no-store',
        signal: ctrl.signal,
      });
    } catch {
      return { kind: 'network' };
    } finally {
      clearTimeout(timer);
    }

    if (res.type === 'opaqueredirect' || (res.status >= 300 && res.status < 400)) {
      return { kind: 'redirect', status: res.status || null };
    }

    let text = '';
    try {
      text = await res.text();
    } catch {
      // body lost mid-stream; status still tells us what happened
    }
    let json: unknown = undefined;
    let parsed = false;
    if (text) {
      try {
        json = JSON.parse(text);
        parsed = true;
      } catch {
        // not JSON
      }
    }
    return { kind: 'response', status: res.status, text, json, parsed };
  }

  /** A kind's `verify` read: no usable answer (network, redirect, not JSON) is a null status. */
  async function read(url: string): Promise<OutboxRead> {
    const res = await send({ method: 'GET', url });
    if (res.kind !== 'response' || (res.text && !res.parsed))
      return { status: null, body: undefined };
    return { status: res.status, body: res.json };
  }

  async function attempt(item: OutboxItem): Promise<AttemptResult> {
    const kind = opts.kinds[item.kind];
    if (!kind) {
      return {
        outcome: 'terminal',
        error: { message: `Unknown outbox item kind "${item.kind}"`, status: null },
      };
    }
    let req: OutboxRequest;
    try {
      req = kind.toRequest(item);
    } catch (err) {
      return {
        outcome: 'terminal',
        error: { message: err instanceof Error ? err.message : 'Invalid item', status: null },
      };
    }

    const res = await send(req);
    if (res.kind === 'network') {
      return { outcome: 'retry', error: { message: 'Could not reach the server', status: null } };
    }
    if (res.kind === 'redirect') {
      return {
        outcome: 'retry',
        error: {
          message: 'The server redirected the request (sign-in required?)',
          status: res.status,
        },
      };
    }

    const { status, text, json, parsed } = res;
    const outcome = kind.classify?.(status, json, item) ?? classifyStatus(status);
    if (outcome === 'ok') {
      // A 200 HTML page (captive portal, proxy) is not a confirmation.
      if (text && !parsed) {
        return {
          outcome: 'retry',
          error: { message: 'Unexpected response from the server', status },
        };
      }
      return { outcome: 'ok', data: json };
    }
    return {
      outcome,
      error: {
        message: errorMessageFor(status, json),
        status,
        ...(parsed ? { body: json } : {}),
      },
    };
  }

  /**
   * A terminal refusal, looked at again by the kind's `verify`: the outcome to apply, and
   * whether an ack came from it. Other items it fails are failed here (unless edited meanwhile).
   */
  async function verified(
    item: OutboxItem,
    res: AttemptResult,
    total: Omit<FlushResult, 'remaining'>,
  ): Promise<{ res: AttemptResult; verified: boolean }> {
    const kind = opts.kinds[item.kind];
    if (res.outcome !== 'terminal' || !kind?.verify) return { res, verified: false };
    let verdict: Verdict | undefined;
    try {
      verdict = await kind.verify(item, res.error, { read, queue: await list() });
    } catch (err) {
      console.error('[outbox] verify failed', err);
    }
    if (!verdict) return { res, verified: false };
    if (verdict.outcome === 'ok')
      return { res: { outcome: 'ok', data: verdict.data }, verified: true };
    for (const id of verdict.fail?.ids ?? []) {
      const other = await store.get(id);
      if (!other || other.id === item.id || other.status === 'failed') continue;
      const next: OutboxItem = {
        ...other,
        status: 'failed',
        last_error: verdict.fail?.error ?? null,
        updated_at: iso(),
      };
      await store.put(next);
      total.failed++;
      emit({ type: 'failed', item: next });
    }
    return {
      res: { outcome: verdict.outcome, error: verdict.error ?? res.error },
      verified: false,
    };
  }

  async function pass(force: boolean, total: Omit<FlushResult, 'remaining'>): Promise<void> {
    const due = (await list()).filter(
      (i) => i.status === 'pending' && (force || i.next_attempt_at <= now()),
    );
    for (const snapshot of due) {
      const item = await store.get(snapshot.id);
      if (item?.status !== 'pending') continue;
      // Waits for an item still queued (e.g. its run's start): not attempted, no backoff.
      // An earlier item of this pass that was just sent is gone from the store by now.
      if (opts.kinds[item.kind]?.waitsFor && isBlocked(item, await store.all())) continue;

      const { res, verified: ackedByVerify } = await verified(item, await attempt(item), total);
      if (res.outcome === 'ok') {
        try {
          await opts.kinds[item.kind]?.onAck?.(item, res.data);
        } catch (err) {
          console.error('[outbox] ack hook failed', err);
        }
        await store.delete(item.id);
        total.sent++;
        emit({ type: 'sent', item, data: res.data, ...(ackedByVerify ? { verified: true } : {}) });
        continue;
      }

      const error = res.error;
      if (res.outcome === 'retired') {
        // Compare-and-set as below: a discard or edit made meanwhile wins.
        const current = await store.get(item.id);
        if (current?.updated_at === item.updated_at) {
          await store.delete(item.id);
          total.retired++;
          emit({ type: 'retired', item, error });
        }
        continue;
      }
      const attempts = item.attempts + 1;
      const terminal = res.outcome === 'terminal';
      const next: OutboxItem = terminal
        ? { ...item, attempts, status: 'failed', last_error: error, updated_at: iso() }
        : {
            ...item,
            attempts,
            next_attempt_at: now() + backoffMs(attempts, random),
            last_error: error,
            updated_at: iso(),
          };
      // Compare-and-set: if the user edited / retried / discarded it meanwhile, theirs wins.
      const current = await store.get(item.id);
      if (current?.updated_at === item.updated_at) {
        await store.put(next);
        if (terminal) total.failed++;
        else total.retrying++;
        emit({ type: terminal ? 'failed' : 'retrying', item: next });
      }
      // Offline: the rest would fail the same way — don't burn their attempts.
      if (!terminal && error.status === null) break;
    }
  }

  let running: Promise<FlushResult> | null = null;
  let again = false;
  let againForce = false;

  function flush(o: { force?: boolean } = {}): Promise<FlushResult> {
    if (running) {
      again = true;
      againForce ||= o.force === true;
      return running;
    }
    const run = async (): Promise<FlushResult> => {
      const total = { sent: 0, failed: 0, retrying: 0, retired: 0 };
      let force = o.force === true;
      try {
        for (;;) {
          again = false;
          await withLock(() => pass(force, total));
          force = againForce;
          againForce = false;
          const remaining = (await store.all()).length;
          // A flush requested while we were busy gets another pass; clear `running`
          // synchronously so a request arriving after this point starts a new run.
          // `again` is set by concurrent flush() calls while we awaited.
          // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
          if (!again) {
            running = null;
            return { ...total, remaining };
          }
        }
      } catch (err) {
        running = null;
        throw err;
      }
    };
    running = run();
    return running;
  }

  function subscribe(listener: OutboxListener): () => void {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  }

  function waitFor(id: string, timeoutMs: number): Promise<SendNowResult> {
    return new Promise((resolve) => {
      let settled = false;
      const done = (r: SendNowResult) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        unsubscribe();
        resolve(r);
      };
      const unsubscribe = subscribe((e) => {
        if (!('item' in e) || e.item.id !== id) return;
        if (e.type === 'sent') done({ status: 'sent', data: e.data });
        else if (e.type === 'failed') done({ status: 'failed', item: e.item });
        else if (e.type === 'retrying') done({ status: 'queued', item: e.item });
        else if (e.type === 'retired') done({ status: 'retired', item: e.item, error: e.error });
        else if (e.type === 'discarded') done({ status: 'discarded' });
      });
      const timer = setTimeout(() => {
        void store.get(id).then(
          (item) => done({ status: 'queued', item }),
          () => done({ status: 'queued', item: undefined }),
        );
      }, timeoutMs);
    });
  }

  return {
    async enqueue<P>(kind: string, payload: P, o: { id?: string } = {}) {
      const k = Object.hasOwn(opts.kinds, kind) ? opts.kinds[kind] : undefined;
      if (!k) throw new Error(`Unknown outbox item kind "${kind}"`);
      const ts = iso();
      const item: OutboxItem<P> = {
        id: o.id ?? uuid(),
        kind,
        payload,
        created_at: ts,
        updated_at: ts,
        attempts: 0,
        status: 'pending',
        next_attempt_at: now(),
        last_error: null,
      };
      if (!k.coalesce || k.coalesces?.(item) === false) {
        await store.put(item);
        emit({ type: 'enqueued', item });
        return item;
      }
      // Under the flush lock, so no attempt of a dropped item is in flight.
      const dropped: OutboxItem[] = [];
      const kept = { stored: true };
      await withLock(async () => {
        const verdict = k.coalesce?.(item, await list());
        for (const id of verdict?.drop ?? []) {
          const queued = await store.get(id);
          if (!queued) continue;
          await store.delete(id);
          dropped.push(queued);
        }
        kept.stored = verdict?.store ?? true;
        if (kept.stored) await store.put(item);
      });
      for (const d of dropped) emit({ type: 'discarded', item: d });
      if (kept.stored) emit({ type: 'enqueued', item });
      return item;
    },
    list,
    get: (id) => store.get(id),
    async update<P>(id: string, payload: P) {
      const item = await store.get(id);
      if (!item) return undefined;
      const next: OutboxItem<P> = {
        ...item,
        payload,
        status: 'pending',
        next_attempt_at: now(),
        last_error: null,
        updated_at: iso(),
      };
      await store.put(next);
      emit({ type: 'updated', item: next });
      return next;
    },
    async retry(id) {
      const item = await store.get(id);
      if (!item) return undefined;
      const next: OutboxItem = {
        ...item,
        status: 'pending',
        next_attempt_at: now(),
        updated_at: iso(),
      };
      await store.put(next);
      emit({ type: 'updated', item: next });
      return flush();
    },
    async discard(id) {
      const item = await store.get(id);
      if (!item) return undefined;
      await store.delete(id);
      emit({ type: 'discarded', item });
      // Items that can never be sent without it (e.g. a run's events without its start).
      for (const other of await list()) {
        const owners = opts.kinds[other.kind]?.discardedWith?.(other) ?? [];
        if (other.id === id || !owners.includes(id)) continue;
        await store.delete(other.id);
        emit({ type: 'discarded', item: other });
      }
      return item;
    },
    flush,
    sendNow(id, timeoutMs = 8_000) {
      const wait = waitFor(id, timeoutMs);
      void flush();
      return wait;
    },
    async nextDueAt() {
      // Blocked items aren't due: the item they wait for has its own deadline (or failed).
      const all = await store.all();
      const pending = all.filter((i) => i.status === 'pending' && !isBlocked(i, all));
      return pending.length ? Math.min(...pending.map((i) => i.next_attempt_at)) : null;
    },
    async clear() {
      await store.clear();
      emit({ type: 'cleared' });
    },
    subscribe,
    close() {
      channel?.close();
      listeners.clear();
    },
  };
}
