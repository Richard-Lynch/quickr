import 'fake-indexeddb/auto';

import { describe, expect, it, vi } from 'vitest';

import { uuid } from '../uuid';
import { BACKOFF_BASE_MS, BACKOFF_MAX_MS, backoffMs, classifyStatus } from './classify';
import { createOutbox, type OutboxOptions } from './outbox';
import { idbOutboxStore } from './store';
import type { OutboxEvent, OutboxKind } from './types';

interface NotePayload {
  text: string;
}

const noteCreate: OutboxKind = {
  toRequest: (item) => ({
    method: 'POST',
    url: '/api/v1/notes',
    body: { id: item.id, ...(item.payload as NotePayload) },
  }),
};

const kinds: Record<string, OutboxKind> = { 'note.create': noteCreate };

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const problem = (code: string, detail: string) => ({ code, detail, errors: [] });

function setup(responses: (Response | Error)[], extra: Partial<OutboxOptions> = {}) {
  let t = 1_000_000;
  const fetchMock = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(
    () => {
      const next = responses.shift();
      if (next === undefined) return Promise.reject(new Error('no more responses'));
      return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
    },
  );
  const store = idbOutboxStore(`test-${uuid()}`);
  const events: OutboxEvent[] = [];
  const outbox = createOutbox({
    kinds,
    store,
    fetch: fetchMock,
    now: () => t,
    random: () => 0.5, // no jitter
    channelName: null,
    headers: { 'X-Test': '1' },
    ...extra,
  });
  outbox.subscribe((e) => events.push(e));
  return {
    outbox,
    store,
    fetchMock,
    events,
    advance: (ms: number) => {
      t += ms;
    },
    now: () => t,
  };
}

describe('classifyStatus', () => {
  it.each([
    [200, 'ok'],
    [201, 'ok'],
    [204, 'ok'],
    [null, 'retry'],
    [0, 'retry'],
    [500, 'retry'],
    [502, 'retry'],
    [503, 'retry'],
    [408, 'retry'],
    [429, 'retry'],
    [401, 'retry'],
    [400, 'terminal'],
    [404, 'terminal'],
    [409, 'terminal'],
    [422, 'terminal'],
  ] as const)('%s → %s', (status, outcome) => {
    expect(classifyStatus(status)).toBe(outcome);
  });
});

describe('backoffMs', () => {
  it('doubles per attempt and caps', () => {
    const mid = () => 0.5;
    expect(backoffMs(1, mid)).toBe(BACKOFF_BASE_MS);
    expect(backoffMs(2, mid)).toBe(BACKOFF_BASE_MS * 2);
    expect(backoffMs(3, mid)).toBe(BACKOFF_BASE_MS * 4);
    expect(backoffMs(30, mid)).toBe(BACKOFF_MAX_MS);
  });

  it('jitters within ±20%', () => {
    expect(backoffMs(1, () => 0)).toBe(BACKOFF_BASE_MS * 0.8);
    expect(backoffMs(1, () => 0.999999)).toBeCloseTo(BACKOFF_BASE_MS * 1.2, -1);
  });
});

describe('outbox', () => {
  it('persists enqueued items durably and lists them oldest first', async () => {
    const { outbox, store, advance } = setup([]);
    const a = await outbox.enqueue<NotePayload>('note.create', { text: 'a' });
    advance(10);
    const b = await outbox.enqueue<NotePayload>('note.create', { text: 'b' });
    expect(a).toMatchObject({ status: 'pending', attempts: 0, last_error: null });
    expect(a.id).toMatch(/^[0-9a-f-]{36}$/);
    // a second outbox on the same DB (e.g. after a reload / in the SW) sees them
    const again = createOutbox({ kinds, store, channelName: null });
    expect((await again.list()).map((i) => i.payload)).toEqual([{ text: 'a' }, { text: 'b' }]);
    expect(b.created_at > a.created_at).toBe(true);
  });

  it('rejects unknown kinds', async () => {
    const { outbox } = setup([]);
    await expect(outbox.enqueue('nope', {})).rejects.toThrow(/Unknown outbox item kind/);
  });

  it('sends, removes on 2xx and reports the server response', async () => {
    const { outbox, fetchMock, events } = setup([json(201, { id: 'srv-1' })]);
    const item = await outbox.enqueue<NotePayload>('note.create', { text: 'hi' });
    const r = await outbox.flush();
    expect(r).toEqual({ sent: 1, failed: 0, retrying: 0, retired: 0, remaining: 0 });
    expect(await outbox.list()).toEqual([]);
    const [url, init] = fetchMock.mock.calls[0] ?? [];
    expect(url).toBe('/api/v1/notes');
    expect(init?.method).toBe('POST');
    expect(init?.redirect).toBe('manual');
    expect(JSON.parse(init?.body as string)).toEqual({ id: item.id, text: 'hi' });
    expect(init?.headers).toMatchObject({ 'X-Test': '1', 'Content-Type': 'application/json' });
    expect(events.find((e) => e.type === 'sent')).toMatchObject({ data: { id: 'srv-1' } });
  });

  it('keeps items on network errors, backs off, and stops the pass', async () => {
    const { outbox, fetchMock, advance, now } = setup([new TypeError('Failed to fetch')]);
    await outbox.enqueue('note.create', { text: '1' });
    advance(1);
    await outbox.enqueue('note.create', { text: '2' });
    const r = await outbox.flush();
    expect(r).toMatchObject({ sent: 0, retrying: 1, remaining: 2 });
    // the second item was not attempted (we're offline; don't burn its attempts)
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [first, second] = await outbox.list();
    expect(first).toMatchObject({
      status: 'pending',
      attempts: 1,
      next_attempt_at: now() + BACKOFF_BASE_MS,
      last_error: { status: null, message: 'Could not reach the server' },
    });
    expect(second?.attempts).toBe(0);

    // not due yet → only the untouched item goes
    fetchMock.mockImplementation(() => Promise.resolve(json(201, {})));
    await outbox.flush();
    expect((await outbox.list()).map((i) => i.payload)).toEqual([{ text: '1' }]);
    advance(BACKOFF_BASE_MS);
    await outbox.flush();
    expect(await outbox.list()).toEqual([]);
  });

  it('retries 5xx with growing backoff; force ignores backoff', async () => {
    const { outbox, now } = setup([json(503, {}), json(500, {}), json(201, {})]);
    await outbox.enqueue('note.create', { text: 'x' });
    await outbox.flush();
    await outbox.flush({ force: true });
    const [item] = await outbox.list();
    expect(item).toMatchObject({
      attempts: 2,
      status: 'pending',
      next_attempt_at: now() + BACKOFF_BASE_MS * 2,
      last_error: { status: 500, message: 'Server error (500)' },
    });
    await outbox.flush({ force: true });
    expect(await outbox.list()).toEqual([]);
  });

  it('marks 4xx validation errors and 409 conflicts as terminal failures', async () => {
    const body = {
      code: 'invalid_answers',
      detail: 'one or more answers are invalid',
      errors: [{ loc: ['answers', 'mood'], message: 'bad' }],
    };
    const { outbox, fetchMock, events } = setup([
      json(422, body),
      json(409, problem('conflict', 'already exists')),
    ]);
    await outbox.enqueue('note.create', { text: 'a' });
    await outbox.enqueue('note.create', { text: 'b' });
    expect(await outbox.flush()).toMatchObject({ failed: 2, remaining: 2 });
    const [a, b] = await outbox.list();
    expect(a).toMatchObject({
      status: 'failed',
      attempts: 1,
      last_error: { status: 422, message: 'One or more answers are invalid', body },
    });
    expect(b).toMatchObject({ status: 'failed', last_error: { status: 409 } });
    expect(events.filter((e) => e.type === 'failed')).toHaveLength(2);
    // terminal items are never sent automatically, even when forced
    await outbox.flush({ force: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('retry() re-sends a failed item; update() replaces its payload', async () => {
    const { outbox, fetchMock } = setup([json(422, problem('invalid', 'nope')), json(201, {})]);
    const item = await outbox.enqueue<NotePayload>('note.create', { text: 'bad' });
    await outbox.flush();
    const updated = await outbox.update<NotePayload>(item.id, { text: 'good' });
    expect(updated).toMatchObject({ status: 'pending', last_error: null, attempts: 1 });
    await outbox.retry(item.id);
    expect(await outbox.list()).toEqual([]);
    expect(JSON.parse(fetchMock.mock.calls[1]?.[1]?.body as string)).toMatchObject({
      text: 'good',
    });
  });

  it('discard() removes an item and emits its last state', async () => {
    const { outbox, events } = setup([]);
    const item = await outbox.enqueue('note.create', { text: 'x' });
    const removed = await outbox.discard(item.id);
    expect(removed?.id).toBe(item.id);
    expect(await outbox.list()).toEqual([]);
    expect(events.at(-1)).toMatchObject({ type: 'discarded', item: { status: 'pending' } });
    expect(await outbox.discard('missing')).toBeUndefined();
  });

  it('does not treat a non-JSON 200 (captive portal) or a redirect as success', async () => {
    const { outbox } = setup([
      new Response('<html>login</html>', { status: 200 }),
      new Response(null, { status: 302 }),
    ]);
    await outbox.enqueue('note.create', { text: 'x' });
    await outbox.flush();
    expect((await outbox.list())[0]?.last_error?.message).toBe(
      'Unexpected response from the server',
    );
    await outbox.flush({ force: true });
    expect((await outbox.list())[0]).toMatchObject({
      status: 'pending',
      attempts: 2,
      last_error: { status: 302 },
    });
  });

  it('honours a kind-specific classification', async () => {
    const del: OutboxKind = {
      toRequest: () => ({ method: 'DELETE', url: '/api/v1/notes/1' }),
      classify: (s) => (s === 404 ? 'ok' : undefined),
    };
    const { outbox, fetchMock } = setup([new Response(null, { status: 404 })], {
      kinds: { ...kinds, 'note.delete': del },
    });
    await outbox.enqueue('note.delete', {});
    expect(await outbox.flush()).toMatchObject({ sent: 1, remaining: 0 });
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBeNull();
  });

  it('retires an item the server says can never happen, without a failure', async () => {
    const retire: OutboxKind = {
      ...noteCreate,
      classify: (s, body) =>
        s === 409 && (body as { code?: string } | undefined)?.code === 'gone'
          ? 'retired'
          : undefined,
    };
    const { outbox, events } = setup(
      [json(409, problem('gone', 'deleted')), json(409, problem('conflict', 'taken'))],
      { kinds: { 'note.create': retire } },
    );
    const a = await outbox.enqueue('note.create', { text: 'a' });
    expect(await outbox.sendNow(a.id)).toMatchObject({ status: 'retired', item: { id: a.id } });
    expect(events.at(-1)).toMatchObject({
      type: 'retired',
      item: { id: a.id },
      error: { status: 409, body: { code: 'gone' } },
    });
    // Any other 409 is still a terminal failure.
    const b = await outbox.enqueue('note.create', { text: 'b' });
    expect(await outbox.flush()).toMatchObject({ failed: 1, remaining: 1 });
    expect(await outbox.list()).toMatchObject([{ id: b.id, status: 'failed' }]);
  });

  it('does not retire an item discarded while its send was in flight', async () => {
    let release: (r: Response) => void = () => undefined;
    const retire: OutboxKind = { ...noteCreate, classify: () => 'retired' };
    const { outbox, fetchMock, events } = setup([], { kinds: { 'note.create': retire } });
    fetchMock.mockImplementation(
      () =>
        new Promise<Response>((resolve) => {
          release = resolve;
        }),
    );
    const item = await outbox.enqueue('note.create', { text: 'x' });
    const flushing = outbox.flush();
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalled();
    });
    await outbox.discard(item.id);
    release(json(409, problem('gone', 'deleted')));
    expect(await flushing).toMatchObject({ retired: 0, remaining: 0 });
    expect(events.map((e) => e.type)).toEqual(['enqueued', 'discarded']);
  });

  it('coalesces concurrent flushes so nothing is sent twice', async () => {
    const { outbox, fetchMock } = setup([json(201, {}), json(201, {})]);
    await outbox.enqueue('note.create', { text: '1' });
    await outbox.enqueue('note.create', { text: '2' });
    await Promise.all([outbox.flush(), outbox.flush(), outbox.flush({ force: true })]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(await outbox.list()).toEqual([]);
  });

  it('lets a discard during an in-flight send win over the retry bookkeeping', async () => {
    let release: (r: Response) => void = () => undefined;
    const { outbox, fetchMock } = setup([]);
    fetchMock.mockImplementation(
      () =>
        new Promise<Response>((resolve) => {
          release = resolve;
        }),
    );
    const item = await outbox.enqueue('note.create', { text: 'x' });
    const flushing = outbox.flush();
    await vi.waitFor(() => {
      expect(fetchMock).toHaveBeenCalled();
    });
    await outbox.discard(item.id);
    release(json(503, {}));
    await flushing;
    expect(await outbox.list()).toEqual([]);
  });

  it('sendNow resolves with the first outcome of that item', async () => {
    const { outbox } = setup([
      json(201, { id: 's1' }),
      json(422, problem('invalid', 'bad')),
      new TypeError('offline'),
    ]);
    const a = await outbox.enqueue('note.create', { text: 'a' });
    expect(await outbox.sendNow(a.id)).toEqual({ status: 'sent', data: { id: 's1' } });
    const b = await outbox.enqueue('note.create', { text: 'b' });
    expect(await outbox.sendNow(b.id)).toMatchObject({ status: 'failed', item: { id: b.id } });
    await outbox.discard(b.id);
    const c = await outbox.enqueue('note.create', { text: 'c' });
    expect(await outbox.sendNow(c.id)).toMatchObject({ status: 'queued', item: { attempts: 1 } });
  });

  it('sendNow times out to "queued" while a send hangs', async () => {
    const { outbox, fetchMock } = setup([]);
    fetchMock.mockImplementation(() => new Promise<Response>(() => undefined));
    const a = await outbox.enqueue('note.create', { text: 'a' });
    const r = await outbox.sendNow(a.id, 20);
    expect(r).toMatchObject({ status: 'queued', item: { id: a.id } });
  });

  it('aborts a hanging request after requestTimeoutMs and retries later', async () => {
    const { outbox, fetchMock } = setup([], { requestTimeoutMs: 10 });
    fetchMock.mockImplementation(
      (_u, init) =>
        new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => {
            reject(new DOMException('aborted', 'AbortError'));
          });
        }),
    );
    await outbox.enqueue('note.create', { text: 'a' });
    expect(await outbox.flush()).toMatchObject({ retrying: 1 });
  });

  it('reports the earliest due time of pending items', async () => {
    const { outbox, now } = setup([new TypeError('offline')]);
    expect(await outbox.nextDueAt()).toBeNull();
    await outbox.enqueue('note.create', { text: 'a' });
    expect(await outbox.nextDueAt()).toBe(now());
    await outbox.flush();
    expect(await outbox.nextDueAt()).toBe(now() + BACKOFF_BASE_MS);
  });
});
