import { describe, expect, it } from 'vitest';

import { T0, runItem } from '../../test/runs';
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

  it('retires on run_deleted, retries a finish refused with run_open, and defers the rest', () => {
    expect(kind.classify?.(409, problem('run_deleted'), next)).toBe('retired');
    expect(kind.classify?.(409, problem('run_open'), finish)).toBe('retry');
    // Only a finish keeps its answers this way; a stop is never refused with run_open.
    expect(kind.classify?.(409, problem('run_open'), next)).toBeUndefined();
    for (const code of ['topic_not_timed', 'topic_archived', 'id_conflict', 'event_conflict']) {
      expect(kind.classify?.(409, problem(code), start)).toBeUndefined();
    }
    expect(kind.classify?.(404, problem('not_found'), next)).toBeUndefined();
    expect(kind.classify?.(422, problem('invalid_answers'), finish)).toBeUndefined();
    expect(kind.classify?.(200, { event: { effect: 'void' } }, next)).toBeUndefined();
  });

  it('makes an event wait for its run start only', () => {
    expect(kind.waitsFor?.(start)).toEqual([]);
    expect(kind.waitsFor?.(next)).toEqual(['r1']);
    expect(kind.waitsFor?.(finish)).toEqual(['r1']);
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
});
