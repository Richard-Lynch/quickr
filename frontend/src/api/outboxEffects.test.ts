import { QueryClient, type InfiniteData } from '@tanstack/react-query';
import { describe, expect, it } from 'vitest';

import type { EntryOut, EntryPage, TopicDetail } from '../client';
import {
  getEntryQueryKey,
  getTopicQueryKey,
  listEntriesInfiniteQueryKey,
} from '../client/@tanstack/react-query.gen';
import { ENTRY_CREATE, type EntryCreatePayload } from '../lib/outbox/kinds';
import type { Outbox, OutboxListener } from '../lib/outbox/outbox';
import type { OutboxEvent, OutboxItem } from '../lib/outbox/types';
import { T0, ev, runItem, serverRun } from '../test/runs';
import { connectOutboxEffects } from './outboxEffects';
import { cachedServerRuns, mergeListed, runsQueryKey, upsertServerRun } from './runs';

const topic = {
  id: 't1',
  slug: 'sleep',
  name: 'Sleep',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 1,
  entry_count: 2,
  last_captured_at: '2026-01-01T00:00:00Z',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: null,
  questions: [],
} satisfies TopicDetail;

const entry = (id: string): EntryOut => ({
  id,
  topic_id: 't1',
  version: 1,
  revision: 1,
  source: 'phone',
  channel: 'ui',
  captured_at: '2026-01-02T00:00:00Z',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
  notes: '',
  meta: {},
  answers: [],
  timing: null,
});

const item: OutboxItem<EntryCreatePayload> = {
  id: 'e1',
  kind: ENTRY_CREATE,
  payload: {
    topic: { id: 't1', slug: 'sleep', name: 'Sleep' },
    body: { answers: { hours: 7 }, captured_at: '2026-01-03T00:00:00Z' },
  },
  created_at: '2026-01-03T00:00:00Z',
  updated_at: '2026-01-03T00:00:00Z',
  attempts: 0,
  status: 'pending',
  next_attempt_at: 0,
  last_error: null,
};

function setup() {
  const qc = new QueryClient();
  const topicKey = getTopicQueryKey({ path: { ref: 'sleep' } });
  qc.setQueryData(topicKey, topic);
  const entriesKey = listEntriesInfiniteQueryKey({ path: { ref: 'sleep' } });
  qc.setQueryData<InfiniteData<EntryPage>>(entriesKey, {
    pages: [{ items: [entry('e0')], total: 1, limit: 25, offset: 0 }],
    pageParams: [0],
  });
  let listener: OutboxListener = () => undefined;
  const outbox = {
    subscribe(l: OutboxListener) {
      listener = l;
      return () => undefined;
    },
  } as unknown as Outbox;
  connectOutboxEffects(qc, outbox);
  const count = () => qc.getQueryData<TopicDetail>(topicKey)?.entry_count;
  const ids = () =>
    qc.getQueryData<InfiniteData<EntryPage>>(entriesKey)?.pages[0]?.items.map((e) => e.id);
  const emit = (e: OutboxEvent) => {
    listener(e, false);
  };
  return { qc, emit, count, ids };
}

const flushPromises = () => new Promise((r) => setTimeout(r, 0));

describe('entry.create effects', () => {
  it('rolls back the optimistic entry when the server retires it (entry_deleted)', () => {
    const { qc, emit, count, ids } = setup();
    emit({ type: 'enqueued', item });
    expect(count()).toBe(3);
    // e.g. a stale cache already holding it (sent from another tab, then deleted)
    qc.setQueryData(getEntryQueryKey({ path: { entry_id: 'e1' } }), entry('e1'));

    emit({
      type: 'retired',
      item,
      error: { message: 'Deleted', status: 409, body: { code: 'entry_deleted' } },
    });
    expect(count()).toBe(2);
    expect(ids()).toEqual(['e0']);
    expect(qc.getQueryData(getEntryQueryKey({ path: { entry_id: 'e1' } }))).toBeUndefined();
  });
});

describe('run.event effects', () => {
  const runTopic = { id: 't1', slug: 'sleep', name: 'Sleep' };
  const stop = (makes_entry: boolean) => {
    const i = runItem('stop', { id: 's1', run: 'r1', at: T0 + 5000, makes_entry });
    return { ...i, payload: { ...i.payload, topic: runTopic } };
  };

  it('counts a stop that makes the entry at once, and rolls it back on failure', () => {
    const { emit, count } = setup();
    emit({ type: 'enqueued', item: stop(true) });
    expect(count()).toBe(3);
    emit({ type: 'failed', item: { ...stop(true), status: 'failed' } });
    expect(count()).toBe(2);
    emit({ type: 'enqueued', item: stop(false) });
    expect(count()).toBe(2);
  });

  it("doesn't un-count a failed stop again when it is discarded", () => {
    const { emit, count } = setup();
    emit({ type: 'enqueued', item: stop(true) });
    emit({ type: 'failed', item: { ...stop(true), status: 'failed' } });
    emit({ type: 'discarded', item: { ...stop(true), status: 'failed' } });
    expect(count()).toBe(2);
  });

  it('un-counts a pending stop that was discarded (K6) or retired', () => {
    const { emit, count } = setup();
    emit({ type: 'enqueued', item: stop(true) });
    emit({ type: 'discarded', item: stop(true) });
    expect(count()).toBe(2);
    emit({ type: 'enqueued', item: stop(true) });
    emit({ type: 'retired', item: stop(true), error: { message: 'gone', status: 409 } });
    expect(count()).toBe(2);
  });

  it("puts the response's run in the runs cache, and its entry in the entry caches", async () => {
    // The response is parsed (zRunEventResult): real UUIDs.
    const R1 = '00000000-0000-4000-8000-000000000001';
    const S1 = '00000000-0000-4000-8000-000000000002';
    const T1 = '00000000-0000-4000-8000-0000000000aa';
    const { qc, emit, ids } = setup();
    const run = serverRun(R1, [ev(R1, 'start', T0)], { topic_id: T1 });
    emit({
      type: 'sent',
      item: runItem('start', { id: R1, run: R1, at: T0 }),
      data: { event: { id: R1, effect: 'applied', reason: null }, run, entry: null },
    });
    await flushPromises();
    expect(cachedServerRuns(qc).map((r) => r.id)).toEqual([R1]);

    const stopped = serverRun(R1, [ev(R1, 'start', T0), ev(S1, 'stop', T0 + 5000)], {
      topic_id: T1,
    });
    emit({
      type: 'sent',
      item: stop(true),
      data: {
        event: { id: S1, effect: 'applied', reason: null },
        run: stopped,
        entry: { ...entry(R1), topic_id: T1 },
      },
    });
    await flushPromises();
    expect(cachedServerRuns(qc)).toEqual([]);
    expect(ids()).toEqual([R1, 'e0']);
    expect(qc.getQueryData(getEntryQueryKey({ path: { entry_id: R1 } }))).toMatchObject({ id: R1 });
  });
});

describe('a start acked by verify (§8.1)', () => {
  it('pulls the runs: the run is the server’s, started elsewhere', async () => {
    const R1 = '00000000-0000-4000-8000-000000000001';
    const T1 = '00000000-0000-4000-8000-0000000000aa';
    const run = serverRun(R1, [ev(R1, 'start', T0)], { topic_id: T1 });
    const data = { event: { id: R1, effect: 'applied', reason: null }, run, entry: null };
    const start = runItem('start', { id: R1, run: R1, at: T0 });
    for (const verified of [false, true]) {
      const { qc, emit } = setup();
      qc.setQueryData(runsQueryKey(), []);
      emit({ type: 'sent', item: start, data, ...(verified ? { verified } : {}) });
      await flushPromises();
      expect(qc.getQueryState(runsQueryKey())?.isInvalidated).toBe(verified);
      expect(cachedServerRuns(qc).map((r) => r.id)).toEqual([R1]);
    }
  });
});

describe('upsertServerRun', () => {
  it('keeps the newer copy, drops closed runs and merged aliases', () => {
    const qc = new QueryClient();
    const r1 = serverRun('r1', [ev('r1', 'start', T0)], { revision: 3 });
    const r2 = serverRun('r2', [ev('r2', 'start', T0)], { revision: 1 });
    qc.setQueryData(runsQueryKey(), [r1, r2]);
    upsertServerRun(qc, { ...r1, revision: 2, status: 'paused' });
    expect(cachedServerRuns(qc)).toEqual([r1, r2]);
    upsertServerRun(qc, { ...r1, revision: 4, aliases: ['r2'] });
    expect(cachedServerRuns(qc).map((r) => [r.id, r.revision])).toEqual([['r1', 4]]);
    upsertServerRun(qc, { ...r1, revision: 5, status: 'discarded' });
    expect(cachedServerRuns(qc)).toEqual([]);
  });
});

describe('mergeListed', () => {
  const r1 = serverRun('r1', [ev('r1', 'start', T0)], { revision: 3 });

  it("keeps a cached copy that is newer than the list's", () => {
    expect(mergeListed([r1], [{ ...r1, revision: 2 }], 0)).toEqual([r1]);
    expect(mergeListed([r1], [{ ...r1, revision: 4 }], 0)[0]?.revision).toBe(4);
  });

  it('keeps a run put in the cache after the fetch began, and drops others the list lacks', () => {
    const qc = new QueryClient();
    upsertServerRun(qc, r1, 1000);
    expect(mergeListed(cachedServerRuns(qc), [], 900)).toEqual([r1]);
    expect(mergeListed(cachedServerRuns(qc), [], 1001)).toEqual([]);
  });
});
