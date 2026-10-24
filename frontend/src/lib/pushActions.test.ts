/**
 * PWA notification actions (docs/ios/specs/notifications.md §10, PLAN B8): the actions a
 * reminder offers (checked against the cross-platform vectors the server and iOS share), click
 * validation, and the action → outbox path with its once-per-slot de-duplication.
 */
import 'fake-indexeddb/auto';
import { describe, expect, it, vi } from 'vitest';

import idRaw from '../../../shared/fixtures/action-entry-id-vectors.json?raw';
import raw from '../../../shared/fixtures/notification-vectors.json?raw';
import { uuid } from './uuid';
import {
  ENTRY_CREATE,
  OUTBOX_KINDS,
  RUN_EVENT,
  type EntryCreatePayload,
  type RunEventPayload,
} from './outbox/kinds';
import { createOutbox } from './outbox/outbox';
import { idbOutboxStore, memoryOutboxStore } from './outbox/store';
import { fakeQuickrServer } from '../test/fakeQuickrServer';
import {
  actionEntryId,
  answerLabel,
  handleReminderAction,
  isStartAction,
  logFromAction,
  notificationData,
  PWA_NOTIFICATION_SOURCE,
  pushActions,
  resolveAction,
  START_ACTION,
  startVersionOf,
  startVersionOfTopic,
} from './pushActions';
import { formatQuickLogNumber, parsePushPayload, type PushPayload } from './pushPayload';
import { ackedItems, memoryAckedStore, setAckedStore } from './runs/acked';
import { tapRun } from './runs/actions';
import { formatInstant } from './runs/instant';
import type { OutboxItem } from './outbox/types';

interface VectorAction {
  kind: 'log' | 'input' | 'open' | 'start';
  identifier: string;
  title: string;
}
interface Vectors {
  cases: {
    name: string;
    server_id: string;
    topic_id: string;
    version: number;
    expected: { quick_log: unknown; actions: VectorAction[] };
  }[];
  fmt: { kind: 'int' | 'double'; value: number; expected: string }[];
}

const vectors = JSON.parse(raw) as Vectors;
const idVectors = JSON.parse(idRaw) as {
  cases: {
    name: string;
    server_id: string;
    topic_id: string;
    due_since: string;
    expected: string;
  }[];
};

const SERVER = '0b9e0000-0000-4000-8000-0000000000aa';
const TOPIC = '6f1c0000-0000-4000-8000-000000000001';
const SLOT = '2026-10-17T08:00:00Z';

function reminder(quickLog: unknown, patch: Record<string, unknown> = {}): PushPayload {
  return parsePushPayload({
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
    due_since: SLOT,
    quick_log: quickLog,
    ...patch,
  });
}

const enumLog = {
  type: 'enum',
  key: 'mood',
  label: 'Mood',
  options: [
    { value: 'good', label: 'Good' },
    { value: 'ok', label: 'OK' },
    { value: 'bad', label: 'Bad' },
  ],
  total_options: 3,
};

const numberLog = {
  type: 'double',
  key: 'hours',
  label: 'Sleep',
  unit: 'h',
  min: 0,
  max: 24,
  decimals: 1,
  last_value: 7.5,
};

describe('formatQuickLogNumber (§4.4 fmt)', () => {
  it.each(vectors.fmt.map((c) => [c.kind, c.value, c.expected] as const))(
    '%s %s → %s',
    (kind, value, expected) => {
      // JSON numbers beyond 2^53 lose digits in JS: the PWA offers no action for them.
      if (kind === 'int' && !Number.isSafeInteger(value)) {
        expect(formatQuickLogNumber(kind, value)).toBeNull();
      } else {
        expect(formatQuickLogNumber(kind, value)).toBe(expected);
      }
    },
  );

  it('refuses non-finite values', () => {
    expect(formatQuickLogNumber('double', Number.NaN)).toBeNull();
    expect(formatQuickLogNumber('double', Number.POSITIVE_INFINITY)).toBeNull();
  });
});

describe('pushActions', () => {
  // The log and start actions of every vector case, in order, as the PWA renders them (§10):
  // no input action, no "More…".
  it.each(
    vectors.cases.filter((c) => c.expected.quick_log !== null).map((c) => [c.name, c] as const),
  )('matches the shared vectors: %s', (_name, c) => {
    const p = reminder(c.expected.quick_log, { topic_id: c.topic_id, version: c.version });
    const expected = c.expected.actions
      .filter((a) => a.kind === 'log' || a.kind === 'start')
      .map((a) => {
        const parts = a.identifier.split('|');
        return { action: `log|${parts[5]}|${parts.slice(6).join('|')}`, title: a.title };
      });
    const q = p.quickr?.quick_log;
    const unsafeInt =
      q?.type === 'int' && q.last_value !== null && !Number.isSafeInteger(q.last_value);
    expect(pushActions(p, 99)).toEqual(unsafeInt ? [] : expected);
  });

  it('offers at most maxActions, and none where actions are unsupported', () => {
    const p = reminder(enumLog);
    expect(pushActions(p, 2)).toEqual([
      { action: 'log|o|good', title: 'Good' },
      { action: 'log|o|ok', title: 'OK' },
    ]);
    expect(pushActions(p, 0)).toEqual([]);
    expect(pushActions(reminder(numberLog), 2)).toEqual([
      { action: 'log|n|7.5', title: 'Log 7.5 h' },
    ]);
    expect(pushActions(reminder({ ...numberLog, last_value: null }), 2)).toEqual([]);
  });

  it('offers nothing for test pushes, newer payload versions or malformed descriptors', () => {
    expect(pushActions(reminder(enumLog, { kind: 'test' }), 2)).toEqual([]);
    expect(pushActions(reminder(enumLog, { v: 2 }), 2)).toEqual([]);
    expect(pushActions(reminder(enumLog, { due_since: undefined }), 2)).toEqual([]);
    // no server id, no shared entry id (§7.4): display-only
    expect(pushActions(reminder(enumLog, { server_id: undefined }), 2)).toEqual([]);
    expect(pushActions(reminder({ ...enumLog, options: [{ value: 1 }] }), 2)).toEqual([]);
    expect(pushActions(reminder({ type: 'str', key: 'note' }), 2)).toEqual([]);
    // the original 5-field payload still parses (older servers)
    expect(parsePushPayload({ title: 'Water', url: '/t/water/record' }).quickr).toBeUndefined();
  });
});

describe('resolveAction', () => {
  const enumQ = reminder(enumLog).quickr;
  const numberQ = reminder(numberLog).quickr;

  it('maps a valid action to its answer', () => {
    expect(resolveAction('log|o|ok', enumQ)).toEqual({ key: 'mood', value: 'ok' });
    expect(resolveAction('log|n|7.5', numberQ)).toEqual({ key: 'hours', value: 7.5 });
  });

  it('rejects tampered, foreign or mismatched actions', () => {
    expect(resolveAction('log|o|great', enumQ)).toBeNull();
    expect(resolveAction('log|n|7.5', enumQ)).toBeNull();
    expect(resolveAction('log|o|ok', numberQ)).toBeNull();
    expect(resolveAction('log|n|8', numberQ)).toBeNull();
    expect(resolveAction('open', enumQ)).toBeNull();
    expect(resolveAction('log|o|ok', null)).toBeNull();
  });
});

describe('actionEntryId (§7.4, shared with the iOS handler)', () => {
  it.each(idVectors.cases.map((c) => [c.name, c] as const))(
    'matches the shared vectors: %s',
    async (_name, c) => {
      expect(await actionEntryId(c.server_id, c.topic_id, c.due_since)).toBe(c.expected);
    },
  );

  it('is a version-8 UUID that changes with the server, topic and slot', async () => {
    const id = await actionEntryId(SERVER, TOPIC, SLOT);
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(await actionEntryId(SERVER, TOPIC, '2026-10-17T09:00:00Z')).not.toBe(id);
    expect(await actionEntryId(uuid(), TOPIC, SLOT)).not.toBe(id);
    expect(await actionEntryId(SERVER, uuid(), SLOT)).not.toBe(id);
  });
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function setup(responses: Response[] = []) {
  const fetchMock = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(
    () => {
      const next = responses.shift();
      return next ? Promise.resolve(next) : Promise.reject(new TypeError('Failed to fetch'));
    },
  );
  const outbox = createOutbox({
    kinds: OUTBOX_KINDS,
    store: memoryOutboxStore(),
    fetch: fetchMock,
    channelName: null,
    random: () => 0.5,
  });
  return { outbox, fetchMock };
}

/** A Web Lock stand-in: runs callbacks one at a time, in order. */
function serialLock() {
  let tail: Promise<unknown> = Promise.resolve();
  return {
    request<T>(_name: string, fn: () => Promise<T>): Promise<T> {
      const run = tail.then(fn);
      tail = run.catch(() => undefined);
      return run;
    },
  };
}

describe('logFromAction', () => {
  const data = notificationData(reminder(enumLog));
  const now = () => Date.parse('2026-10-17T08:05:00Z');

  it('queues one entry.create with the answer, the push version and the PWA source', async () => {
    const { outbox } = setup();
    const result = await logFromAction({ outbox, action: 'log|o|ok', data, now });
    expect(result).toEqual({ status: 'enqueued', id: await actionEntryId(SERVER, TOPIC, SLOT) });
    const [item] = await outbox.list();
    expect(item?.kind).toBe(ENTRY_CREATE);
    expect(item?.payload).toEqual({
      topic: { id: TOPIC, slug: 'mood', name: 'Mood' },
      body: {
        answers: { mood: 'ok' },
        version: 3,
        captured_at: '2026-10-17T08:05:00.000Z',
        source: PWA_NOTIFICATION_SOURCE,
        notes: '',
        meta: {},
      },
      expect_server_id: SERVER,
    } satisfies EntryCreatePayload);
  });

  it('logs the number action as the number itself', async () => {
    const { outbox } = setup();
    await logFromAction({
      outbox,
      action: 'log|n|7.5',
      data: notificationData(reminder(numberLog)),
      now,
    });
    const [item] = await outbox.list();
    expect((item?.payload as EntryCreatePayload).body.answers).toEqual({ hours: 7.5 });
  });

  it('never queues a second entry for the same reminder', async () => {
    const { outbox } = setup();
    const first = await logFromAction({ outbox, action: 'log|o|ok', data, now });
    const before = await outbox.list();
    // the same action again, another option, a re-delivered push of the same slot
    expect(
      await logFromAction({ outbox, action: 'log|o|ok', data, now: () => now() + 1000 }),
    ).toEqual({
      status: 'duplicate',
      id: (first as { id: string }).id,
      existing: before[0],
    });
    expect((await logFromAction({ outbox, action: 'log|o|bad', data, now })).status).toBe(
      'duplicate',
    );
    const again = notificationData(reminder(enumLog, { title: 'Mood (again)' }));
    expect((await logFromAction({ outbox, action: 'log|o|ok', data: again, now })).status).toBe(
      'duplicate',
    );
    expect(await outbox.list()).toEqual(before);
  });

  it('serialises racing clicks so only one is queued', async () => {
    const { outbox } = setup();
    const locks = serialLock();
    const results = await Promise.all(
      ['log|o|ok', 'log|o|good', 'log|o|ok'].map((action) =>
        logFromAction({ outbox, action, data, now, locks }),
      ),
    );
    expect(results.map((r) => r.status).sort()).toEqual(['duplicate', 'duplicate', 'enqueued']);
    expect(await outbox.list()).toHaveLength(1);
  });

  it('another slot of the same topic is a new entry', async () => {
    const { outbox } = setup();
    await logFromAction({ outbox, action: 'log|o|ok', data, now });
    const next = notificationData(reminder(enumLog, { due_since: '2026-10-17T20:00:00Z' }));
    expect((await logFromAction({ outbox, action: 'log|o|ok', data: next, now })).status).toBe(
      'enqueued',
    );
    expect(await outbox.list()).toHaveLength(2);
  });

  it('rejects an invalid action without touching the outbox', async () => {
    const { outbox } = setup();
    expect(await logFromAction({ outbox, action: 'log|o|great', data, now })).toEqual({
      status: 'invalid',
    });
    expect(await logFromAction({ outbox, action: 'log|o|ok', data: { url: '/' }, now })).toEqual({
      status: 'invalid',
    });
    expect(await outbox.list()).toEqual([]);
  });

  it('sends the entry with its slot id; a click after it was sent replays the same id', async () => {
    const created = { id: 'x' };
    const { outbox, fetchMock } = setup([json(201, created), json(201, created)]);
    const first = await logFromAction({ outbox, action: 'log|o|ok', data, now });
    expect((await outbox.flush({ force: true })).sent).toBe(1);
    expect(await outbox.list()).toEqual([]);
    // A second click after the send: queued again with the same id, which the server answers
    // with the existing entry (POST replay is idempotent), so nothing is logged twice.
    const second = await logFromAction({ outbox, action: 'log|o|bad', data, now });
    expect(second).toEqual(first);
    await outbox.flush({ force: true });
    const bodies = fetchMock.mock.calls.map(
      ([, init]) => JSON.parse(init?.body as string) as { id: string },
    );
    expect(bodies.map((b) => b.id)).toEqual([
      (first as { id: string }).id,
      (first as { id: string }).id,
    ]);
    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe(`/api/v1/topics/${TOPIC}/entries`);
    expect(init?.method).toBe('POST');
    expect(JSON.parse(init?.body as string)).toMatchObject({
      answers: { mood: 'ok' },
      version: 3,
      source: PWA_NOTIFICATION_SOURCE,
    });
  });

  it('is durable before the network: offline, the entry waits in IndexedDB for the app', async () => {
    const store = idbOutboxStore(`test-${uuid()}`);
    const sw = createOutbox({
      kinds: OUTBOX_KINDS,
      store,
      fetch: () => Promise.reject(new TypeError('offline')),
      channelName: null,
    });
    await logFromAction({ outbox: sw, action: 'log|o|ok', data, now });
    const result = await sw.flush({ force: true });
    expect(result).toMatchObject({ sent: 0, retrying: 1, remaining: 1 });
    // The app (another context on the same IndexedDB) sees and sends it.
    const appFetch = vi.fn(() => Promise.resolve(json(201, { id: 'x' })));
    const app = createOutbox({ kinds: OUTBOX_KINDS, store, fetch: appFetch, channelName: null });
    expect(await app.list()).toHaveLength(1);
    expect((await app.flush({ force: true })).sent).toBe(1);
    expect(await app.list()).toEqual([]);
  });
});

describe('handleReminderAction', () => {
  const data = notificationData(reminder(enumLog));

  function rig(serverId = SERVER) {
    const server = fakeQuickrServer(serverId, [TOPIC]);
    const outbox = createOutbox({
      kinds: OUTBOX_KINDS,
      store: memoryOutboxStore(),
      fetch: server.fetch,
      channelName: null,
      random: () => 0.5,
    });
    const queued = vi.fn(() => Promise.resolve());
    const click = (action: string, d: unknown = data, extra: Record<string, unknown> = {}) =>
      handleReminderAction({ outbox, action, data: d, queued, sendTimeoutMs: 2000, ...extra });
    return { server, outbox, queued, click };
  }

  it('logs against the reminder’s server and shows nothing more', async () => {
    const { server, outbox, click } = rig();
    expect(await click('log|o|ok')).toEqual({ kind: 'none' });
    expect([...server.entries.values()]).toMatchObject([
      { topic_id: TOPIC, answers: [{ key: 'mood', value: 'ok' }], source: PWA_NOTIFICATION_SOURCE },
    ]);
    expect(server.requests[0]?.headers['x-quickr-expect-server-id']).toBe(SERVER);
    expect(await outbox.list()).toEqual([]);
  });

  it('writes nothing when the origin now serves another server, and says so', async () => {
    const { server, outbox, click } = rig('0b9e0000-0000-4000-8000-0000000000bb');
    const feedback = await click('log|o|ok');
    expect(feedback).toEqual({
      kind: 'notify',
      title: 'Couldn’t log Mood',
      body: 'This reminder came from another quickR server, so nothing was logged.',
    });
    expect(server.entries.size).toBe(0);
    expect(await outbox.list()).toEqual([]); // it can never succeed: dropped
  });

  it('reports an archived topic (the item stays failed for the app) and a deleted one', async () => {
    const archived = rig();
    archived.server.topics.set(TOPIC, { status: 'archived' });
    expect(await archived.click('log|o|ok')).toEqual({
      kind: 'notify',
      title: 'Couldn’t log Mood',
      body: 'The topic is archived. Open quickR to log.',
    });
    expect((await archived.outbox.list()).map((i) => i.status)).toEqual(['failed']);

    const deleted = rig();
    deleted.server.topics.clear();
    expect(await deleted.click('log|o|ok')).toMatchObject({
      kind: 'notify',
      body: 'The topic was deleted.',
    });
  });

  it('refuses an archived topic the cache knows of, before queueing anything', async () => {
    const { server, outbox, click } = rig();
    const feedback = await click('log|o|ok', data, {
      topicState: () => Promise.resolve('archived'),
    });
    expect(feedback).toMatchObject({
      kind: 'notify',
      body: 'The topic is archived. Open quickR to log.',
    });
    expect(server.requests).toEqual([]);
    expect(await outbox.list()).toEqual([]);
  });

  it('reports a reminder whose entry was deleted (its id is reserved)', async () => {
    const { server, click } = rig();
    server.deleted.add(await actionEntryId(SERVER, TOPIC, SLOT));
    expect(await click('log|o|ok')).toMatchObject({
      kind: 'notify',
      body: 'This reminder’s entry was deleted. Open quickR to log again.',
    });
  });

  it('offline is not a failure: the entry waits and Background Sync is asked for', async () => {
    const { server, outbox, queued, click } = rig();
    server.offline = true;
    expect(await click('log|o|ok')).toEqual({ kind: 'none' });
    expect(queued).toHaveBeenCalledOnce();
    expect((await outbox.list()).map((i) => i.status)).toEqual(['pending']);
  });

  it('the first choice wins, visibly: a later different choice says what was logged', async () => {
    // After the first was sent: the replay returns the first entry.
    const sent = rig();
    expect(await sent.click('log|o|ok')).toEqual({ kind: 'none' });
    expect(await sent.click('log|o|bad')).toEqual({
      kind: 'notify',
      title: 'Already logged',
      body: 'This reminder was already logged as OK. Open quickR to change it.',
    });
    expect(await sent.click('log|o|ok')).toEqual({ kind: 'none' });
    expect([...sent.server.entries.values()].map((e) => e.answers)).toEqual([
      [{ key: 'mood', value: 'ok' }],
    ]);

    // While the first is still queued (offline).
    const queued = rig();
    queued.server.offline = true;
    await queued.click('log|o|ok');
    expect(await queued.click('log|o|bad')).toMatchObject({
      kind: 'notify',
      body: 'This reminder was already logged as OK. Open quickR to change it.',
    });
    expect(await queued.click('log|o|ok')).toEqual({ kind: 'none' });
    expect(await queued.outbox.list()).toHaveLength(1);
  });

  it('opens the app when the click can’t be handled here', async () => {
    const { outbox, click } = rig();
    expect(await click('log|o|great')).toEqual({ kind: 'open' });
    expect(await click('log|o|ok', { url: '/' })).toEqual({ kind: 'open' });
    // storage or lock failure
    const broken = createOutbox({
      kinds: OUTBOX_KINDS,
      store: { ...memoryOutboxStore(), put: () => Promise.reject(new Error('QuotaExceededError')) },
      channelName: null,
    });
    expect(await handleReminderAction({ outbox: broken, action: 'log|o|ok', data })).toEqual({
      kind: 'open',
    });
    const failingLock = { request: () => Promise.reject(new Error('lock')) };
    expect(
      await handleReminderAction({ outbox, action: 'log|o|ok', data, locks: failingLock }),
    ).toEqual({
      kind: 'open',
    });
  });

  it('labels numbers with their unit', () => {
    const q = reminder(numberLog).quickr;
    if (!q) throw new Error('no quickr');
    expect(answerLabel(q, 7.5)).toBe('7.5 h');
    expect(answerLabel(reminder(enumLog).quickr ?? q, 'ok')).toBe('OK');
  });
});

describe('a single topic (no questions)', () => {
  const singleLog = { type: 'single' };
  const now = () => Date.parse('2026-10-17T08:05:00Z');

  it('offers one "Log it" action, and only where actions are supported', () => {
    expect(pushActions(reminder(singleLog), 2)).toEqual([{ action: 'log|s|', title: 'Log it' }]);
    expect(pushActions(reminder(singleLog), 0)).toEqual([]);
  });

  it('accepts only its own action', () => {
    const q = reminder(singleLog).quickr;
    expect(resolveAction('log|s|', q)).toEqual({ key: null, value: null });
    expect(resolveAction('log|s|x', q)).toBeNull();
    expect(resolveAction('log|o|good', q)).toBeNull();
    expect(resolveAction('log|s|', reminder(enumLog).quickr)).toBeNull();
  });

  it('logs an entry with no answers, once per reminder', async () => {
    const { outbox } = setup();
    const data = notificationData(reminder(singleLog));
    const result = await logFromAction({ outbox, action: 'log|s|', data, now });
    expect(result).toEqual({ status: 'enqueued', id: await actionEntryId(SERVER, TOPIC, SLOT) });
    const again = await logFromAction({ outbox, action: 'log|s|', data, now });
    expect(again.status).toBe('duplicate');
    const items = await outbox.list();
    expect(items).toHaveLength(1);
    expect((items[0]?.payload as EntryCreatePayload).body.answers).toEqual({});
  });

  it('a second click on the same reminder says nothing more', async () => {
    const { outbox } = setup();
    const data = notificationData(reminder(singleLog));
    await logFromAction({ outbox, action: 'log|s|', data, now });
    const feedback = await handleReminderAction({
      outbox: { ...outbox, sendNow: () => Promise.reject(new Error('not sent')) },
      action: 'log|s|',
      data,
      now,
    });
    expect(feedback).toEqual({ kind: 'none' });
  });
});

describe('a timed topic (timers.md §10.1, §10.2)', () => {
  const timedLog = { type: 'timed' };
  const data = notificationData(reminder(timedLog));
  const T = Date.parse('2026-10-17T08:05:00Z');
  const now = () => T;
  /** The action entry id vector of this reminder's (server, topic, slot). */
  const vectorId = idVectors.cases.find((c) => c.name === 'canonical')?.expected;
  /** Another slot of the same topic: the next day's reminder. */
  const nextDay = (d: typeof data) => {
    if (!d.quickr) throw new Error('not actionable');
    return { ...d, quickr: { ...d.quickr, due_since: '2026-10-18T08:00:00Z' } };
  };

  function rig(clock: () => number = now) {
    setAckedStore(memoryAckedStore());
    const server = fakeQuickrServer(SERVER, [TOPIC]);
    const outbox = createOutbox({
      kinds: OUTBOX_KINDS,
      store: memoryOutboxStore(),
      fetch: server.fetch,
      channelName: null,
      random: () => 0.5,
      now: clock,
    });
    const queued = vi.fn(() => Promise.resolve());
    const click = (extra: Record<string, unknown> = {}) =>
      handleReminderAction({
        outbox,
        action: START_ACTION,
        data,
        now: clock,
        queued,
        acked: () => ackedItems(clock()),
        sendTimeoutMs: 2000,
        ...extra,
      });
    const runEvents = async () =>
      (await outbox.list()).filter((i) => i.kind === RUN_EVENT) as OutboxItem<RunEventPayload>[];
    return { server, outbox, queued, click, runEvents };
  }

  it('offers one Start, and only where actions are supported', () => {
    expect(pushActions(reminder(timedLog), 2)).toEqual([{ action: 'log|t|', title: 'Start' }]);
    expect(pushActions(reminder(timedLog), 0)).toEqual([]);
    expect(reminder(timedLog).quickr?.quick_log).toEqual({ type: 'timed' });
  });

  it('accepts only its own action; a Start is no answer', () => {
    const q = reminder(timedLog).quickr;
    expect(isStartAction('log|t|', q)).toBe(true);
    expect(isStartAction('log|t|x', q)).toBe(false);
    expect(isStartAction('log|t|', reminder(enumLog).quickr)).toBe(false);
    expect(isStartAction('log|t|', reminder({ type: 'single' }).quickr)).toBe(false);
    expect(resolveAction('log|t|', q)).toBeNull();
    expect(resolveAction('log|s|', q)).toBeNull();
    expect(resolveAction('log|o|good', q)).toBeNull();
    if (!q) throw new Error('not actionable');
    expect(answerLabel(q, undefined)).toBe('it');
  });

  it('two racing clicks enqueue one start, whose id is the action entry id vector', async () => {
    const { server, click, runEvents } = rig();
    server.offline = true;
    const feedback = await Promise.all([click(), click()]);
    expect(feedback).toEqual([{ kind: 'none' }, { kind: 'none' }]);
    const items = await runEvents();
    expect(items).toHaveLength(1);
    const [start] = items;
    expect(vectorId).toBeDefined();
    expect(start?.id).toBe(vectorId);
    expect(start?.payload).toMatchObject({
      run_id: vectorId,
      topic: { id: TOPIC, slug: 'mood', name: 'Mood' },
      version: 3,
      steps: null, // nothing cached: unknown, not guessed
      requires_answers: null,
      makes_entry: false,
      expect_server_id: SERVER,
      event: {
        type: 'start',
        topic_id: TOPIC,
        version: 3,
        source: PWA_NOTIFICATION_SOURCE,
        at: formatInstant(now()),
      },
    });
    expect((await click()).kind).toBe('none'); // a re-delivered push: still one
    expect(await runEvents()).toHaveLength(1);
  });

  it('stamps the start with the server-time offset it is given', async () => {
    const { server, click, runEvents } = rig();
    server.offline = true;
    await click({ offset: () => Promise.resolve(7250) });
    expect((await runEvents())[0]?.payload.event.at).toBe(formatInstant(now() + 7250));
  });

  it('carries the version’s steps and required-question flag when the cache knows them', async () => {
    const { server, click, runEvents } = rig();
    server.offline = true;
    const steps = [{ key: 'shower', label: 'Shower' }];
    const startVersion = vi.fn(() => Promise.resolve({ steps, requires_answers: true }));
    await click({ startVersion });
    expect(startVersion).toHaveBeenCalledWith(TOPIC, 'mood', 3);
    expect((await runEvents())[0]?.payload).toMatchObject({ steps, requires_answers: true });
  });

  it('sends the start to the reminder’s server; a second click after it went writes nothing', async () => {
    const { server, outbox, click, runEvents } = rig();
    expect(await click()).toEqual({ kind: 'none' });
    expect([...server.runs.keys()]).toEqual([vectorId]);
    expect(server.runs.get(vectorId ?? '')?.source).toBe(PWA_NOTIFICATION_SOURCE);
    const [request] = server.requests;
    expect(request?.url).toBe(`/api/v1/runs/${vectorId}/events`);
    expect(request?.headers['x-quickr-expect-server-id']).toBe(SERVER);
    expect(await outbox.list()).toEqual([]);
    // Acked (the acked record has it): the same reminder doesn't start it again.
    expect(await click()).toEqual({ kind: 'none' });
    expect(server.requests).toHaveLength(1);
    expect(await runEvents()).toEqual([]);
  });

  it('a run this device already stopped is not started again by the same reminder', async () => {
    const { server, outbox, click, runEvents } = rig();
    server.offline = true;
    await click({ startVersion: () => Promise.resolve({ steps: [], requires_answers: false }) });
    const ctx = { topic: { id: TOPIC, slug: 'mood', name: 'Mood' }, version: 3 };
    const deps = { outbox, serverRuns: () => [], now };
    const stop = await tapRun(
      deps,
      vectorId ?? '',
      { ...ctx, steps: [], requires_answers: false },
      'stop',
    );
    expect(stop?.payload.event.type).toBe('stop');
    const before = await runEvents();
    expect(await click()).toEqual({ kind: 'none' }); // a re-delivered push
    expect(await runEvents()).toEqual(before);
  });

  it('a failed start is never replaced by a later click on the same reminder', async () => {
    let clock = T;
    const { server, click, runEvents } = rig(() => clock);
    server.topics.set(TOPIC, { status: 'archived' });
    expect((await click()).kind).toBe('notify');
    const [failed] = await runEvents();
    expect(failed?.status).toBe('failed');
    clock += 60_000;
    expect(await click()).toEqual({ kind: 'none' });
    const [after] = await runEvents();
    expect(after?.payload.event.at).toBe(failed?.payload.event.at);
    expect(after?.created_at).toBe(failed?.created_at);
    expect(after?.status).toBe('failed');
    expect(server.requests).toHaveLength(1);
  });

  it('a stale acked start (no page to prune it) doesn’t block the next day’s Start (H1)', async () => {
    let clock = T;
    const { server, outbox, click } = rig(() => clock);
    expect(await click()).toEqual({ kind: 'none' }); // started, acked; no page open
    clock += 24 * 60 * 60_000; // the next day, nothing local changed
    expect(await click({ data: nextDay(data) })).toEqual({ kind: 'none' });
    const nextId = await actionEntryId(SERVER, TOPIC, '2026-10-18T08:00:00Z');
    expect(server.requests.map((r) => r.url)).toEqual([
      `/api/v1/runs/${vectorId}/events`,
      `/api/v1/runs/${nextId}/events`,
    ]);
    // The fake still has the first run open: the server merged the second start (§4.5).
    expect(server.runs.get(vectorId ?? '')?.aliases?.has(nextId)).toBe(true);
    expect(await outbox.list()).toEqual([]);
  });

  it('a Start waits for this device’s retrying stop of the topic’s run, so it isn’t merged (§8.1)', async () => {
    let clock = T;
    const { server, outbox, queued, click } = rig(() => clock);
    const id = vectorId ?? '';
    expect(await click()).toEqual({ kind: 'none' }); // started, acked
    clock += 1000;
    server.unavailable.add('stop-1');
    await outbox.enqueue(
      RUN_EVENT,
      {
        topic: { id: TOPIC, slug: 'mood', name: 'Mood' },
        run_id: id,
        version: 3,
        steps: [],
        requires_answers: false,
        makes_entry: true,
        event: { type: 'stop', at: formatInstant(clock) },
      } satisfies RunEventPayload,
      { id: 'stop-1' },
    );
    await outbox.flush(); // 503: retrying
    clock += 1000;
    expect(await click({ data: nextDay(data), sendTimeoutMs: 50 })).toEqual({ kind: 'none' });
    expect(queued).toHaveBeenCalled();
    const nextId = await actionEntryId(SERVER, TOPIC, '2026-10-18T08:00:00Z');
    expect(server.requests.map((r) => r.url)).not.toContain(`/api/v1/runs/${nextId}/events`);
    server.unavailable.delete('stop-1');
    await outbox.flush({ force: true });
    expect(server.requests.map((r) => (r.body as { type: string }).type).slice(-2)).toEqual([
      'stop',
      'start',
    ]);
    expect(server.runs.get(id)?.status).toBe('stopped');
    expect(server.runs.get(id)?.aliases).toBeUndefined();
    expect(server.runs.get(nextId)?.status).toBe('running');
  });

  it('a fresh acked start of another slot doesn’t make an open run either: the server merges', async () => {
    const { server, outbox, click } = rig();
    await click();
    expect(await click({ data: nextDay(data) })).toEqual({ kind: 'none' }); // 201, void
    expect(server.requests).toHaveLength(2);
    expect(await outbox.list()).toEqual([]);
  });

  it('a start the server already has from another device is dropped silently', async () => {
    const { server, outbox, click } = rig();
    const id = vectorId ?? '';
    server.runs.set(id, { id, topic_id: TOPIC, version: 3, at: 'elsewhere', source: 'ios' });
    expect(await click()).toEqual({ kind: 'none' });
    expect(server.runs.get(id)?.source).toBe('ios');
    expect(await outbox.list()).toEqual([]);
  });

  it('the same id as another topic’s run or entry is refused, not dropped', async () => {
    const id = vectorId ?? '';
    const run = rig();
    run.server.topics.set('topic-other', { status: 'active' });
    run.server.runs.set(id, { id, topic_id: 'topic-other', version: 1, at: 'x', source: 'ios' });
    expect(await run.click()).toMatchObject({ kind: 'notify', title: 'Couldn’t start Mood' });
    expect((await run.runEvents()).map((i) => i.status)).toEqual(['failed']);

    const entry = rig();
    entry.server.entries.set(id, { id, topic_id: 'topic-other', answers: [], source: 'ios' });
    expect(await entry.click()).toMatchObject({ kind: 'notify', title: 'Couldn’t start Mood' });
    expect((await entry.runEvents()).map((i) => i.status)).toEqual(['failed']);
  });

  it('a topic with a run open here starts nothing more', async () => {
    const { server, outbox, click, runEvents } = rig();
    server.offline = true;
    const q = data.quickr;
    if (!q) throw new Error('not actionable');
    const other = { ...data, quickr: { ...q, due_since: '2026-10-17T07:00:00Z' } };
    await click({ data: other }); // another slot's start, still queued: an open run
    await click();
    expect((await runEvents()).map((i) => i.id)).toEqual([
      await actionEntryId(SERVER, TOPIC, '2026-10-17T07:00:00Z'),
    ]);
    expect(await outbox.list()).toHaveLength(1);
  });

  it('says why it was refused, and refuses a topic the cache shows archived', async () => {
    const mismatch = rig();
    mismatch.server.serverId = '0b9e0000-0000-4000-8000-0000000000bb';
    expect(await mismatch.click()).toEqual({
      kind: 'notify',
      title: 'Couldn’t start Mood',
      body: 'This reminder came from another quickR server, so nothing was started.',
    });
    expect(await mismatch.outbox.list()).toEqual([]);

    const archived = rig();
    archived.server.topics.set(TOPIC, { status: 'archived' });
    expect((await archived.click()).kind).toBe('notify');
    expect((await archived.outbox.list()).map((i) => i.status)).toEqual(['failed']);

    const logged = rig(); // the run was stopped elsewhere: its entry has the id
    logged.server.entries.set(vectorId ?? '', {
      id: vectorId ?? '',
      topic_id: TOPIC,
      answers: [],
      source: 'ios',
    });
    expect(await logged.click()).toEqual({ kind: 'none' });
    expect(await logged.outbox.list()).toEqual([]);

    const untimed = rig();
    untimed.server.topics.set(TOPIC, { status: 'active', untimed: true });
    expect(await untimed.click()).toEqual({
      kind: 'notify',
      title: 'Couldn’t start Mood',
      body: 'This version of the topic isn’t timed. Open quickR to log it.',
    });

    const deleted = rig();
    deleted.server.deletedRuns.add(vectorId ?? '');
    expect(await deleted.click()).toEqual({
      kind: 'notify',
      title: 'Couldn’t start Mood',
      body: 'The topic was deleted.',
    });

    const cached = rig();
    const topicState = () => Promise.resolve('archived' as const);
    expect(await cached.click({ topicState })).toMatchObject({ title: 'Couldn’t start Mood' });
    expect(cached.server.requests).toEqual([]);
    expect(await cached.outbox.list()).toEqual([]);
  });

  it('offline: queued, and Background Sync is asked for', async () => {
    const { server, queued, click, runEvents } = rig();
    server.offline = true;
    expect(await click()).toEqual({ kind: 'none' });
    expect(queued).toHaveBeenCalledOnce();
    expect((await runEvents()).map((i) => i.status)).toEqual(['pending']);
  });

  it('opens the app when the outbox can’t be written', async () => {
    const { outbox, click } = rig();
    const broken = { ...outbox, list: () => Promise.reject(new Error('storage')) };
    expect(await click({ outbox: broken })).toEqual({ kind: 'open' });
  });
});

describe('startVersionOfTopic (a cached getTopic or listTopics answer)', () => {
  const topic = {
    id: TOPIC,
    current_version: 3,
    questions: [{ key: 'mood', type: 'int' }],
    timer: { steps: [{ key: 'a', label: 'A' }] },
  };

  it('uses a topic whose current version it is, with its questions and timer', () => {
    const expected = { steps: [{ key: 'a', label: 'A' }], requires_answers: true };
    expect(startVersionOfTopic(topic, TOPIC, 3)).toEqual(expected);
    expect(startVersionOfTopic({ items: [{ id: 'x' }, topic] }, TOPIC, 3)).toEqual(expected);
  });

  it('knows nothing of another version, another topic or a summary without them', () => {
    expect(startVersionOfTopic(topic, TOPIC, 2)).toBeUndefined();
    expect(startVersionOfTopic(topic, uuid(), 3)).toBeUndefined();
    const summary = { id: TOPIC, current_version: 3 };
    expect(startVersionOfTopic({ items: [summary] }, TOPIC, 3)).toBeUndefined();
    expect(startVersionOfTopic({ ...topic, timer: null }, TOPIC, 3)).toBeUndefined();
  });
});

describe('startVersionOf (a cached listTopicVersions answer)', () => {
  const versions = [
    { version: 1, questions: [], timer: null },
    {
      version: 2,
      questions: [{ key: 'note', type: 'str', required: false }],
      timer: { steps: [{ key: 'a', label: 'A' }] },
    },
    { version: 3, questions: [{ key: 'mood', type: 'int', required: true }], timer: { steps: [] } },
  ];

  it('finds the version’s steps and whether a question is required', () => {
    expect(startVersionOf(versions, 2)).toEqual({
      steps: [{ key: 'a', label: 'A' }],
      requires_answers: false,
    });
    expect(startVersionOf(versions, 3)).toEqual({ steps: [], requires_answers: true });
  });

  it('knows nothing of an untimed, missing or malformed version', () => {
    expect(startVersionOf(versions, 1)).toBeUndefined();
    expect(startVersionOf(versions, 9)).toBeUndefined();
    expect(startVersionOf({ items: versions }, 2)).toBeUndefined();
    expect(startVersionOf([{ version: 2, timer: { steps: [{ key: 1 }] } }], 2)).toBeUndefined();
  });
});
