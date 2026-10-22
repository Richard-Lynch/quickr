/**
 * Chromium notification actions for quick-log reminders (docs/ios/specs/notifications.md §10,
 * PLAN B8): what a reminder offers, what a click on one means, and how it reaches the outbox.
 * Bundled into `sw.ts`; pure apart from the outbox and `crypto.subtle`.
 *
 * - An enum offers its first `Notification.maxActions` options, `{action: "log|o|" + value}`.
 * - A number with a last value offers `{action: "log|n|" + fmt(last), title: "Log …"}`.
 * - A single topic (no questions) offers `{action: "log|s|", title: "Log it"}`: no answers.
 * - No text input, no "More…" (the body opens the record screen).
 *
 * A click is validated against the notification's own data, then enqueues an `entry.create`
 * into the same IndexedDB outbox as the app. Its id is the shared action entry id (§7.4),
 * derived from (server, topic, slot) exactly as the iOS app derives it, so a second click, a
 * re-delivered push, two racing clicks or the same reminder actioned on the iPhone never log
 * twice: an item already queued is left alone, and one already sent is replayed idempotently
 * by the server (a POST with a live id returns that entry).
 */
import { ENTRY_CREATE, problemCode, type EntryCreatePayload } from './outbox/kinds';
import type { Outbox } from './outbox/outbox';
import type { OutboxItem } from './outbox/types';
import { formatQuickLogNumber, type PushPayload, type PushQuickr } from './pushPayload';

/** The namespace of the shared action entry id (notifications.md §7.4). */
export const ACTION_ENTRY_ID_PREFIX = 'quickr-action-entry-v1';

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
  if (q.type === 'single') return [{ action: 'log|s|', title: 'Log it' }];
  if (q.type === 'enum') {
    return q.options
      .slice(0, maxActions)
      .map((o) => ({ action: `log|o|${o.value}`, title: o.label }));
  }
  if (q.last_value === null) return [];
  const shown = formatQuickLogNumber(q.type, q.last_value);
  if (shown === null) return [];
  return [{ action: `log|n|${shown}`, title: q.unit ? `Log ${shown} ${q.unit}` : `Log ${shown}` }];
}

/** The answer a clicked action stands for (`key` null for a single topic: no answers), or null
 *  when it doesn't match the reminder. */
export function resolveAction(
  action: string,
  quickr: PushQuickr | null | undefined,
): { key: string; value: string | number } | { key: null; value: null } | null {
  const q = quickr?.quick_log;
  const m = /^log\|([ons])\|(.*)$/s.exec(action);
  if (!q || !m) return null;
  const [, kind, value = ''] = m;
  if (kind === 's') return q.type === 'single' && value === '' ? { key: null, value: null } : null;
  if (q.type === 'single') return null;
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
 * The shared action entry id (notifications.md §7.4): a UUID (version 8) from SHA-256 of
 * `quickr-action-entry-v1|{server_id}|{topic_id}|{due_since}`, ids lowercased, `due_since`
 * exactly as the payload carries it. The iOS handler derives the same id
 * (`shared/fixtures/action-entry-id-vectors.json`).
 */
export async function actionEntryId(
  serverId: string,
  topicId: string,
  dueSince: string,
): Promise<string> {
  const name = new TextEncoder().encode(
    `${ACTION_ENTRY_ID_PREFIX}|${serverId.toLowerCase()}|${topicId.toLowerCase()}|${dueSince}`,
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
  /** This slot's entry is already queued (`existing`): nothing changed. */
  | { status: 'duplicate'; id: string; existing: OutboxItem<EntryCreatePayload> }
  /** The action doesn't match the reminder (or it isn't actionable): open the app instead. */
  | { status: 'invalid' };

interface LockManagerLike {
  request<T>(name: string, fn: () => Promise<T>): Promise<T>;
}

function readData(raw: unknown): Partial<NotificationData> {
  if (typeof raw !== 'object' || raw === null) return {};
  return raw; // written by notificationData; every field is optional
}

/**
 * Validates a click on a reminder action and enqueues its entry once per slot, carrying the
 * reminder's `server_id` as the request's identity precondition. Durable before any network:
 * the caller sends it afterwards.
 */
export async function logFromAction(opts: {
  outbox: Pick<Outbox, 'get' | 'enqueue'>;
  action: string;
  data: unknown;
  now?: () => number;
  locks?: LockManagerLike | undefined;
}): Promise<ActionResult> {
  const data = readData(opts.data);
  const q = data.quickr ?? null;
  const answer = resolveAction(opts.action, q);
  if (!q || !answer) return { status: 'invalid' };
  const id = await actionEntryId(q.server_id, q.topic_id, q.due_since);
  const now = opts.now ?? Date.now;
  const payload: EntryCreatePayload = {
    topic: { id: q.topic_id, slug: data.topic_slug ?? '', name: data.title ?? '' },
    body: {
      answers: answer.key === null ? {} : { [answer.key]: answer.value },
      version: q.version,
      captured_at: new Date(now()).toISOString(),
      source: PWA_NOTIFICATION_SOURCE,
      notes: '',
      meta: {},
    },
    expect_server_id: q.server_id,
  };
  const run = async (): Promise<ActionResult> => {
    const existing = await opts.outbox.get(id);
    if (existing) {
      return { status: 'duplicate', id, existing: existing as OutboxItem<EntryCreatePayload> };
    }
    await opts.outbox.enqueue(ENTRY_CREATE, payload, { id });
    return { status: 'enqueued', id };
  };
  return opts.locks ? opts.locks.request(PUSH_ACTION_LOCK, run) : run();
}

/** What the service worker shows after handling an action click. */
export type ActionFeedback =
  /** Logged, or queued while offline: nothing more to show. */
  | { kind: 'none' }
  /** The click can't be handled here: open the record screen (`url`). */
  | { kind: 'open' }
  /** A follow-up notification whose click opens the record screen. */
  | { kind: 'notify'; title: string; body: string };

/** The topic's state as far as the service worker knows it (from cached API responses). */
export type CachedTopicState = 'active' | 'archived' | undefined;

const NONE: ActionFeedback = { kind: 'none' };

/**
 * A click on a reminder action, end to end (notifications.md §10): validate, refuse an
 * archived topic the cache knows of, enqueue once per slot, send now, and turn the outcome
 * into feedback, so a failure never just dismisses the reminder:
 * - logged, or queued offline (Background Sync or the app sends it later): nothing;
 * - an invalid action, or the outbox can't be written (storage, lock): open the app;
 * - the server refused it, or the slot's entry already holds another choice (the first
 *   choice wins, §7.4): a notification saying so, which opens the record screen.
 */
export async function handleReminderAction(opts: {
  outbox: Pick<Outbox, 'get' | 'enqueue' | 'sendNow' | 'discard'>;
  action: string;
  data: unknown;
  now?: () => number;
  locks?: LockManagerLike | undefined;
  topicState?: (topicId: string, slug: string | null) => Promise<CachedTopicState>;
  /** Called when the entry is still queued (offline): register Background Sync. */
  queued?: () => Promise<void>;
  sendTimeoutMs?: number;
}): Promise<ActionFeedback> {
  const data = readData(opts.data);
  const q = data.quickr ?? null;
  const answer = resolveAction(opts.action, q);
  if (!q || !answer) return { kind: 'open' };
  const topic = data.title || 'this topic';

  let state: CachedTopicState;
  try {
    state = await opts.topicState?.(q.topic_id, data.topic_slug ?? null);
  } catch {
    state = undefined;
  }
  if (state === 'archived') {
    return {
      kind: 'notify',
      title: `Couldn’t log ${topic}`,
      body: 'The topic is archived. Open quickR to log.',
    };
  }

  let result: ActionResult;
  try {
    result = await logFromAction(opts);
  } catch {
    return { kind: 'open' };
  }
  if (result.status === 'invalid') return { kind: 'open' };
  if (result.status === 'duplicate') {
    if (answer.key === null) return NONE; // a single topic's entry has nothing to differ in
    const first = result.existing.payload.body.answers[answer.key];
    return first === undefined || first === answer.value ? NONE : alreadyLogged(q, first);
  }

  const sent = await opts.outbox.sendNow(result.id, opts.sendTimeoutMs ?? 8_000);
  switch (sent.status) {
    case 'sent': {
      // A replay of the slot's create returns the entry that was logged first (§7.4).
      if (answer.key === null) return NONE;
      const logged = loggedAnswer(sent.data, answer.key);
      return logged === undefined || logged === answer.value ? NONE : alreadyLogged(q, logged);
    }
    case 'queued':
      try {
        await opts.queued?.();
      } catch {
        // no Background Sync: the app sends it on its next start
      }
      return NONE;
    case 'discarded':
      return NONE;
    case 'retired':
      return {
        kind: 'notify',
        title: `Couldn’t log ${topic}`,
        body: 'This reminder’s entry was deleted. Open quickR to log again.',
      };
    case 'failed':
      return refused(sent.item, topic, opts.outbox);
  }
}

/** A failed create: say why; one meant for another server is dropped (it never can succeed). */
async function refused(
  item: OutboxItem,
  topic: string,
  outbox: Pick<Outbox, 'discard'>,
): Promise<ActionFeedback> {
  const code = problemCode(item.last_error?.body);
  const title = `Couldn’t log ${topic}`;
  if (code === 'server_mismatch') {
    await outbox.discard(item.id).catch(() => undefined);
    return {
      kind: 'notify',
      title,
      body: 'This reminder came from another quickR server, so nothing was logged.',
    };
  }
  if (code === 'topic_archived') {
    return { kind: 'notify', title, body: 'The topic is archived. Open quickR to log.' };
  }
  if (item.last_error?.status === 404) {
    return { kind: 'notify', title, body: 'The topic was deleted.' };
  }
  const reason = item.last_error?.message ?? 'The server refused it';
  return { kind: 'notify', title, body: `${reason}. Open quickR to fix it.` };
}

function alreadyLogged(q: PushQuickr, value: unknown): ActionFeedback {
  return {
    kind: 'notify',
    title: 'Already logged',
    body: `This reminder was already logged as ${answerLabel(q, value)}. Open quickR to change it.`,
  };
}

/** How an answer reads on the reminder's buttons: the option label, or the number and unit. */
export function answerLabel(q: PushQuickr, value: unknown): string {
  const log = q.quick_log;
  if (log.type === 'single') return 'it';
  if (log.type === 'enum') {
    return log.options.find((o) => o.value === value)?.label ?? String(value);
  }
  const shown = typeof value === 'number' ? formatQuickLogNumber(log.type, value) : null;
  const text = shown ?? String(value);
  return log.unit ? `${text} ${log.unit}` : text;
}

/** The value of `key` in an `EntryOut` response body, if it has one. */
function loggedAnswer(entry: unknown, key: string): unknown {
  if (typeof entry !== 'object' || entry === null) return undefined;
  const answers = (entry as { answers?: unknown }).answers;
  if (!Array.isArray(answers)) return undefined;
  const found = answers.find(
    (a): a is { key: string; value: unknown } =>
      typeof a === 'object' && a !== null && (a as { key?: unknown }).key === key,
  );
  return found?.value;
}
