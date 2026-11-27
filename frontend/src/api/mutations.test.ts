/** `useUpdateTopicMeta` shows an appearance PATCH at once, everywhere the topic is cached. */
import { QueryClient, QueryClientProvider, type InfiniteData } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { createElement, type ReactNode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { TopicDetail, TopicPage } from '../client';
import { getTopicQueryKey, listTopicsInfiniteQueryKey } from '../client/@tanstack/react-query.gen';
import { client } from '../client/client.gen';
import type { Appearance } from '../lib/appearance';
import { appearanceOf, type TopicUpdateBody } from '../lib/topicAppearanceSeam';
import { applyAppearanceUpdate, useUpdateTopicMeta } from './mutations';

const before: Appearance = { color: 'red', icon: { kind: 'emoji', value: '🏃' }, tags: ['sport'] };
const topic = {
  id: '6f1c0000-0000-4000-8000-000000000001',
  slug: 'gym',
  name: 'Gym',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 4,
  question_count: 0,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: null,
  last_entry: null,
  questions: [],
  appearance: before,
} satisfies TopicDetail;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

/** A PATCH the test answers when it calls `respond` (so the optimistic state can be read). */
function pendingPatch() {
  const sent: unknown[] = [];
  let respond: (r: Response) => void = () => undefined;
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: Request) => {
      sent.push(JSON.parse(await input.text()));
      return new Promise<Response>((resolve) => {
        respond = resolve;
      });
    }),
  );
  return { sent, respond: (r: Response) => respond(r) };
}

function setup() {
  // The generated keys carry the client's baseUrl, so build them after `beforeEach` sets it.
  const detailKey = getTopicQueryKey({ path: { ref: 'gym' } });
  const listKey = listTopicsInfiniteQueryKey({ query: { status: 'active' } });
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity } },
  });
  qc.setQueryData(detailKey, topic);
  qc.setQueryData<InfiniteData<TopicPage>>(listKey, {
    pages: [{ items: [topic], total: 1, limit: 20, offset: 0 }],
    pageParams: [0],
  });
  const wrapper = ({ children }: { children: ReactNode }) =>
    createElement(QueryClientProvider, { client: qc }, children);
  const { result } = renderHook(() => useUpdateTopicMeta(), { wrapper });
  const detail = () => appearanceOf(qc.getQueryData<TopicDetail>(detailKey) ?? {});
  const tile = () =>
    appearanceOf(qc.getQueryData<InfiniteData<TopicPage>>(listKey)?.pages[0]?.items[0] ?? {});
  return { result, detail, tile };
}

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('applyAppearanceUpdate', () => {
  it('changes only the fields present, null and [] clearing', () => {
    expect(applyAppearanceUpdate(before, { color: 'blue' })).toEqual({ ...before, color: 'blue' });
    expect(applyAppearanceUpdate(before, { icon: null, tags: [] })).toEqual({
      color: 'red',
      icon: null,
      tags: [],
    });
    expect(applyAppearanceUpdate(null, { tags: ['a'] })).toEqual({
      color: null,
      icon: null,
      tags: ['a'],
    });
  });
});

describe('useUpdateTopicMeta appearance', () => {
  const body: TopicUpdateBody = { appearance: { color: 'teal', icon: null }, expected_revision: 4 };

  it('patches the tile and the detail before the server answers, then takes its reply', async () => {
    const server = pendingPatch();
    const { result, detail, tile } = setup();
    act(() => result.current.mutate({ path: { ref: 'gym' }, body }));
    const optimistic = { color: 'teal', icon: null, tags: ['sport'] };
    await waitFor(() => expect(tile()).toEqual(optimistic));
    expect(detail()).toEqual(optimistic);
    expect(server.sent).toEqual([body]);

    const saved = { color: 'teal', icon: null, tags: ['sport', 'from-server'] };
    server.respond(json(200, { ...topic, revision: 5, appearance: saved }));
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(detail()).toEqual(saved);
  });

  it('restores the previous appearance when the PATCH fails', async () => {
    const server = pendingPatch();
    const { result, detail, tile } = setup();
    act(() => result.current.mutate({ path: { ref: 'gym' }, body }));
    await waitFor(() => expect(tile()?.color).toBe('teal'));
    server.respond(json(409, { code: 'stale_revision', detail: 'The topic changed', errors: [] }));
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(tile()).toEqual(before);
    expect(detail()).toEqual(before);
  });

  it('leaves the appearance alone for a PATCH without one', async () => {
    const server = pendingPatch();
    const { result, tile } = setup();
    act(() => result.current.mutate({ path: { ref: 'gym' }, body: { name: 'Lifting' } }));
    await waitFor(() => expect(server.sent).toHaveLength(1));
    expect(tile()).toEqual(before);
  });
});
