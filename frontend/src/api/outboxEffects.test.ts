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
import { connectOutboxEffects } from './outboxEffects';

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
