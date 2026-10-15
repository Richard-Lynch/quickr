import type { Outcome } from './types';

/**
 * 4xx statuses that are worth retrying:
 * 401/403 — an auth proxy in front of the app may come back after re-login;
 * 408/425/429 — timeouts and rate limits.
 */
const RETRYABLE_4XX = new Set([401, 403, 408, 425, 429]);

/**
 * Default classification of an HTTP status (`null` = no response: offline, DNS,
 * timeout, CORS...).
 *
 * - 2xx → `ok`
 * - network / 5xx / the 4xx above → `retry` (safe: creation is idempotent by client id)
 * - every other 4xx (400, 404, 409 conflict, 422 validation...) → `terminal`: retrying the
 *   same request can never succeed, the user has to fix or discard it.
 */
export function classifyStatus(status: number | null): Outcome {
  if (status === null || status === 0) return 'retry';
  if (status >= 200 && status < 300) return 'ok';
  if (status >= 400 && status < 500) return RETRYABLE_4XX.has(status) ? 'retry' : 'terminal';
  return 'retry';
}

export const BACKOFF_BASE_MS = 2_000;
export const BACKOFF_MAX_MS = 5 * 60_000;

/**
 * Exponential backoff with ±20% jitter: ~2s, 4s, 8s … capped at 5 min.
 * `attempts` is the number of attempts already made (≥ 1).
 */
export function backoffMs(attempts: number, random: () => number = Math.random): number {
  const exp = Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** Math.max(0, attempts - 1));
  return Math.round(exp * (0.8 + random() * 0.4));
}

/** Human message for a failed response: the Problem `detail` when there is one. */
export function errorMessageFor(status: number | null, body: unknown): string {
  if (status === null) return 'Could not reach the server';
  if (typeof body === 'object' && body !== null && 'detail' in body) {
    const detail = body.detail;
    if (typeof detail === 'string' && detail.trim()) {
      const t = detail.trim();
      return t.charAt(0).toUpperCase() + t.slice(1);
    }
  }
  if (status >= 500) return `Server error (${status})`;
  return `Request failed (${status})`;
}
