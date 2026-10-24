import { QueryClient, type InfiniteData } from '@tanstack/react-query';
import { describe, expect, it, vi } from 'vitest';

import {
  getEntryQueryKey,
  getTopicQueryKey,
  listEntriesInfiniteQueryKey,
  listTopicsInfiniteQueryKey,
} from '../client/@tanstack/react-query.gen';
import type { EntryOut, EntryPage, TopicDetail, TopicPage } from '../client';
import { scheduleUndoable } from '../lib/undo';
import {
  patchEntries,
  patchTopics,
  prependEntry,
  restoreSnapshot,
  snapshotOperations,
  topicIs,
} from './cache';
import { applyEntryUpdate } from './mutations';

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

const entry = (id: string, value = 1): EntryOut => ({
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
  answers: [{ key: 'hours', type: 'int', value }],
  timing: null,
});

function seed() {
  const qc = new QueryClient();
  const topicsKey = listTopicsInfiniteQueryKey({ query: { status: 'active' } });
  qc.setQueryData<InfiniteData<TopicPage>>(topicsKey, {
    pages: [{ items: [topic], total: 1, limit: 20, offset: 0 }],
    pageParams: [0],
  });
  qc.setQueryData(getTopicQueryKey({ path: { ref: 'sleep' } }), topic);
  const entriesKey = listEntriesInfiniteQueryKey({ path: { ref: 'sleep' } });
  qc.setQueryData<InfiniteData<EntryPage>>(entriesKey, {
    pages: [{ items: [entry('a'), entry('b')], total: 2, limit: 25, offset: 0 }],
    pageParams: [0],
  });
  return { qc, topicsKey, entriesKey };
}

describe('optimistic cache helpers', () => {
  it('patches a topic in lists and details, and can drop it from lists', () => {
    const { qc, topicsKey } = seed();
    patchTopics(qc, topicIs({ slug: 'sleep' }), (t) => ({ entry_count: t.entry_count + 1 }));
    expect(
      qc.getQueryData<TopicDetail>(getTopicQueryKey({ path: { ref: 'sleep' } })),
    ).toMatchObject({ entry_count: 3 });
    const list = qc.getQueryData<InfiniteData<TopicPage>>(topicsKey);
    expect(list?.pages[0]?.items[0]?.entry_count).toBe(3);
    patchTopics(qc, topicIs({ id: 't1' }), () => null);
    expect(qc.getQueryData<InfiniteData<TopicPage>>(topicsKey)?.pages[0]).toMatchObject({
      items: [],
      total: 0,
    });
  });

  it('removes / prepends entries and restores a snapshot', () => {
    const { qc, entriesKey } = seed();
    const snap = snapshotOperations(qc, ['listEntries', 'listTopics', 'getTopic']);
    patchEntries(qc, (s) => (s.id === 'a' ? null : s));
    expect(qc.getQueryData<InfiniteData<EntryPage>>(entriesKey)?.pages[0]).toMatchObject({
      total: 1,
      items: [{ id: 'b' }],
    });
    prependEntry(qc, topic, entry('new'));
    prependEntry(qc, topic, entry('new')); // idempotent
    expect(
      qc.getQueryData<InfiniteData<EntryPage>>(entriesKey)?.pages[0]?.items.map((s) => s.id),
    ).toEqual(['new', 'b']);
    restoreSnapshot(qc, snap);
    expect(
      qc.getQueryData<InfiniteData<EntryPage>>(entriesKey)?.pages[0]?.items.map((s) => s.id),
    ).toEqual(['a', 'b']);
  });

  it('applies entry updates locally (answers merge, null clears)', () => {
    const s = entry('a', 7);
    expect(applyEntryUpdate(s, { answers: { hours: 8 }, notes: 'n' })).toMatchObject({
      notes: 'n',
      answers: [{ key: 'hours', value: 8 }],
    });
    expect(applyEntryUpdate(s, { answers: { hours: null } }).answers).toEqual([]);
    const qc = new QueryClient();
    qc.setQueryData(getEntryQueryKey({ path: { entry_id: 'a' } }), s);
    patchEntries(qc, (x) => applyEntryUpdate(x, { source: 'watch' }));
    expect(qc.getQueryData<EntryOut>(getEntryQueryKey({ path: { entry_id: 'a' } }))?.source).toBe(
      'watch',
    );
  });
});

describe('scheduleUndoable', () => {
  it('commits after the delay unless undone', () => {
    vi.useFakeTimers();
    const commit = vi.fn();
    const kept = scheduleUndoable(commit, 1000);
    const undone = scheduleUndoable(commit, 1000);
    expect(undone.undo()).toBe(true);
    vi.advanceTimersByTime(1000);
    expect(commit).toHaveBeenCalledTimes(1);
    expect(kept.undo()).toBe(false);
    vi.useRealTimers();
  });

  it('commits early when the page is hidden', () => {
    const commit = vi.fn();
    scheduleUndoable(commit, 60_000);
    window.dispatchEvent(new Event('pagehide'));
    expect(commit).toHaveBeenCalledTimes(1);
  });
});
