/// <reference lib="webworker" />
/**
 * quickR service worker (vite-plugin-pwa `injectManifest`; typechecked by tsconfig.sw.json).
 *
 * - precaches the app shell, SPA navigation fallback to index.html
 * - NetworkFirst (short timeout) for GET /api/v1/* JSON as an offline fallback layer;
 *   never caches /mcp, non-GET requests, CSV exports or push endpoints
 * - update flow: waits until the page asks it to SKIP_WAITING (no surprise reloads)
 * - Background Sync: flushes the IndexedDB outbox where supported (Chromium)
 * - Web Push: shows notifications, routes clicks into the app; quick-log reminders offer
 *   Chromium actions that log through the outbox (lib/pushActions.ts)
 */
import { CacheableResponsePlugin } from 'workbox-cacheable-response';
import { clientsClaim } from 'workbox-core';
import type { WorkboxPlugin } from 'workbox-core/types';
import { ExpirationPlugin } from 'workbox-expiration';
import {
  cleanupOutdatedCaches,
  createHandlerBoundToURL,
  precacheAndRoute,
  type PrecacheEntry,
} from 'workbox-precaching';
import { NavigationRoute, registerRoute } from 'workbox-routing';
import { NetworkFirst } from 'workbox-strategies';

import { API_PREFIX, CHANNEL_HEADERS, FROM_CACHE_HEADER, SW_API_CACHE } from './api/constants';
import { OUTBOX_KINDS, OUTBOX_SYNC_TAG } from './lib/outbox/kinds';
import { createOutbox } from './lib/outbox/outbox';
import { SERVER_TIME_HEADER } from './lib/runs/clock';
import { timedFetch } from './lib/runs/serverClock';
import {
  handleReminderAction,
  notificationData,
  pushActions,
  type ActionFeedback,
  type CachedTopicState,
} from './lib/pushActions';
import { parsePushPayload, safeInAppPath, type NavigateMessage } from './lib/pushPayload';

declare const self: ServiceWorkerGlobalScope & {
  __WB_MANIFEST: (string | PrecacheEntry)[];
};

/** Not in lib.webworker yet. */
interface SyncEvent extends ExtendableEvent {
  readonly tag: string;
  readonly lastChance: boolean;
}

// ---- lifecycle ----------------------------------------------------------------

self.addEventListener('message', (event) => {
  if ((event.data as { type?: unknown } | null)?.type === 'SKIP_WAITING') void self.skipWaiting();
});
// First install: take control right away so the very first visit works offline.
// Updates still wait for SKIP_WAITING from the "Update available" toast.
clientsClaim();

// ---- precache + navigation -------------------------------------------------------

precacheAndRoute(self.__WB_MANIFEST);
cleanupOutdatedCaches();

registerRoute(
  new NavigationRoute(createHandlerBoundToURL('index.html'), {
    denylist: [/^\/api\//, /^\/mcp/, /^\/docs/, /^\/redoc/, /^\/openapi\.json/],
  }),
);

// ---- API runtime cache (fallback layer under the persisted query cache) ---------

const NO_CACHE = [
  /\.csv$/,
  new RegExp(`^${API_PREFIX}/push/`),
  new RegExp(`^${API_PREFIX}/health$`),
  // Runs change by the second: a stale list would reopen stopped runs. The persisted
  // query cache covers offline (timers.md §7.3).
  new RegExp(`^${API_PREFIX}/runs(/|$)`),
];

/**
 * A cached copy doesn't keep the server time, and an answer from the cache is marked:
 * offline, it would be an old time with a short round trip, a bad offset sample
 * (timers.md §5.1).
 */
const dropServerTime: WorkboxPlugin = {
  cachedResponseWillBeUsed: ({ cachedResponse }) => {
    if (!cachedResponse) return Promise.resolve(cachedResponse);
    const headers = new Headers(cachedResponse.headers);
    headers.set(FROM_CACHE_HEADER, '1');
    const { status, statusText } = cachedResponse;
    return Promise.resolve(new Response(cachedResponse.body, { status, statusText, headers }));
  },
  cacheWillUpdate: ({ response }) => {
    if (!response.headers.has(SERVER_TIME_HEADER)) return Promise.resolve(response);
    const headers = new Headers(response.headers);
    headers.delete(SERVER_TIME_HEADER);
    const { status, statusText } = response;
    return Promise.resolve(new Response(response.body, { status, statusText, headers }));
  },
};

registerRoute(
  ({ url, request, sameOrigin }) =>
    sameOrigin &&
    request.method === 'GET' &&
    url.pathname.startsWith(`${API_PREFIX}/`) &&
    !NO_CACHE.some((re) => re.test(url.pathname)),
  new NetworkFirst({
    cacheName: SW_API_CACHE,
    networkTimeoutSeconds: 4,
    plugins: [
      // (workbox's plugin classes predate exactOptionalPropertyTypes)
      new CacheableResponsePlugin({ statuses: [200] }) as WorkboxPlugin,
      dropServerTime,
      new ExpirationPlugin({
        maxEntries: 300,
        maxAgeSeconds: 7 * 24 * 60 * 60,
        purgeOnQuotaError: true,
      }) as WorkboxPlugin,
    ],
  }),
  'GET',
);

// ---- Background Sync: flush the outbox -------------------------------------------

const outbox = createOutbox({ kinds: OUTBOX_KINDS, headers: CHANNEL_HEADERS, fetch: timedFetch() });

self.addEventListener('sync', (event) => {
  const e = event as SyncEvent;
  if (e.tag !== OUTBOX_SYNC_TAG) return;
  e.waitUntil(
    (async () => {
      await outbox.flush({ force: true });
      const stillPending = (await outbox.list()).some((i) => i.status === 'pending');
      // Rejecting asks the browser to retry the sync later (with its own backoff).
      if (stillPending && !e.lastChance) throw new Error('outbox: items still pending');
    })(),
  );
});

// ---- Web Push ---------------------------------------------------------------------

self.addEventListener('push', (event) => {
  let raw: unknown;
  try {
    raw = event.data?.json();
  } catch {
    raw = event.data?.text();
  }
  const p = parsePushPayload(raw);
  const actions = pushActions(p, maxActions());
  // userVisibleOnly: every push must show a notification (Safari revokes otherwise).
  event.waitUntil(
    self.registration.showNotification(p.title, {
      body: p.body,
      icon: '/pwa-192x192.png',
      badge: '/badge-96x96.png',
      data: notificationData(p),
      ...(p.tag ? { tag: p.tag } : {}),
      // (`actions` isn't in lib.webworker's NotificationOptions)
      ...(actions.length ? ({ actions } as NotificationOptions) : {}),
    }),
  );
});

/** Chromium shows up to `Notification.maxActions` actions; Safari and iOS have none. */
function maxActions(): number {
  const n = (self as { Notification?: { maxActions?: unknown } }).Notification?.maxActions;
  return typeof n === 'number' && n > 0 ? n : 0;
}

async function focusOrOpen(path: string): Promise<void> {
  const origin = self.location.origin;
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const ours = windows.filter((c) => new URL(c.url).origin === origin);
  const client = ours.find((c) => c.focused) ?? ours[0];
  if (client) {
    let target: WindowClient = client;
    try {
      target = await client.focus();
    } catch {
      // focus can be refused; still route the existing window
    }
    const here = new URL(target.url);
    if (here.pathname + here.search !== path) {
      // Let the SPA route (keeps state, respects the unsaved-changes guard).
      const msg: NavigateMessage = { type: 'quickr:navigate', url: path };
      target.postMessage(msg);
    }
    return;
  }
  await self.clients.openWindow(new URL(path, origin).href);
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data as { url?: unknown } | null;
  const open = () => focusOrOpen(safeInAppPath(data?.url));
  event.waitUntil(event.action ? onAction(event.action, data, open) : open());
});

/**
 * A reminder action: log it through the outbox, or say why not (lib/pushActions.ts). Works
 * with the app closed; offline, Background Sync (Chromium) or the app's next start sends it.
 */
async function onAction(action: string, data: unknown, open: () => Promise<void>): Promise<void> {
  let feedback: ActionFeedback;
  try {
    feedback = await handleReminderAction({
      outbox,
      action,
      data,
      locks: (self.navigator as { locks?: LockManager }).locks,
      topicState: cachedTopicState,
      queued: () =>
        (self.registration as { sync?: { register(tag: string): Promise<void> } }).sync?.register(
          OUTBOX_SYNC_TAG,
        ) ?? Promise.resolve(),
    });
  } catch {
    feedback = { kind: 'open' };
  }
  if (feedback.kind === 'open') return open();
  if (feedback.kind === 'notify') {
    const topicId = (data as { quickr?: { topic_id?: unknown } } | null)?.quickr?.topic_id;
    await self.registration.showNotification(feedback.title, {
      body: feedback.body,
      icon: '/pwa-192x192.png',
      badge: '/badge-96x96.png',
      // no quickr data: tapping it just opens the record screen
      data: { url: safeInAppPath((data as { url?: unknown } | null)?.url) },
      ...(typeof topicId === 'string' ? { tag: `quickr.err.${topicId}` } : {}),
    });
  }
}

/**
 * Whether the API cache (the app's last GETs) shows the topic archived: `getTopic` by slug or
 * id, or any cached `listTopics` page. Undefined when it doesn't know; the server decides.
 */
async function cachedTopicState(topicId: string, slug: string | null): Promise<CachedTopicState> {
  const cache = await caches.open(SW_API_CACHE);
  const paths = [slug, topicId].flatMap((ref) =>
    ref ? [`${API_PREFIX}/topics/${encodeURIComponent(ref)}`] : [],
  );
  const candidates: Response[] = [];
  for (const path of paths) {
    const hit = await cache.match(path);
    if (hit) candidates.push(hit);
  }
  for (const request of await cache.keys()) {
    if (new URL(request.url).pathname === `${API_PREFIX}/topics`) {
      const hit = await cache.match(request);
      if (hit) candidates.push(hit);
    }
  }
  for (const response of candidates) {
    const body: unknown = await response.json().catch(() => null);
    const topics = Array.isArray((body as { items?: unknown } | null)?.items)
      ? (body as { items: unknown[] }).items
      : [body];
    for (const t of topics) {
      const topic = t as { id?: unknown; status?: unknown } | null;
      if (topic?.id === topicId && (topic.status === 'archived' || topic.status === 'active')) {
        return topic.status;
      }
    }
  }
  return undefined;
}
