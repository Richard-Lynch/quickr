/**
 * Transport constants shared by the app, the outbox and the service worker.
 * Keep this module dependency-free: it is bundled into `sw.ts` too.
 */

/** Same-origin API prefix (paths in the OpenAPI spec already carry it). */
export const API_PREFIX = '/api/v1';

/** Header that tags requests made by the UI (`channel: ui` on the server). */
export const CHANNEL_HEADER = 'X-QuickR-Channel';
export const CHANNEL = 'ui';

export const CHANNEL_HEADERS: Readonly<Record<string, string>> = { [CHANNEL_HEADER]: CHANNEL };

/** Cache Storage bucket the service worker uses for GET /api/v1/* responses. */
export const SW_API_CACHE = 'quickr-api';

/** Set by the service worker on an API response it answered from its cache. */
export const FROM_CACHE_HEADER = 'X-QuickR-From-Cache';
