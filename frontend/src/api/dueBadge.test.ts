import 'fake-indexeddb/auto';

import { QueryClient } from '@tanstack/react-query';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { TopicPage, TopicSummary } from '../client';
import { listTopicsQueryKey } from '../client/@tanstack/react-query.gen';
import { setAppBadge } from '../lib/badge';
import { outbox, refreshOutboxSnapshot } from '../lib/outbox/client';
import { RUN_EVENT } from '../lib/outbox/kinds';
import {
  memoryAckedStore,
  recordAcked,
  refreshAckedSnapshot,
  setAckedStore,
} from '../lib/runs/acked';
import { T0, ev, runItem, serverRun } from '../test/runs';
import { connectDueBadge } from './dueBadge';
import { runsQueryKey } from './runs';

vi.mock('../lib/badge', () => ({ setAppBadge: vi.fn(() => Promise.resolve(true)) }));

const due = (id: string): TopicSummary => ({
  id,
  slug: id,
  name: id,
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 0,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: { is_due: true, due_since: null, next_due_at: null, last_entry_at: null },
});

afterEach(() => {
  vi.mocked(setAppBadge).mockClear();
});

describe('the badge with runs (timers.md §11.1)', () => {
  it("doesn't count a topic with an open run, and counts it again once it closes", () => {
    const qc = new QueryClient();
    const page: TopicPage = {
      items: [due('topic-1'), due('topic-2')],
      total: 2,
      limit: 50,
      offset: 0,
    };
    qc.setQueryData(listTopicsQueryKey(), page);
    const stop = connectDueBadge(qc);
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([2]);

    qc.setQueryData(runsQueryKey(), [serverRun('r1', [ev('r1', 'start', T0)])]);
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([1]);

    // A finishing run isn't open: its topic is due again.
    const finishing = serverRun('r1', [ev('r1', 'start', T0), ev('s1', 'stop', T0 + 1000)], {
      status: 'finishing',
    });
    qc.setQueryData(runsQueryKey(), [finishing]);
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([2]);
    stop();
  });

  it('follows the outbox: a queued start stops its topic counting at once', async () => {
    const qc = new QueryClient();
    const page: TopicPage = { items: [due('topic-1')], total: 1, limit: 50, offset: 0 };
    qc.setQueryData(listTopicsQueryKey(), page);
    const stop = connectDueBadge(qc);
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([1]);
    const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
    await outbox.enqueue(RUN_EVENT, start.payload, { id: 'r1' });
    await refreshOutboxSnapshot();
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([0]);
    await outbox.clear();
    await refreshOutboxSnapshot();
    stop();
  });

  it('follows the acked record: a just-acked start keeps its topic out of the count', async () => {
    setAckedStore(memoryAckedStore());
    const qc = new QueryClient();
    const page: TopicPage = { items: [due('topic-1')], total: 1, limit: 50, offset: 0 };
    qc.setQueryData(listTopicsQueryKey(), page);
    const stop = connectDueBadge(qc);
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([1]);
    await recordAcked(runItem('start', { id: 'r1', run: 'r1', at: T0 }));
    await refreshAckedSnapshot();
    expect(vi.mocked(setAppBadge).mock.lastCall).toEqual([0]);
    setAckedStore(memoryAckedStore());
    await refreshAckedSnapshot();
    stop();
  });
});
