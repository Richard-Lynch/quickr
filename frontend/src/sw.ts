/// <reference lib="webworker" />
/**
 * quickR service worker (vite-plugin-pwa `injectManifest`; typechecked by tsconfig.sw.json).
 *
 * - precaches the app shell, SPA navigation fallback to index.html
 * - NetworkFirst (short timeout) for GET /api/v1/* JSON as an offline fallback layer;
 *   never caches /mcp, non-GET requests, CSV exports or push endpoints
 * - update flow: waits until the page asks it to SKIP_WAITING (no surprise reloads)
 * - Background Sync: flushes the IndexedDB outbox where supported (Chromium)
 * - Web Push: shows notifications, routes clicks into the app
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

import { API_PREFIX, CHANNEL_HEADERS, SW_API_CACHE } from './api/constants';
import { OUTBOX_KINDS, OUTBOX_SYNC_TAG } from './lib/outbox/kinds';
import { createOutbox } from './lib/outbox/outbox';
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
];

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

const outbox = createOutbox({ kinds: OUTBOX_KINDS, headers: CHANNEL_HEADERS });

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
  // userVisibleOnly: every push must show a notification (Safari revokes otherwise).
  event.waitUntil(
    self.registration.showNotification(p.title, {
      body: p.body,
      icon: '/pwa-192x192.png',
      badge: '/badge-96x96.png',
      data: { url: p.url, topic_slug: p.topic_slug ?? null },
      ...(p.tag ? { tag: p.tag } : {}),
    }),
  );
});

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
  event.waitUntil(focusOrOpen(safeInAppPath(data?.url)));
});
