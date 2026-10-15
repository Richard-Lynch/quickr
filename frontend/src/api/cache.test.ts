import { QueryClient, type InfiniteData } from '@tanstack/react-query';
import { describe, expect, it, vi } from 'vitest';

import {
  getSessionQueryKey,
  getTopicQueryKey,
  listSessionsInfiniteQueryKey,
  listTopicsInfiniteQueryKey,
} from '../client/@tanstack/react-query.gen';
import type { SessionOut, SessionPage, TopicDetail, TopicPage } from '../client';
import { scheduleUndoable } from '../lib/undo';
import {
  patchSessions,
  patchTopics,
  prependSession,
  restoreSnapshot,
  snapshotOperations,
  topicIs,
} from './cache';
import { applySessionUpdate } from './mutations';

const topic = {
  id: 't1',
  slug: 'sleep',
  name: 'Sleep',
  description: '',
  status: 'active',
  current_version: 1,
  question_count: 1,
  session_count: 2,
  last_captured_at: '2026-01-01T00:00:00Z',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  archived_at: null,
  questions: [],
} satisfies TopicDetail;

const session = (id: string, value = 1): SessionOut => ({
  id,
  topic_id: 't1',
  version: 1,
  source: 'phone',
  channel: 'ui',
  captured_at: '2026-01-02T00:00:00Z',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
  notes: '',
  meta: {},
  answers: [{ key: 'hours', type: 'int', value }],
});

function seed() {
  const qc = new QueryClient();
  const topicsKey = listTopicsInfiniteQueryKey({ query: { status: 'active' } });
  qc.setQueryData<InfiniteData<TopicPage>>(topicsKey, {
    pages: [{ items: [topic], total: 1, limit: 20, offset: 0 }],
    pageParams: [0],
  });
  qc.setQueryData(getTopicQueryKey({ path: { ref: 'sleep' } }), topic);
  const sessionsKey = listSessionsInfiniteQueryKey({ path: { ref: 'sleep' } });
  qc.setQueryData<InfiniteData<SessionPage>>(sessionsKey, {
    pages: [{ items: [session('a'), session('b')], total: 2, limit: 25, offset: 0 }],
    pageParams: [0],
  });
  return { qc, topicsKey, sessionsKey };
}

describe('optimistic cache helpers', () => {
  it('patches a topic in lists and details, and can drop it from lists', () => {
    const { qc, topicsKey } = seed();
    patchTopics(qc, topicIs({ slug: 'sleep' }), (t) => ({ session_count: t.session_count + 1 }));
    expect(
      qc.getQueryData<TopicDetail>(getTopicQueryKey({ path: { ref: 'sleep' } })),
    ).toMatchObject({ session_count: 3 });
    const list = qc.getQueryData<InfiniteData<TopicPage>>(topicsKey);
    expect(list?.pages[0]?.items[0]?.session_count).toBe(3);
    patchTopics(qc, topicIs({ id: 't1' }), () => null);
    expect(qc.getQueryData<InfiniteData<TopicPage>>(topicsKey)?.pages[0]).toMatchObject({
      items: [],
      total: 0,
    });
  });

  it('removes / prepends sessions and restores a snapshot', () => {
    const { qc, sessionsKey } = seed();
    const snap = snapshotOperations(qc, ['listSessions', 'listTopics', 'getTopic']);
    patchSessions(qc, (s) => (s.id === 'a' ? null : s));
    expect(qc.getQueryData<InfiniteData<SessionPage>>(sessionsKey)?.pages[0]).toMatchObject({
      total: 1,
      items: [{ id: 'b' }],
    });
    prependSession(qc, topic, session('new'));
    prependSession(qc, topic, session('new')); // idempotent
    expect(
      qc.getQueryData<InfiniteData<SessionPage>>(sessionsKey)?.pages[0]?.items.map((s) => s.id),
    ).toEqual(['new', 'b']);
    restoreSnapshot(qc, snap);
    expect(
      qc.getQueryData<InfiniteData<SessionPage>>(sessionsKey)?.pages[0]?.items.map((s) => s.id),
    ).toEqual(['a', 'b']);
  });

  it('applies session updates locally (answers merge, null clears)', () => {
    const s = session('a', 7);
    expect(applySessionUpdate(s, { answers: { hours: 8 }, notes: 'n' })).toMatchObject({
      notes: 'n',
      answers: [{ key: 'hours', value: 8 }],
    });
    expect(applySessionUpdate(s, { answers: { hours: null } }).answers).toEqual([]);
    const qc = new QueryClient();
    qc.setQueryData(getSessionQueryKey({ path: { session_id: 'a' } }), s);
    patchSessions(qc, (x) => applySessionUpdate(x, { source: 'watch' }));
    expect(
      qc.getQueryData<SessionOut>(getSessionQueryKey({ path: { session_id: 'a' } }))?.source,
    ).toBe('watch');
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
