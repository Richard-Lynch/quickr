/**
 * Transport constants shared by the app, the outbox and the service worker.
 * Keep this module dependency-free: it is bundled into `sw.ts` too.
 */

/** Same-origin API prefix (paths in the OpenAPI spec already carry it). */
export const API_PREFIX = '/api/v1';

/**
 * Header that tags requests made by the UI.
 * TODO(api-v2): the backend renames this to `X-QuickR-Channel` — change it here only.
 */
export const CHANNEL_HEADER = 'X-Quicker-Channel';
export const CHANNEL = 'ui';

export const CHANNEL_HEADERS: Readonly<Record<string, string>> = { [CHANNEL_HEADER]: CHANNEL };

/** Cache Storage bucket the service worker uses for GET /api/v1/* responses. */
export const SW_API_CACHE = 'quickr-api';
