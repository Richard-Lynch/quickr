/**
 * Chromium notification actions for quick-log reminders (docs/ios/specs/notifications.md §10,
 * PLAN B8): what a reminder offers, what a click on one means, and how it reaches the outbox.
 * Bundled into `sw.ts`; pure apart from the outbox and `crypto.subtle`.
 *
 * - An enum offers its first `Notification.maxActions` options, `{action: "log|o|" + value}`.
 * - A number with a last value offers `{action: "log|n|" + fmt(last), title: "✓ …"}`.
 * - No text input, no "More…" (the body opens the record screen).
 *
 * A click is validated against the notification's own data, then enqueues an `entry.create`
 * into the same IndexedDB outbox as the app. Its id is derived from the reminder's slot, so a
 * second click, a re-delivered push or two racing clicks never log twice: an item already
 * queued is left alone, and one already sent is replayed idempotently by the server (a POST
 * with a live id returns that entry).
 */
import { ENTRY_CREATE, type EntryCreatePayload } from './outbox/kinds';
import type { Outbox } from './outbox/outbox';
import { formatQuickLogNumber, type PushPayload, type PushQuickr } from './pushPayload';

/** `source` of entries logged from a PWA notification action. */
export const PWA_NOTIFICATION_SOURCE = 'pwa.notification';

/** Web Lock serialising action handling (check-then-enqueue), across clicks and contexts. */
export const PUSH_ACTION_LOCK = 'quickr-push-action';

/** `NotificationAction` (not in every TS lib: lib.webworker dropped it). */
export interface PushAction {
  action: string;
  title: string;
}

/** What a reminder stores in `Notification.data` for the click handler. */
export interface NotificationData {
  url: string;
  topic_slug: string | null;
  /** The topic name, as the push title shows it (for the queued item's label). */
  title: string;
  quickr: PushQuickr | null;
}

export function notificationData(p: PushPayload): NotificationData {
  return { url: p.url, topic_slug: p.topic_slug ?? null, title: p.title, quickr: p.quickr ?? null };
}

/** The actions a reminder offers, at most `maxActions` (0 where actions are unsupported). */
export function pushActions(p: PushPayload, maxActions: number): PushAction[] {
  const q = p.quickr?.quick_log;
  if (!q || maxActions <= 0) return [];
  if (q.type === 'enum') {
    return q.options
      .slice(0, maxActions)
      .map((o) => ({ action: `log|o|${o.value}`, title: o.label }));
  }
  if (q.last_value === null) return [];
  const shown = formatQuickLogNumber(q.type, q.last_value);
  if (shown === null) return [];
  return [{ action: `log|n|${shown}`, title: q.unit ? `✓ ${shown} ${q.unit}` : `✓ ${shown}` }];
}

/** The answer a clicked action stands for, or null when it doesn't match the reminder. */
export function resolveAction(
  action: string,
  quickr: PushQuickr | null | undefined,
): { key: string; value: string | number } | null {
  const q = quickr?.quick_log;
  const m = /^log\|([on])\|(.*)$/s.exec(action);
  if (!q || !m) return null;
  const [, kind, value = ''] = m;
  if (kind === 'o') {
    return q.type === 'enum' && q.options.some((o) => o.value === value)
      ? { key: q.key, value }
      : null;
  }
  if (q.type === 'enum' || q.last_value === null) return null;
  return formatQuickLogNumber(q.type, q.last_value) === value
    ? { key: q.key, value: q.last_value }
    : null;
}

/**
 * The entry id for an action on a reminder: a UUID (version 8, name-based on SHA-256) of the
 * topic and the slot. One reminder slot logs at most one entry, whichever action was clicked.
 */
export async function actionEntryId(topicId: string, dueSince: string): Promise<string> {
  const name = new TextEncoder().encode(
    `quickr-pwa-action-v1|${topicId.toLowerCase()}|${dueSince}`,
  );
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', name)).slice(0, 16);
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x80; // version 8
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80; // RFC 9562 variant
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export type ActionResult =
  /** A new `entry.create` was queued (`id`). */
  | { status: 'enqueued'; id: string }
  /** This slot's entry is already queued: nothing changed. */
  | { status: 'duplicate'; id: string }
  /** The action doesn't match the reminder (or it isn't actionable): open the app instead. */
  | { status: 'invalid' };

interface LockManagerLike {
  request<T>(name: string, fn: () => Promise<T>): Promise<T>;
}

/**
 * Handles a click on a reminder action: validate, then enqueue once per slot. Durable before
 * any network: the caller flushes afterwards.
 */
export async function logFromAction(opts: {
  outbox: Pick<Outbox, 'get' | 'enqueue'>;
  action: string;
  data: unknown;
  now?: () => number;
  locks?: LockManagerLike | undefined;
}): Promise<ActionResult> {
  const data = (
    typeof opts.data === 'object' && opts.data !== null ? opts.data : {}
  ) as Partial<NotificationData>;
  const q = data.quickr ?? null;
  const answer = resolveAction(opts.action, q);
  if (!q || !answer) return { status: 'invalid' };
  const id = await actionEntryId(q.topic_id, q.due_since);
  const now = opts.now ?? Date.now;
  const payload: EntryCreatePayload = {
    topic: { id: q.topic_id, slug: data.topic_slug ?? '', name: data.title ?? '' },
    body: {
      answers: { [answer.key]: answer.value },
      version: q.version,
      captured_at: new Date(now()).toISOString(),
      source: PWA_NOTIFICATION_SOURCE,
      notes: '',
      meta: {},
    },
  };
  const run = async (): Promise<ActionResult> => {
    if (await opts.outbox.get(id)) return { status: 'duplicate', id };
    await opts.outbox.enqueue(ENTRY_CREATE, payload, { id });
    return { status: 'enqueued', id };
  };
  return opts.locks ? opts.locks.request(PUSH_ACTION_LOCK, run) : run();
}
