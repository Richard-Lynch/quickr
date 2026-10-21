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
import { ENTRY_CREATE, OUTBOX_KINDS, type EntryCreatePayload } from './outbox/kinds';
import { createOutbox } from './outbox/outbox';
import { idbOutboxStore, memoryOutboxStore } from './outbox/store';
import { fakeQuickrServer } from '../test/fakeQuickrServer';
import {
  actionEntryId,
  answerLabel,
  handleReminderAction,
  logFromAction,
  notificationData,
  PWA_NOTIFICATION_SOURCE,
  pushActions,
  resolveAction,
} from './pushActions';
import { formatQuickLogNumber, parsePushPayload, type PushPayload } from './pushPayload';

interface VectorAction {
  kind: 'log' | 'input' | 'open';
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
  // The log actions of every vector case, in order, as the PWA renders them (§10): no input
  // action, no "More…".
  it.each(
    vectors.cases.filter((c) => c.expected.quick_log !== null).map((c) => [c.name, c] as const),
  )('matches the shared vectors: %s', (_name, c) => {
    const p = reminder(c.expected.quick_log, { topic_id: c.topic_id, version: c.version });
    const expected = c.expected.actions
      .filter((a) => a.kind === 'log')
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
