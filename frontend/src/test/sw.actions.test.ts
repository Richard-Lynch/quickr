/**
 * The real `sw.ts`, loaded into a simulated ServiceWorkerGlobalScope, driving push and
 * notification-click events end to end against a fake quickR server (PLAN B8, Codex review).
 *
 * Simulated faithfully: the SW and the app as **separate contexts** (separate IndexedDB
 * connections to the same fake-indexeddb database, a real BroadcastChannel between them, a
 * shared Web Lock), the SW's own outbox, `fetch`, the API cache and `registration`.
 *
 * Not covered here (needs a real Chromium with a service worker, which the repo has no
 * harness for): the browser's notification UI and real `maxActions`, event lifetimes and
 * `waitUntil` extension, a real Background Sync retry, and an auth proxy's redirects.
 */
import { IDBFactory } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import idRaw from '../../../shared/fixtures/action-entry-id-vectors.json?raw';
import { OUTBOX_KINDS, type RunEventPayload } from '../lib/outbox/kinds';
import { createOutbox } from '../lib/outbox/outbox';
import { idbOutboxStore } from '../lib/outbox/store';
import type { OutboxItem } from '../lib/outbox/types';
import { ACKED_MAX_AGE_MS, recordAcked } from '../lib/runs/acked';
import { parseInstant } from '../lib/runs/instant';
import { persistServerOffset } from '../lib/runs/serverClock';
import { fakeQuickrServer, type FakeQuickrServer } from './fakeQuickrServer';
import { runItem } from './runs';

vi.mock('workbox-core', () => ({ clientsClaim: vi.fn() }));
vi.mock('workbox-precaching', () => ({
  precacheAndRoute: vi.fn(),
  cleanupOutdatedCaches: vi.fn(),
  createHandlerBoundToURL: vi.fn(),
}));
vi.mock('workbox-routing', () => ({ NavigationRoute: vi.fn(), registerRoute: vi.fn() }));
vi.mock('workbox-strategies', () => ({ NetworkFirst: vi.fn() }));
vi.mock('workbox-expiration', () => ({ ExpirationPlugin: vi.fn() }));
vi.mock('workbox-cacheable-response', () => ({ CacheableResponsePlugin: vi.fn() }));

const SERVER = '0b9e0000-0000-4000-8000-0000000000aa';
const TOPIC = '6f1c0000-0000-4000-8000-000000000001';

const reminder = {
  title: 'Mood',
  body: 'Time to log',
  url: '/t/mood/record',
  tag: `due-${TOPIC}`,
  topic_slug: 'mood',
  v: 1,
  kind: 'due',
  server_id: SERVER,
  topic_id: TOPIC,
  version: 3,
  due_since: '2026-10-17T08:00:00Z',
  quick_log: {
    type: 'enum',
    key: 'mood',
    label: 'Mood',
    options: [
      { value: 'good', label: 'Good' },
      { value: 'ok', label: 'OK' },
      { value: 'bad', label: 'Bad' },
    ],
    total_options: 3,
  },
};

type Listener = (event: unknown) => void;

interface Shown {
  title: string;
  options: { body?: string; data?: unknown; actions?: { action: string; title: string }[] };
}

/** Web Locks, per name, serialised (what navigator.locks gives the SW and the app). */
function webLocks() {
  const tails = new Map<string, Promise<unknown>>();
  return {
    request<T>(name: string, fn: () => Promise<T>): Promise<T> {
      const run = (tails.get(name) ?? Promise.resolve()).then(fn);
      tails.set(
        name,
        run.catch(() => undefined),
      );
      return run;
    },
  };
}

/** Cache Storage with one cache, enough for `cachedTopicState`. */
function fakeCaches() {
  const entries = new Map<string, string>();
  const cache = {
    match: (req: RequestInfo | URL) => {
      const key = new URL(String(req instanceof Request ? req.url : req), 'https://q.test').href;
      const body = entries.get(key);
      return Promise.resolve(body === undefined ? undefined : new Response(body));
    },
    keys: () => Promise.resolve([...entries.keys()].map((url) => new Request(url))),
    put: (path: string, body: unknown) => {
      entries.set(new URL(path, 'https://q.test').href, JSON.stringify(body));
    },
  };
  return { open: () => Promise.resolve(cache), cache };
}

let listeners: Map<string, Listener>;
let shown: Shown[];
let opened: string[];
let syncTags: string[];
let server: FakeQuickrServer;
let cacheStore: ReturnType<typeof fakeCaches>;

async function loadServiceWorker(): Promise<void> {
  vi.resetModules();
  listeners = new Map();
  shown = [];
  opened = [];
  syncTags = [];
  cacheStore = fakeCaches();
  const scope = {
    __WB_MANIFEST: [],
    location: new URL('https://q.test/'),
    addEventListener: (type: string, fn: Listener) => listeners.set(type, fn),
    skipWaiting: vi.fn(),
    navigator: { locks: sharedLocks },
    Notification: { maxActions: 2 },
    registration: {
      showNotification: (title: string, options: Shown['options']) => {
        shown.push({ title, options });
        return Promise.resolve();
      },
      sync: {
        register: (tag: string) => {
          syncTags.push(tag);
          return Promise.resolve();
        },
      },
    },
    clients: {
      matchAll: () => Promise.resolve([]),
      openWindow: (url: string) => {
        opened.push(url);
        return Promise.resolve(null);
      },
    },
  };
  vi.stubGlobal('self', scope);
  vi.stubGlobal('caches', cacheStore);
  const sw = '../sw.ts';
  await import(/* @vite-ignore */ sw);
}

let sharedLocks: ReturnType<typeof webLocks>;

/** Fires an event at the SW and waits for everything it passed to `waitUntil`. */
async function fire(type: string, init: Record<string, unknown>): Promise<void> {
  const pending: Promise<unknown>[] = [];
  const listener = listeners.get(type);
  if (!listener) throw new Error(`no ${type} listener`);
  listener({ ...init, waitUntil: (p: Promise<unknown>) => pending.push(p) });
  await Promise.all(pending);
}

async function push(payload: unknown): Promise<Shown> {
  await fire('push', { data: { json: () => payload, text: () => JSON.stringify(payload) } });
  const last = shown.at(-1);
  if (!last) throw new Error('nothing shown');
  return last;
}

function click(notification: Shown, action = ''): Promise<void> {
  return fire('notificationclick', {
    action,
    notification: { data: notification.options.data, close: vi.fn() },
  });
}

/** The app, in its own context: its own IndexedDB connection, the same lock and channel. */
function appOutbox() {
  return createOutbox({ kinds: OUTBOX_KINDS, store: idbOutboxStore(), fetch: server.fetch });
}

beforeEach(async () => {
  vi.stubGlobal('indexedDB', new IDBFactory());
  sharedLocks = webLocks();
  Object.defineProperty(globalThis.navigator, 'locks', { value: sharedLocks, configurable: true });
  server = fakeQuickrServer(SERVER, [TOPIC]);
  vi.stubGlobal('fetch', server.fetch);
  await loadServiceWorker();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('service worker: reminder actions', () => {
  it('shows the actions, and a click logs on the reminder’s server with the app closed', async () => {
    const n = await push(reminder);
    expect(n.options.actions).toEqual([
      { action: 'log|o|good', title: 'Good' },
      { action: 'log|o|ok', title: 'OK' },
    ]);
    await click(n, 'log|o|ok');
    expect([...server.entries.values()].map((e) => e.answers)).toEqual([
      [{ key: 'mood', value: 'ok' }],
    ]);
    expect(server.requests[0]?.headers['x-quickr-expect-server-id']).toBe(SERVER);
    expect(shown).toHaveLength(1); // no follow-up
    expect(await appOutbox().list()).toEqual([]);
  });

  it('a reminder from a replaced server writes nothing and tells the user', async () => {
    const n = await push(reminder);
    server.serverId = '0b9e0000-0000-4000-8000-0000000000bb'; // the origin now serves server B
    await click(n, 'log|o|ok');
    expect(server.entries.size).toBe(0);
    expect(shown.at(-1)).toMatchObject({
      title: 'Couldn’t log Mood',
      options: { body: 'This reminder came from another quickR server, so nothing was logged.' },
    });
    expect(await appOutbox().list()).toEqual([]);
  });

  it('a terminal refusal is shown, and the failed item is there for the app', async () => {
    const n = await push(reminder);
    server.topics.set(TOPIC, { status: 'archived' });
    await click(n, 'log|o|ok');
    expect(shown.at(-1)?.options.body).toBe('The topic is archived. Open quickR to log.');
    expect(shown.at(-1)?.options.data).toEqual({ url: '/t/mood/record' });
    expect((await appOutbox().list()).map((i) => i.status)).toEqual(['failed']);
  });

  it('a topic the app saw archived is refused without a request', async () => {
    cacheStore.cache.put('/api/v1/topics/mood', { id: TOPIC, status: 'archived' });
    await click(await push(reminder), 'log|o|ok');
    expect(server.requests).toEqual([]);
    expect(shown.at(-1)?.options.body).toBe('The topic is archived. Open quickR to log.');
  });

  it('offline: queued silently, Background Sync requested, and the app sends it later', async () => {
    const n = await push(reminder);
    server.offline = true;
    await click(n, 'log|o|ok');
    expect(shown).toHaveLength(1);
    expect(syncTags).toEqual(['quickr-outbox']);
    server.offline = false;
    const app = appOutbox();
    expect((await app.list()).map((i) => i.status)).toEqual(['pending']);
    expect((await app.flush({ force: true })).sent).toBe(1);
    expect(server.entries.size).toBe(1);
  });

  it('racing clicks and a re-delivered push log once; a later other choice says what was logged', async () => {
    const n = await push(reminder);
    await Promise.all([click(n, 'log|o|ok'), click(n, 'log|o|ok')]);
    const again = await push(reminder); // delivered twice (at least once per slot)
    await click(again, 'log|o|ok');
    expect(server.entries.size).toBe(1);
    await click(again, 'log|o|bad');
    expect(shown.at(-1)).toMatchObject({
      title: 'Already logged',
      options: { body: 'This reminder was already logged as OK. Open quickR to change it.' },
    });
    expect([...server.entries.values()].map((e) => e.answers)).toEqual([
      [{ key: 'mood', value: 'ok' }],
    ]);
  });

  it('the body, an invalid action or a broken outbox opens the record screen', async () => {
    const n = await push(reminder);
    await click(n);
    await click(n, 'log|o|tampered');
    expect(opened).toEqual(['https://q.test/t/mood/record', 'https://q.test/t/mood/record']);
    vi.stubGlobal('indexedDB', undefined); // storage unavailable
    await loadServiceWorker();
    await click(await push(reminder), 'log|o|ok');
    expect(opened).toEqual(['https://q.test/t/mood/record']);
    expect(server.entries.size).toBe(0);
  });

  it('Safari-style pushes (no maxActions) and test pushes show no actions', async () => {
    expect((await push({ ...reminder, kind: 'test' })).options.actions).toBeUndefined();
    (self as unknown as { Notification: unknown }).Notification = undefined;
    expect((await push(reminder)).options.actions).toBeUndefined();
  });
});

describe('service worker: a timed reminder’s Start (timers.md §10.2)', () => {
  const timed = { ...reminder, title: 'Routine', quick_log: { type: 'timed' } };
  /** The action entry id vector of the reminder's (server, topic, slot). */
  const runId = (JSON.parse(idRaw) as { cases: { name: string; expected: string }[] }).cases.find(
    (c) => c.name === 'canonical',
  )?.expected;

  it('offers Start; a click starts the run, its id the action entry id, at the page’s offset', async () => {
    vi.stubGlobal('localStorage', undefined); // as in a service worker
    const n = await push(timed);
    expect(n.options.actions).toEqual([{ action: 'log|t|', title: 'Start' }]);
    await persistServerOffset(5000); // the page's latest sample, in IndexedDB
    const before = Date.now();
    await click(n, 'log|t|');
    const after = Date.now();
    const run = server.runs.get(runId ?? '');
    expect(run).toMatchObject({ topic_id: TOPIC, version: 3, source: 'pwa.notification' });
    const at = parseInstant(run?.at ?? '');
    expect(at).toBeGreaterThanOrEqual(before + 5000);
    expect(at).toBeLessThanOrEqual(after + 5000);
    expect(server.requests[0]?.headers['x-quickr-expect-server-id']).toBe(SERVER);
    expect(shown).toHaveLength(1); // no follow-up
    expect(await appOutbox().list()).toEqual([]);
  });

  it('without cached versions, a cached getTopic with the version’s timer gives the steps', async () => {
    cacheStore.cache.put('/api/v1/topics/mood', {
      id: TOPIC,
      current_version: 3,
      questions: [{ key: 'mood', type: 'int', required: true }],
      timer: { steps: [{ key: 'warm', label: 'Warm up' }] },
    });
    server.offline = true;
    await click(await push(timed), 'log|t|');
    const [item] = (await appOutbox().list()) as OutboxItem<RunEventPayload>[];
    expect(item?.payload).toMatchObject({
      steps: [{ key: 'warm', label: 'Warm up' }],
      requires_answers: true,
    });
  });

  it('a run id the cache shows as an entry (logged already) starts nothing (L6)', async () => {
    cacheStore.cache.put('/api/v1/topics/mood/entries', {
      items: [{ id: runId?.toUpperCase(), topic_id: TOPIC }],
      total: 1,
    });
    await click(await push(timed), 'log|t|');
    expect(server.requests).toEqual([]);
    expect(await appOutbox().list()).toEqual([]);
    expect(shown).toHaveLength(1); // no follow-up
  });

  it('nor does one cached as getEntry', async () => {
    cacheStore.cache.put(`/api/v1/entries/${runId ?? ''}`, { id: runId, topic_id: TOPIC });
    await click(await push(timed), 'log|t|');
    expect(server.requests).toEqual([]);
    expect(await appOutbox().list()).toEqual([]);
  });

  it('with nothing cached, the start’s steps and questions are unknown (null)', async () => {
    server.offline = true;
    await click(await push(timed), 'log|t|');
    const [item] = (await appOutbox().list()) as OutboxItem<RunEventPayload>[];
    expect(item?.payload).toMatchObject({ steps: null, requires_answers: null });
  });

  it('reads the acked record as of now: a stale ack doesn’t make the Start known', async () => {
    const id = runId ?? '';
    const acked = runItem('start', { id, run: id, at: Date.now() });
    await recordAcked(acked, Date.now() - ACKED_MAX_AGE_MS - 60_000);
    await click(await push(timed), 'log|t|');
    expect(server.requests).toHaveLength(1); // stale: started (no page pruned it)

    server.requests.length = 0;
    server.runs.clear();
    await recordAcked(acked, Date.now()); // fresh: this device started it
    await click(await push(timed), 'log|t|');
    expect(server.requests).toEqual([]);
  });

  it('racing clicks and a re-delivered push start one run; offline, the app sends it later', async () => {
    cacheStore.cache.put('/api/v1/topics/mood/versions', [
      { version: 3, questions: [], timer: { steps: [{ key: 'shower', label: 'Shower' }] } },
    ]);
    const n = await push(timed);
    server.offline = true;
    await Promise.all([click(n, 'log|t|'), click(n, 'log|t|')]);
    await click(await push(timed), 'log|t|');
    expect(syncTags).toContain('quickr-outbox');
    const app = appOutbox();
    const items = (await app.list()) as OutboxItem<RunEventPayload>[];
    expect(items.map((i) => i.id)).toEqual([runId]);
    expect(items[0]?.payload.steps).toEqual([{ key: 'shower', label: 'Shower' }]);
    server.offline = false;
    expect((await app.flush({ force: true })).sent).toBe(1);
    expect([...server.runs.keys()]).toEqual([runId]);
  });
});
