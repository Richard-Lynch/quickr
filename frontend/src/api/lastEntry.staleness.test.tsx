/**
 * content-display.md §2, the PWA's `last_entry` staleness bound (≤ 60 s; review D4): the
 * home list refetches `listTopics` every 60 s and on focus, so an entry changed on another
 * device reaches the tile within one refetch; an outbox ack (`entry.create`, a `run.event`
 * that made the entry) and an entry edit invalidate the topic's `listTopics` pages, so a
 * local change lands at once, without waiting for the interval.
 */
import {
  focusManager,
  InfiniteQueryObserver,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { EntryOut, TopicPage, TopicSummary } from '../client';
import { client } from '../client/client.gen';
import { listTopicsInfiniteOptions } from '../client/@tanstack/react-query.gen';
import { ENTRY_CREATE, type EntryCreatePayload } from '../lib/outbox/kinds';
import type { Outbox, OutboxListener } from '../lib/outbox/outbox';
import type { OutboxEvent, OutboxItem } from '../lib/outbox/types';
import { renderRunApp, RUN_ID, summaryOf, timedTopic, type Harness } from '../test/runUi';
import { ev, runItem, serverRun, T0 } from '../test/runs';
import { useUpdateEntry } from './mutations';
import { connectOutboxEffects } from './outboxEffects';

// The list is validated (zod), so ids are UUIDs.
const E_REMOTE = '0e5e0000-0000-4000-8000-000000000001';
const E_FOCUS = '0e5e0000-0000-4000-8000-000000000002';
const E_LOCAL = '0e5e0000-0000-4000-8000-000000000003';
const E_EDIT = '0e5e0000-0000-4000-8000-000000000004';

const entry = (id: string, topicId: string): EntryOut => ({
  id,
  topic_id: topicId,
  version: 1,
  revision: 1,
  source: 'phone',
  channel: 'ui',
  captured_at: '2026-10-24T08:00:05Z',
  created_at: '2026-10-24T08:00:05Z',
  updated_at: '2026-10-24T08:00:05Z',
  notes: '',
  meta: {},
  answers: [],
  timing: null,
});

const json = (body: unknown) =>
  new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });

const urlOf = (input: RequestInfo | URL) =>
  new URL(input instanceof Request ? input.url : input instanceof URL ? input.href : input);

/**
 * A server whose `GET /topics` lists `topic` with the current `remote` last entry; `next`
 * replaces it (a change made elsewhere). Other requests go to `rest`. Counts topic lists.
 */
function remoteTopics(topic: TopicSummary, rest?: typeof fetch) {
  let last: EntryOut | null = topic.last_entry;
  let lists = 0;
  const fetchFn = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
    const url = urlOf(input);
    if (url.pathname === '/api/v1/topics') {
      lists++;
      const page: TopicPage = {
        items: [{ ...topic, last_entry: last }],
        total: 1,
        limit: 50,
        offset: 0,
      };
      return Promise.resolve(json(page));
    }
    if (rest) return rest(input, init);
    return Promise.reject(new Error(`unexpected ${url.pathname}`));
  });
  return {
    fetchFn,
    next(e: EntryOut | null) {
      last = e;
    },
    lists: () => lists,
  };
}

/** The `last_entry` ids every cached `listTopics` page holds. */
function cachedLastEntries(qc: QueryClient): (string | null)[] {
  return qc
    .getQueryCache()
    .findAll()
    .filter((q) => (q.queryKey[0] as { _id?: string } | undefined)?._id === 'listTopics')
    .flatMap((q) => {
      const data = q.state.data as { pages: TopicPage[] } | undefined;
      return data?.pages.flatMap((p) => p.items.map((t) => t.last_entry?.id ?? null)) ?? [];
    });
}

describe('the home list (TopicsPage)', () => {
  let h: Harness | null = null;

  afterEach(async () => {
    vi.useRealTimers();
    await h?.teardown();
    h = null;
  });

  it('shows an entry made on another device within one 60 s refetch, and on focus', async () => {
    // Only the interval is faked: the outbox and IndexedDB keep their real timers.
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
    const fixture = timedTopic();
    h = renderRunApp('/', fixture);
    const remote = remoteTopics(summaryOf(fixture.topic), globalThis.fetch);
    vi.stubGlobal('fetch', remote.fetchFn);
    const qc = h.qc;
    await waitFor(() => expect(cachedLastEntries(qc)).toEqual([null]));

    remote.next(entry(E_REMOTE, fixture.topic.id));
    const before = remote.lists();
    await act(async () => {
      vi.advanceTimersByTime(59_000);
      await Promise.resolve();
    });
    expect(remote.lists()).toBe(before);
    expect(cachedLastEntries(qc)).toEqual([null]);
    await act(async () => {
      vi.advanceTimersByTime(1_000);
      await Promise.resolve();
    });
    await waitFor(() => expect(cachedLastEntries(qc)).toEqual([E_REMOTE]));
    expect(remote.lists()).toBe(before + 1);

    // Returning to the app refetches too (once the list is stale; the harness's is at once).
    remote.next(entry(E_FOCUS, fixture.topic.id));
    act(() => {
      focusManager.setFocused(false);
      focusManager.setFocused(true);
    });
    await waitFor(() => expect(cachedLastEntries(qc)).toEqual([E_FOCUS]));
    focusManager.setFocused(undefined);
  });
});

describe('local changes', () => {
  const topic = summaryOf(timedTopic().topic);

  afterEach(() => {
    client.setConfig({ baseUrl: '' });
    vi.unstubAllGlobals();
  });

  /** A client watching the home list (as `TopicsPage` does), wired to a fake outbox. */
  async function watching(rest?: typeof fetch) {
    const remote = remoteTopics(topic, rest);
    vi.stubGlobal('fetch', remote.fetchFn);
    client.setConfig({ baseUrl: 'http://quickr.test' });
    const qc = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 20_000 } },
    });
    const observer = new InfiniteQueryObserver(qc, {
      ...listTopicsInfiniteOptions({ query: { status: 'active', sort: 'due', limit: 50 } }),
      initialPageParam: 0,
      getNextPageParam: () => undefined,
    });
    const unsubscribe = observer.subscribe(() => undefined);
    let listener: OutboxListener = () => undefined;
    const outbox = {
      subscribe(l: OutboxListener) {
        listener = l;
        return () => undefined;
      },
    } as unknown as Outbox;
    const disconnect = connectOutboxEffects(qc, outbox);
    await waitFor(() => expect(cachedLastEntries(qc)).toEqual([null]));
    return {
      qc,
      remote,
      emit: (e: OutboxEvent) => {
        listener(e, false);
      },
      done: () => {
        unsubscribe();
        disconnect();
        qc.clear();
      },
    };
  }

  it('an entry.create ack refetches the list at once', async () => {
    const w = await watching();
    const item: OutboxItem<EntryCreatePayload> = {
      id: E_LOCAL,
      kind: ENTRY_CREATE,
      payload: {
        topic: { id: topic.id, slug: topic.slug, name: topic.name },
        body: { answers: {}, captured_at: '2026-10-24T08:00:05Z' },
      },
      created_at: '2026-10-24T08:00:05Z',
      updated_at: '2026-10-24T08:00:05Z',
      attempts: 0,
      status: 'pending',
      next_attempt_at: 0,
      last_error: null,
    };
    const before = w.remote.lists();
    w.remote.next(entry(E_LOCAL, topic.id));
    w.emit({ type: 'sent', item, data: entry(E_LOCAL, topic.id) });
    await waitFor(() => expect(cachedLastEntries(w.qc)).toEqual([E_LOCAL]));
    expect(w.remote.lists()).toBe(before + 1);
    w.done();
  });

  it('a run stop that made the entry refetches the list at once', async () => {
    const w = await watching();
    const R1 = RUN_ID;
    const S1 = '0e5e0000-0000-4000-8000-000000000005';
    const stopped = serverRun(R1, [ev(R1, 'start', T0), ev(S1, 'stop', T0 + 5000)], {
      topic_id: topic.id,
    });
    const before = w.remote.lists();
    w.remote.next(entry(R1, topic.id));
    w.emit({
      type: 'sent',
      item: runItem('stop', { id: S1, run: R1, at: T0 + 5000, makes_entry: true }),
      data: {
        event: { id: S1, effect: 'applied', reason: null },
        run: stopped,
        entry: entry(R1, topic.id),
      },
    });
    await waitFor(() => expect(cachedLastEntries(w.qc)).toEqual([R1]));
    expect(w.remote.lists()).toBe(before + 1);
    w.done();
  });

  it('an entry edit refetches the list once it settles', async () => {
    const edited = { ...entry(E_EDIT, topic.id), notes: 'edited', revision: 2 };
    const w = await watching((input) => {
      const url = urlOf(input);
      if (url.pathname === `/api/v1/entries/${E_EDIT}`) return Promise.resolve(json(edited));
      return Promise.reject(new Error(`unexpected ${url.pathname}`));
    });
    const wrapper = ({ children }: { children: ReactNode }) => (
      <QueryClientProvider client={w.qc}>{children}</QueryClientProvider>
    );
    const { result } = renderHook(() => useUpdateEntry(), { wrapper });
    const before = w.remote.lists();
    w.remote.next(edited);
    await act(async () => {
      await result.current.mutateAsync({ path: { entry_id: E_EDIT }, body: { notes: 'edited' } });
    });
    await waitFor(() => expect(cachedLastEntries(w.qc)).toEqual([E_EDIT]));
    expect(w.remote.lists()).toBe(before + 1);
    w.done();
  });
});
