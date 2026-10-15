/**
 * Durable mutation outbox — shared types.
 *
 * Everything under `src/lib/outbox/` except `react.tsx`, `client.ts` and `effects.ts` is
 * environment-agnostic (no `window`, no React) because the service worker bundles it to
 * flush the queue from a Background Sync event.
 */

/** `pending` = will be (re)sent automatically; `failed` = terminal, needs the user. */
export type OutboxStatus = 'pending' | 'failed';

export interface OutboxError {
  message: string;
  /** HTTP status, or `null` for network errors, timeouts and client-side failures. */
  status: number | null;
  /** Parsed JSON error body (usually a `Problem` envelope) when the server sent one. */
  body?: unknown;
}

export interface OutboxItem<P = unknown> {
  /** Client-generated UUID. Also the idempotency key once the API accepts it. */
  id: string;
  /** Registry key, e.g. `entry.create` (see `kinds.ts`). */
  kind: string;
  payload: P;
  /** ISO timestamp of the original enqueue (the user's action). */
  created_at: string;
  updated_at: string;
  /** Number of send attempts made so far. */
  attempts: number;
  status: OutboxStatus;
  /** Epoch ms before which automatic flushes skip this item (backoff). */
  next_attempt_at: number;
  last_error: OutboxError | null;
}

export interface OutboxRequest {
  method: 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  /** Same-origin path, e.g. `/api/v1/topics/{ref}/sessions`. */
  url: string;
  /** JSON-serialisable body. */
  body?: unknown;
}

/** What to do with an item after an attempt. */
export type Outcome = 'ok' | 'retry' | 'terminal';

export interface OutboxKind<P = unknown> {
  /**
   * Build the HTTP request at send time (not at enqueue time), so code updates — e.g.
   * starting to send the client id — apply to items already waiting in the queue.
   */
  toRequest(item: OutboxItem<P>): OutboxRequest;
  /** Override the default status classification (e.g. treat 404 on DELETE as done). */
  classify?(status: number): Outcome | undefined;
}

export type OutboxEvent =
  | { type: 'enqueued'; item: OutboxItem }
  | { type: 'updated'; item: OutboxItem }
  | { type: 'sent'; item: OutboxItem; data: unknown }
  | { type: 'retrying'; item: OutboxItem }
  | { type: 'failed'; item: OutboxItem }
  | { type: 'discarded'; item: OutboxItem }
  | { type: 'cleared' };

export interface FlushResult {
  sent: number;
  failed: number;
  retrying: number;
  /** Items still in the outbox (pending + failed) after the flush. */
  remaining: number;
}

export type SendNowResult =
  | { status: 'sent'; data: unknown }
  | { status: 'failed'; item: OutboxItem }
  | { status: 'queued'; item: OutboxItem | undefined }
  | { status: 'discarded' };
