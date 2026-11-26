import { QueryClient } from '@tanstack/react-query';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { RunOut } from '../client';
import { client } from '../client/client.gen';
import { ackedItems, memoryAckedStore, recordAcked, setAckedStore } from '../lib/runs/acked';
import { T0, ev, runItem, serverRun } from '../test/runs';
import { FROM_CACHE_HEADER } from './constants';
import {
  applyRunDeletion,
  cachedServerRuns,
  clearRunMarkers,
  RUN_MARKER_MAX_AGE_MS,
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

describe('run_closed markers (timers2.md §5.2)', () => {
  const id = (n: number) => `00000000-0000-4000-8000-0000000001${String(n).padStart(2, '0')}`;
  const open = (rid: string, revision: number) => run(rid, revision);
  const closed = (rid: string, revision: number) => run(rid, revision, 'stopped');
  const reopenAck = { type: 'reopen', applied: true } as const;
  const ids = (qc: QueryClient) => cachedServerRuns(qc).map((r) => [r.id, r.revision]);
  const listed = (qc: QueryClient, fetched: RunOut[]) =>
    mergeListed(cachedServerRuns(qc), fetched, Date.now() - 1000);
  const fresh = () => {
    clearRunMarkers();
    const qc = new QueryClient();
    return qc;
  };

  it("a closing ack's marker is beaten by a higher-revision list row: the run re-lists", () => {
    const qc = fresh();
    upsertServerRun(qc, open(id(1), 2));
    upsertServerRun(qc, closed(id(1), 3));
    expect(listed(qc, [open(id(1), 3)])).toEqual([]);
    // Another device reopened it (revision 4): a list fetched now has it open.
    expect(listed(qc, [open(id(1), 4)]).map((r) => r.revision)).toEqual([4]);
  });

  it('an applied-reopen ack beats the marker; a delayed older ack and a non-reopen ack stay buried', () => {
    const qc = fresh();
    upsertServerRun(qc, closed(id(2), 3));
    // A lap tapped before the stop, acked late (revision 2).
    upsertServerRun(qc, open(id(2), 2), { ack: { type: 'lap', applied: true } });
    expect(ids(qc)).toEqual([]);
    // A newer revision, but from a lap's ack: a delayed ack can never reopen a run.
    upsertServerRun(qc, open(id(2), 5), { ack: { type: 'lap', applied: true } });
    expect(ids(qc)).toEqual([]);
    // A void reopen doesn't either.
    upsertServerRun(qc, open(id(2), 5), { ack: { type: 'reopen', applied: false } });
    expect(ids(qc)).toEqual([]);
    upsertServerRun(qc, open(id(2), 4), { ack: reopenAck });
    expect(ids(qc)).toEqual([[id(2), 4]]);
    // The marker is cleared: the run is a row again, with the row's revision guard.
    upsertServerRun(qc, open(id(2), 5), { ack: { type: 'lap', applied: true } });
    expect(ids(qc)).toEqual([[id(2), 5]]);
  });

  it("an applied reopen at or below the marker's revision stays buried", () => {
    const qc = fresh();
    upsertServerRun(qc, closed(id(3), 6));
    upsertServerRun(qc, open(id(3), 6), { ack: reopenAck });
    expect(ids(qc)).toEqual([]);
  });

  it('a delayed stop ack after the reopen upsert is a no-op: the run stays open', () => {
    const qc = fresh();
    upsertServerRun(qc, closed(id(4), 3));
    upsertServerRun(qc, open(id(4), 4), { ack: reopenAck });
    upsertServerRun(qc, closed(id(4), 3)); // the stop's ack, delivered again late
    expect(ids(qc)).toEqual([[id(4), 4]]);
    expect(listed(qc, [open(id(4), 4)]).map((r) => r.revision)).toEqual([4]);
    // A re-stop (a newer close) does close it.
    upsertServerRun(qc, closed(id(4), 5));
    expect(ids(qc)).toEqual([]);
    expect(listed(qc, [open(id(4), 4)])).toEqual([]);
  });

  it('a marker is only ever raised: an older close after a newer one keeps the higher fence', () => {
    const qc = fresh();
    upsertServerRun(qc, closed(id(5), 5));
    upsertServerRun(qc, closed(id(5), 3));
    expect(listed(qc, [open(id(5), 4)])).toEqual([]);
    expect(listed(qc, [open(id(5), 6)]).map((r) => r.revision)).toEqual([6]);
  });

  describe('a run deletion (FeedDeletion with revision)', () => {
    it('followed by an upsert with a higher revision re-lists the run', () => {
      const qc = fresh();
      qc.setQueryData(runsQueryKey(), [open(id(6), 2)]);
      applyRunDeletion(qc, { id: id(6), revision: 3 });
      expect(ids(qc)).toEqual([]);
      expect(listed(qc, [open(id(6), 3)])).toEqual([]);
      expect(listed(qc, [open(id(6), 4)]).map((r) => r.revision)).toEqual([4]);
    });

    it('against a newer row is a no-op (an older page after a newer ack)', () => {
      const qc = fresh();
      upsertServerRun(qc, open(id(7), 5), { ack: reopenAck });
      applyRunDeletion(qc, { id: id(7), revision: 3 });
      expect(ids(qc)).toEqual([[id(7), 5]]);
    });

    it('null (a topic cascade) or absent fences for good', () => {
      const qc = fresh();
      applyRunDeletion(qc, { id: id(8), revision: null });
      applyRunDeletion(qc, { id: id(9) });
      expect(listed(qc, [open(id(8), 99), open(id(9), 99)])).toEqual([]);
      upsertServerRun(qc, open(id(8), 99), { ack: reopenAck });
      expect(ids(qc)).toEqual([]);
    });

    it('fences the run’s aliases for good', () => {
      const qc = fresh();
      qc.setQueryData(runsQueryKey(), [{ ...open(id(10), 2), aliases: [id(11)] }]);
      applyRunDeletion(qc, { id: id(10), revision: 3 });
      expect(listed(qc, [open(id(11), 99)])).toEqual([]);
    });
  });

  it('markers prune after 30 days', () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    try {
      const qc = fresh();
      upsertServerRun(qc, closed(id(12), 3));
      vi.setSystemTime(Date.now() + RUN_MARKER_MAX_AGE_MS + 1);
      expect(listed(qc, [open(id(12), 3)]).map((r) => r.revision)).toEqual([3]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('bootstrap after a reopen elsewhere: a fresh listRuns lists the run', async () => {
    const qc = fresh();
    const R = id(13);
    upsertServerRun(qc, open(R, 1));
    upsertServerRun(qc, closed(R, 2));
    expect(cachedServerRuns(qc)).toEqual([]);
    vi.stubGlobal(
      'fetch',
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify([open(R, 3)]), {
            headers: { 'Content-Type': 'application/json' },
          }),
        ),
      ),
    );
    await qc.query({ ...runsQueryOptions(qc), staleTime: 0 });
    expect(ids(qc)).toEqual([[R, 3]]);
  });
});
