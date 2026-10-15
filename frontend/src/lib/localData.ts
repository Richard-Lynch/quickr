import type { QueryClient } from '@tanstack/react-query';

import { SW_API_CACHE } from '../api/constants';
import { clearPersistedCache } from '../api/persist';
import { clearAppBadge } from './badge';
import { outbox } from './outbox/client';
import { clearStored } from './storage';

/**
 * Forget everything this device stored: the outbox (unsynced items are lost), the
 * persisted query cache, the service worker's API cache and app preferences.
 * The precached app shell is kept so the app still opens offline.
 */
export async function clearLocalData(qc: QueryClient): Promise<void> {
  await outbox.clear();
  await clearPersistedCache();
  qc.clear();
  if (typeof caches !== 'undefined') {
    await caches.delete(SW_API_CACHE).catch(() => false);
  }
  clearStored();
  await clearAppBadge();
}
