/** The `run.event` kind in a real outbox: start ordering, K6, classification (timers.md §8). */
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { T0, runItem } from '../../test/runs';
import { ackedItems, memoryAckedStore, setAckedStore } from '../runs/acked';
import { ENTRY_CREATE, OUTBOX_KINDS, RUN_EVENT, type RunEventPayload } from './kinds';
import { createOutbox } from './outbox';
import { memoryOutboxStore } from './store';
import type { OutboxEvent, OutboxItem } from './types';

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const problem = (status: number, code: string) => json(status, { code, detail: code, errors: [] });
const ok = (id: string) =>
  json(200, { event: { id, effect: 'applied', reason: null }, run: {}, entry: null });

beforeEach(() => {
  setAckedStore(memoryAckedStore());
});

type Responder = (body: { id: string; type: string }) => Response | Error;

function setup(respond: Responder) {
  const t = { now: T0 };
  const sent: string[] = [];
  const fetchMock = vi.fn((_url: RequestInfo | URL, init?: RequestInit) => {
    const body = JSON.parse(init?.body as string) as { id: string; type: string };
    sent.push(body.id);
    const r = respond(body);
    return r instanceof Error ? Promise.reject(r) : Promise.resolve(r);
  });
  const store = memoryOutboxStore();
  const outbox = createOutbox({
    kinds: OUTBOX_KINDS,
    store,
    fetch: fetchMock,
    now: () => t.now,
    random: () => 0.5,
    channelName: null,
  });
  const events: OutboxEvent[] = [];
  outbox.subscribe((e) => events.push(e));
  /** Put items in the queue as `enqueue` would (in order, kind hooks included). */
  const queue = async (...items: OutboxItem<RunEventPayload>[]) => {
    for (const i of items) {
      t.now = Date.parse(i.created_at);
      await outbox.enqueue(RUN_EVENT, i.payload, { id: i.id });
    }
  };
  const ids = async () => (await outbox.list()).map((i) => `${i.id}:${i.status}`);
  return { outbox, store, sent, events, queue, ids, t };
}

const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
const next = runItem('next', { id: 'n1', run: 'r1', at: T0 + 1000, seg: 0 });
const stop = runItem('stop', { id: 's1', run: 'r1', at: T0 + 2000 });

describe('start ordering', () => {
  it("doesn't send a run's events before its start is in", async () => {
    let up = false;
    const { outbox, sent, queue, ids } = setup((b) => (up ? ok(b.id) : problem(503, 'down')));
    await queue(start, next, stop);
    await outbox.flush();
    // The start was tried and backs off; its events weren't attempted at all.
    expect(sent).toEqual(['r1']);
    expect((await outbox.list()).map((i) => i.attempts)).toEqual([1, 0, 0]);
    up = true;
    await outbox.flush({ force: true });
    // Start first, then its events in the same pass.
    expect(sent).toEqual(['r1', 'r1', 'n1', 's1']);
    expect(await ids()).toEqual([]);
  });

  it('sends events at once when the start is already in', async () => {
    const { outbox, sent, queue } = setup((b) => ok(b.id));
    await queue(next, stop); // the start was acked earlier
    await outbox.flush();
    expect(sent).toEqual(['n1', 's1']);
  });

  it('a failed start blocks its events until retried, and nothing else', async () => {
    let refuse = true;
    const { outbox, sent, queue, ids } = setup((b) =>
      refuse && b.id === 'r1' ? problem(409, 'topic_not_timed') : ok(b.id),
    );
    const other = runItem('start', { id: 'r2', run: 'r2', at: T0 + 500 });
    await queue(start, other, next);
    await outbox.flush();
    expect(sent).toEqual(['r1', 'r2']);
    expect(await ids()).toEqual(['r1:failed', 'n1:pending']);
    // Blocked items aren't due: no polling while the start needs the user.
    expect(await outbox.nextDueAt()).toBeNull();
    refuse = false;
    await outbox.retry('r1');
    expect(sent).toEqual(['r1', 'r2', 'r1', 'n1']);
    expect(await ids()).toEqual([]);
  });

  it('discarding a failed start discards its events', async () => {
    const { outbox, events, queue, ids } = setup(() => problem(409, 'topic_archived'));
    await queue(start, next, stop);
    await outbox.flush();
    await outbox.discard('r1');
    expect(await ids()).toEqual([]);
    expect(
      events.filter((e) => e.type === 'discarded').map((e) => 'item' in e && e.item.id),
    ).toEqual(['r1', 'n1', 's1']);
  });

  it("a failed Next doesn't block Stop", async () => {
    const { outbox, sent, queue, ids } = setup((b) =>
      b.id === 'n1' ? problem(422, 'invalid_request') : ok(b.id),
    );
    await queue(start, next, stop);
    await outbox.flush();
    expect(sent).toEqual(['r1', 'n1', 's1']);
    expect(await ids()).toEqual(['n1:failed']);
  });

  it('events of one run never wait for each other while retrying', async () => {
    const { outbox, sent, queue, ids } = setup((b) =>
      b.id === 'n1' ? problem(503, 'down') : ok(b.id),
    );
    await queue(next, stop);
    await outbox.flush();
    expect(sent).toEqual(['n1', 's1']);
    expect(await ids()).toEqual(['n1:pending']);
  });
});

describe('K6', () => {
  const discard = runItem('discard', { id: 'd1', run: 'r1', at: T0 + 3000 });

  it('a discard of a never-sent run removes it without a trace', async () => {
    const { outbox, sent, events, queue, ids } = setup((b) => ok(b.id));
    await queue(start, next, discard);
    expect(await ids()).toEqual([]);
    await outbox.flush();
    expect(sent).toEqual([]);
    expect(events.map((e) => e.type)).toEqual(['enqueued', 'enqueued', 'discarded', 'discarded']);
    expect(await outbox.get('d1')).toBeUndefined();
  });

  it('a discard after any attempt is appended and sent', async () => {
    const { outbox, sent, queue, ids } = setup((b) =>
      b.id === 'r1' ? new Error('offline') : ok(b.id),
    );
    await queue(start, next);
    await outbox.flush(); // offline: the start was attempted
    await queue(discard);
    expect(await ids()).toEqual(['r1:pending', 'n1:pending', 'd1:pending']);
    expect(sent).toEqual(['r1']);
  });
});

describe('classification', () => {
  it('acks a void event like any success', async () => {
    const { outbox, queue, ids } = setup((b) =>
      json(200, { event: { id: b.id, effect: 'void', reason: 'stale' }, run: {}, entry: null }),
    );
    await queue(next);
    await outbox.flush();
    expect(await ids()).toEqual([]);
  });

  it('retires on run_deleted', async () => {
    const { outbox, events, queue, ids } = setup(() => problem(409, 'run_deleted'));
    await queue(next);
    await outbox.flush();
    expect(await ids()).toEqual([]);
    expect(events.at(-1)?.type).toBe('retired');
  });

  it('fails a non-start event on 404, and rejects 409 conflicts and 422', async () => {
    const codes: Record<string, Response> = {
      n1: problem(404, 'not_found'),
      s1: problem(422, 'invalid_answers'),
      r1: problem(409, 'id_conflict'),
    };
    const { outbox, queue, ids } = setup((b) => codes[b.id] ?? ok(b.id));
    await queue(start);
    await outbox.flush();
    await queue(next, stop);
    await outbox.flush();
    expect(await ids()).toEqual(['r1:failed', 'n1:pending', 's1:pending']);
    // With the start discarded, they'd go out and fail on their own.
    const { outbox: o2, queue: q2, ids: ids2 } = setup((b) => codes[b.id] ?? ok(b.id));
    await q2(next, stop);
    await o2.flush();
    expect(await ids2()).toEqual(['n1:failed', 's1:failed']);
  });

  it('fails a finish refused with run_open, answers kept, instead of retrying forever', async () => {
    const finish = runItem('finish', { id: 'f1', run: 'r1', at: T0 + 2500, answers: { mood: 4 } });
    const { outbox, queue, ids } = setup(() => problem(409, 'run_open'));
    await queue(finish);
    await outbox.flush();
    expect(await ids()).toEqual(['f1:failed']);
    const kept = await outbox.get('f1');
    expect((kept?.payload as RunEventPayload).event.answers).toEqual({ mood: 4 });
  });
});

describe('finish after stop (L1)', () => {
  const finish = runItem('finish', { id: 'f1', run: 'r1', at: T0 + 2500, answers: { mood: 4 } });

  it("waits for its run's pending stop", async () => {
    let up = false;
    const { outbox, sent, queue, ids } = setup((b) =>
      b.id === 's1' && !up ? problem(503, 'down') : ok(b.id),
    );
    await queue(stop, finish);
    await outbox.flush();
    expect(sent).toEqual(['s1']);
    expect(await ids()).toEqual(['s1:pending', 'f1:pending']);
    up = true;
    await outbox.flush({ force: true });
    expect(sent).toEqual(['s1', 's1', 'f1']);
  });

  it('goes (and fails on run_open) once its stop failed', async () => {
    const { outbox, sent, queue, ids } = setup((b) =>
      b.id === 's1' ? problem(422, 'before_start') : problem(409, 'run_open'),
    );
    await queue(stop, finish);
    await outbox.flush();
    expect(sent).toEqual(['s1', 'f1']);
    expect(await ids()).toEqual(['s1:failed', 'f1:failed']);
  });

  it("isn't discarded with its stop", async () => {
    const { outbox, queue, ids } = setup(() => new Error('offline'));
    await queue(stop, finish);
    await outbox.discard('s1');
    expect(await ids()).toEqual(['f1:pending']);
  });
});

describe('enqueue and flush (H1, L2)', () => {
  it("doesn't wait for a flush in progress, except for a discard", async () => {
    let release: (r: Response) => void = () => undefined;
    const hanging = new Promise<Response>((r) => {
      release = r;
    });
    // The start's request hangs.
    const o = createOutbox({
      kinds: OUTBOX_KINDS,
      store: memoryOutboxStore(),
      fetch: () => hanging,
      channelName: null,
    });
    await o.enqueue(RUN_EVENT, start.payload, { id: 'r1' });
    const flushing = o.flush();
    await new Promise((r) => setTimeout(r, 0));
    // The pass holds the lock on the start's request; a lap is stored at once.
    await o.enqueue(RUN_EVENT, next.payload, { id: 'n1' });
    expect((await o.list()).map((i) => i.id).sort()).toEqual(['n1', 'r1']);
    let discarded = false;
    const discard = runItem('discard', { id: 'd1', run: 'r1', at: T0 + 3000 });
    const pendingDiscard = o.enqueue(RUN_EVENT, discard.payload, { id: 'd1' }).then(() => {
      discarded = true;
    });
    await new Promise((r) => setTimeout(r, 0));
    expect(discarded).toBe(false);
    release(ok('r1'));
    await flushing;
    await pendingDiscard;
    expect(discarded).toBe(true);
  });

  it('sends taps of one millisecond in the order of their at', async () => {
    const { outbox, sent, queue } = setup((b) => ok(b.id));
    // Same created_at; ids that sort the other way round.
    const a = runItem('next', { id: 'zz', run: 'r1', at: T0 + 1, seg: 0, created: T0 });
    const b = runItem('lap', { id: 'aa', run: 'r1', at: T0 + 2, seg: 1, created: T0 });
    await queue(a, b);
    await outbox.flush();
    expect(sent).toEqual(['zz', 'aa']);
  });

  it('records an acked event before it leaves the queue', async () => {
    const seen: string[] = [];
    const { outbox, queue } = setup((b) => ok(b.id));
    outbox.subscribe((e) => {
      if (e.type === 'sent') void ackedItems().then((a) => seen.push(...a.map((i) => i.id)));
    });
    await queue(next);
    await outbox.flush();
    await new Promise((r) => setTimeout(r, 0));
    expect(seen).toEqual(['n1']);
  });
});

describe('entry.create alongside run events', () => {
  it('is sent in order and never waits for a run', async () => {
    const { outbox, sent, queue, t } = setup((b) =>
      b.id === 'r1' ? problem(503, 'down') : json(201, { id: b.id }),
    );
    await queue(start, next);
    t.now += 10;
    await outbox.enqueue(
      ENTRY_CREATE,
      { topic: { id: 't', slug: 't', name: 'T' }, body: { answers: {} } },
      { id: 'e1' },
    );
    await outbox.flush();
    expect(sent).toEqual(['r1', 'e1']);
  });
});
