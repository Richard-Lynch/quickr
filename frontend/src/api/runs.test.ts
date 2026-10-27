import { QueryClient } from '@tanstack/react-query';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { client } from '../client/client.gen';
import { ackedItems, memoryAckedStore, recordAcked, setAckedStore } from '../lib/runs/acked';
import { T0, ev, runItem, serverRun } from '../test/runs';
import { FROM_CACHE_HEADER } from './constants';
import {
  cachedServerRuns,
  mergeCachedListed,
  mergeListed,
  runsQueryKey,
  runsQueryOptions,
  upsertServerRun,
} from './runs';

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

describe('mergeListed: tombstones of closed runs (M4)', () => {
  // Ids of their own: tombstones are module state.
  const R3 = '00000000-0000-4000-8000-000000000003';
  const R4 = '00000000-0000-4000-8000-000000000004';
  const R5 = '00000000-0000-4000-8000-000000000005';

  it('a list fetched before a response closed a run doesn’t reopen it', () => {
    const qc = new QueryClient();
    qc.setQueryData(runsQueryKey(), [run(R3, 2)]);
    const fetchStartedAt = Date.now() - 1000;
    upsertServerRun(qc, run(R3, 3, 'stopped'));
    expect(cachedServerRuns(qc)).toEqual([]);
    // The stale list still has R3 open, at its old revision.
    expect(mergeListed(cachedServerRuns(qc), [run(R3, 2)], fetchStartedAt)).toEqual([]);
    expect(mergeListed(cachedServerRuns(qc), [run(R3, 3)], fetchStartedAt)).toEqual([]);
    // A later revision is news (an edit since).
    expect(mergeListed([], [run(R3, 4)], fetchStartedAt).map((r) => r.revision)).toEqual([4]);
  });

  it('nor a run merged into another (an alias)', () => {
    const qc = new QueryClient();
    const merged = { ...run(R4, 2), aliases: [R5] };
    upsertServerRun(qc, merged);
    const listed = mergeListed(cachedServerRuns(qc), [run(R5, 7), run(R4, 2)], Date.now() - 1000);
    expect(listed.map((r) => r.id)).toEqual([R4]);
  });
});
