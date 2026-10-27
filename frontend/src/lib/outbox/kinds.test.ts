import { describe, expect, it } from 'vitest';

import { T0, runEventResult, runItem } from '../../test/runs';
import { ENTRY_CREATE, OUTBOX_KINDS, RUN_EVENT, problemCode } from './kinds';
import type { OutboxItem } from './types';

describe('entry.create classification', () => {
  const classify = (status: number, body: unknown) =>
    OUTBOX_KINDS[ENTRY_CREATE]?.classify?.(status, body, {} as OutboxItem);

  it('retires a create whose id was deleted on the server', () => {
    expect(classify(409, { code: 'entry_deleted', detail: 'gone', errors: [] })).toBe('retired');
  });

  it('leaves every other response to the default classification', () => {
    expect(classify(409, { code: 'conflict', detail: 'other topic', errors: [] })).toBeUndefined();
    expect(classify(404, { code: 'entry_deleted' })).toBeUndefined();
    expect(classify(409, undefined)).toBeUndefined();
    expect(classify(201, { id: 'x' })).toBeUndefined();
  });

  it('reads Problem codes defensively', () => {
    expect(problemCode({ code: 'x' })).toBe('x');
    expect(problemCode({ code: 1 })).toBeUndefined();
    expect(problemCode('x')).toBeUndefined();
    expect(problemCode(null)).toBeUndefined();
  });
});

describe('run.event kind', () => {
  // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
  const kind = OUTBOX_KINDS[RUN_EVENT]!;
  const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
  const next = runItem('next', { id: 'n1', run: 'r1', at: T0 + 1000, seg: 0 });
  const finish = runItem('finish', { id: 'f1', run: 'r1', at: T0 + 2000, answers: { mood: 3 } });
  const problem = (code: string) => ({ code, detail: code, errors: [] });

  it('posts the event to its run, with the item id as the event id', () => {
    expect(kind.toRequest(next)).toEqual({
      method: 'POST',
      url: '/api/v1/runs/r1/events',
      body: { type: 'next', at: '2026-10-24T08:00:01Z', seg: 0, id: 'n1' },
    });
    expect(kind.toRequest(start).body).toEqual({
      type: 'start',
      at: '2026-10-24T08:00:00Z',
      topic_id: 'topic-1',
      version: 1,
      id: 'r1',
    });
  });

  it('retires on run_deleted, and leaves the rest to the default (a finish on run_open fails)', () => {
    expect(kind.classify?.(409, problem('run_deleted'), next)).toBe('retired');
    // Sent only after this device's stop is in: run_open means no stop is coming.
    expect(kind.classify?.(409, problem('run_open'), finish)).toBeUndefined();
    expect(kind.classify?.(409, problem('run_open'), next)).toBeUndefined();
    for (const code of ['topic_not_timed', 'topic_archived', 'id_conflict', 'event_conflict']) {
      expect(kind.classify?.(409, problem(code), start)).toBeUndefined();
    }
    expect(kind.classify?.(404, problem('not_found'), next)).toBeUndefined();
    expect(kind.classify?.(422, problem('invalid_answers'), finish)).toBeUndefined();
    expect(kind.classify?.(200, runEventResult('n1', 'void', 'stale'), next)).toBeUndefined();
  });

  it('retries a 2xx whose body isn’t a RunEventResult (M7)', () => {
    expect(kind.classify?.(200, { event: { effect: 'void' } }, next)).toBe('retry');
    expect(kind.classify?.(200, {}, next)).toBe('retry');
    expect(kind.classify?.(200, undefined, next)).toBe('retry');
    const noEntry: Partial<ReturnType<typeof runEventResult>> = runEventResult('n1');
    delete noEntry.entry;
    expect(kind.classify?.(200, noEntry, next)).toBe('retry');
  });

  it('a result without its run’s aliases or revision isn’t one (L-3)', () => {
    const noAliases: { run: Partial<ReturnType<typeof runEventResult>['run']> } =
      runEventResult('n1');
    delete noAliases.run.aliases;
    expect(kind.classify?.(200, noAliases, next)).toBe('retry');
    const noRevision: { run: Partial<ReturnType<typeof runEventResult>['run']> } =
      runEventResult('n1');
    delete noRevision.run.revision;
    expect(kind.classify?.(200, noRevision, next)).toBe('retry');
  });

  it('makes an event wait for its run start, and a finish for its pending stops too', () => {
    const stop = runItem('stop', { id: 's1', run: 'r1', at: T0 + 1500 });
    const otherStop = runItem('stop', { id: 's9', run: 'r9', at: T0 + 1500 });
    const queue = [start, next, stop, otherStop];
    expect(kind.waitsFor?.(start, queue)).toEqual([]);
    expect(kind.waitsFor?.(next, queue)).toEqual(['r1']);
    expect(kind.waitsFor?.(stop, queue)).toEqual(['r1']);
    expect(kind.waitsFor?.(finish, queue)).toEqual(['r1', 's1']);
    // A failed stop doesn't hold the finish back.
    expect(kind.waitsFor?.(finish, [start, { ...stop, status: 'failed' }])).toEqual(['r1']);
  });

  it("is discarded with its run's start only", () => {
    expect(kind.discardedWith?.(start)).toEqual([]);
    expect(kind.discardedWith?.(next)).toEqual(['r1']);
    expect(kind.discardedWith?.(finish)).toEqual(['r1']);
  });

  it('orders same-millisecond taps by their at, and only a discard coalesces', () => {
    expect(kind.orderKey?.(next)).toBe(String(T0 + 1000).padStart(16, '0'));
    // Sorts by time, which the wire strings don't.
    const at0 = runItem('lap', { id: 'x', run: 'r1', at: T0 });
    const at1 = runItem('lap', { id: 'y', run: 'r1', at: T0 + 1 });
    expect((kind.orderKey?.(at0) ?? '') < (kind.orderKey?.(at1) ?? '')).toBe(true);
    expect(at0.payload.event.at > at1.payload.event.at).toBe(true);
    expect(kind.coalesces?.(next)).toBe(false);
    expect(kind.coalesces?.(runItem('discard', { id: 'd1', run: 'r1', at: T0 }))).toBe(true);
  });

  describe('K6', () => {
    const discard = runItem('discard', { id: 'd1', run: 'r1', at: T0 + 3000 });

    it('drops a run the server never saw, and the discard with it', () => {
      expect(kind.coalesce?.(discard, [start, next])).toEqual({ drop: ['r1', 'n1'], store: false });
    });

    it('appends the discard once anything of the run was attempted or failed', () => {
      const tried = { ...next, attempts: 1 };
      expect(kind.coalesce?.(discard, [start, tried])).toBeUndefined();
      const failed = { ...next, status: 'failed' as const };
      expect(kind.coalesce?.(discard, [start, failed])).toBeUndefined();
      expect(kind.coalesce?.(discard, [{ ...start, attempts: 1 }])).toBeUndefined();
    });

    it('appends the discard when the start is no longer queued (the server has the run)', () => {
      expect(kind.coalesce?.(discard, [next])).toBeUndefined();
      expect(kind.coalesce?.(discard, [])).toBeUndefined();
    });

    it("ignores other runs' items and other event types", () => {
      const other = runItem('start', { id: 'r2', run: 'r2', at: T0, attempts: 3 });
      expect(kind.coalesce?.(discard, [start, other])).toEqual({ drop: ['r1'], store: false });
      expect(kind.coalesce?.(next, [start])).toBeUndefined();
    });
  });

  it('checks only a start’s 409 event_conflict or id_conflict, and reads the entry only for id_conflict', async () => {
    const urls: string[] = [];
    const read = (url: string) => {
      urls.push(url);
      return Promise.resolve({ status: 404, body: problem('not_found') });
    };
    const queue = () => Promise.resolve([]);
    const refusal = (status: number, code: string) => ({
      message: code,
      status,
      body: problem(code),
    });
    expect(
      await kind.verify?.(start, refusal(422, 'event_conflict'), { read, queue }),
    ).toBeUndefined();
    expect(
      await kind.verify?.(next, refusal(409, 'event_conflict'), { read, queue }),
    ).toBeUndefined();
    expect(await kind.verify?.(start, refusal(409, 'run_open'), { read, queue })).toBeUndefined();
    expect(urls).toEqual([]);
    expect(
      await kind.verify?.(start, refusal(409, 'event_conflict'), { read, queue }),
    ).toBeUndefined();
    expect(urls).toEqual(['/api/v1/runs/r1']);
    urls.length = 0;
    expect(
      await kind.verify?.(start, refusal(409, 'id_conflict'), { read, queue }),
    ).toBeUndefined();
    expect(urls).toEqual(['/api/v1/runs/r1', '/api/v1/entries/r1']);
  });

  it('looks the start’s effect up case-insensitively', async () => {
    const run = {
      id: 'r1',
      topic_id: start.payload.topic.id,
      aliases: [],
      state: { effects: { R1: { effect: 'applied', reason: null } } },
    };
    const verdict = await kind.verify?.(
      start,
      { message: 'x', status: 409, body: problem('event_conflict') },
      { read: () => Promise.resolve({ status: 200, body: run }), queue: () => Promise.resolve([]) },
    );
    expect(verdict).toMatchObject({ outcome: 'ok', data: { event: { effect: 'applied' } } });
  });
});
