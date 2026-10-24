import { QueryClient } from '@tanstack/react-query';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { client } from '../client/client.gen';
import { ackedItems, memoryAckedStore, recordAcked, setAckedStore } from '../lib/runs/acked';
import { T0, ev, runItem, serverRun } from '../test/runs';
import { FROM_CACHE_HEADER } from './constants';
import { cachedServerRuns, mergeCachedListed, runsQueryKey, runsQueryOptions } from './runs';

// Parsed by the generated client (zListRunsResponse): real UUIDs.
const R1 = '00000000-0000-4000-8000-000000000001';
const R2 = '00000000-0000-4000-8000-000000000002';
const TOPIC = '00000000-0000-4000-8000-0000000000aa';
const run = (id: string, revision: number, status?: 'stopped' | 'finishing') =>
  serverRun(id, [ev(id, 'start', T0)], {
    topic_id: TOPIC,
    revision,
    ...(status ? { status } : {}),
  });

// Node's Request needs absolute URLs; the app itself uses same-origin paths.
beforeAll(() => {
  client.setConfig({ baseUrl: 'http://localhost' });
});
afterAll(() => {
  client.setConfig({ baseUrl: '' });
});
beforeEach(() => {
  setAckedStore(memoryAckedStore());
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('mergeCachedListed', () => {
  it('only brings newer revisions of cached runs: no drops, no additions', () => {
    const cached = [run(R1, 3)];
    expect(mergeCachedListed(cached, [])).toEqual(cached);
    expect(mergeCachedListed(cached, [run(R1, 3), run(R2, 1)])).toEqual(cached);
    expect(mergeCachedListed(cached, [run(R1, 2)])).toEqual(cached);
    expect(mergeCachedListed(cached, [run(R1, 4)])[0]?.revision).toBe(4);
  });
});

describe('the runs query', () => {
  const answer = (runs: unknown, headers: Record<string, string> = {}) =>
    vi.fn(() =>
      Promise.resolve(
        new Response(JSON.stringify(runs), {
          headers: { 'Content-Type': 'application/json', ...headers },
        }),
      ),
    );

  it('treats an answer from a cache as additive: no pruning, no dropped or reopened runs', async () => {
    const qc = new QueryClient();
    qc.setQueryData(runsQueryKey(), [run(R1, 2)]);
    await recordAcked(runItem('start', { id: R1, run: R1, at: T0 }), Date.now() - 1000);
    // A stale list: R1 missing, and R2 (closed since) listed as open.
    vi.stubGlobal('fetch', answer([run(R2, 1)], { [FROM_CACHE_HEADER]: '1' }));
    await qc.query({ ...runsQueryOptions(qc), staleTime: 0 });
    expect(cachedServerRuns(qc).map((r) => r.id)).toEqual([R1]);
    expect((await ackedItems()).map((i) => i.id)).toEqual([R1]);
  });

  it('a fresh answer replaces the list and prunes what it covers', async () => {
    const qc = new QueryClient();
    qc.setQueryData(runsQueryKey(), [run(R1, 2)]);
    await recordAcked(runItem('start', { id: R1, run: R1, at: T0 }), Date.now() - 1000);
    vi.stubGlobal('fetch', answer([run(R2, 1)]));
    await qc.query({ ...runsQueryOptions(qc), staleTime: 0 });
    expect(cachedServerRuns(qc).map((r) => r.id)).toEqual([R2]);
    expect(await ackedItems()).toEqual([]);
  });
});
