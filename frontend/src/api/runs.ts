/**
 * The PWA's run data (timers.md §7.3): the server's open and finishing runs are one cached
 * `listRuns` answer, refreshed by polling (`lib/runs/useRuns.ts`) and patched with every
 * `run.event` response this device gets (`outboxEffects.ts`). The local view folds the
 * acked and queued taps over it (`lib/runs/localView.ts`, `lib/runs/acked.ts`).
 */
import { queryOptions, type QueryClient } from '@tanstack/react-query';

import { listRuns, type RunOut } from '../client';
import { listRunsQueryKey } from '../client/@tanstack/react-query.gen';
import { getOutboxSnapshot, outbox } from '../lib/outbox/client';
import { isCachedResponse } from '../lib/runs/serverClock';
import type { RunTapDeps } from '../lib/runs/actions';
import { ackedItems, getAckedSnapshot, pruneAcked } from '../lib/runs/acked';
import { localRuns, openRunTopics, type LocalRun } from '../lib/runs/localView';

/** The one `listRuns` query: open and finishing runs of every topic. */
export const runsQueryKey = () => listRunsQueryKey();

/** `listRuns` lists open and finishing runs only; any other status leaves the cache. */
const LISTED: ReadonlySet<RunOut['status']> = new Set(['running', 'paused', 'finishing']);

const same = (a: RunOut, b: RunOut) => a.id.toLowerCase() === b.id.toLowerCase();

/** When each run was last put in the cache from a response (device ms), by lowercase id. */
const upsertedAt = new Map<string, number>();

export function cachedServerRuns(qc: QueryClient): RunOut[] {
  return qc.getQueryData<RunOut[]>(runsQueryKey()) ?? [];
}

/**
 * A `listRuns` answer merged into the cache it lands on: a cached copy with a higher
 * revision wins, and a run a response put in the cache after the fetch began stays even if
 * the (older) list lacks it.
 */
export function mergeListed(
  cached: readonly RunOut[],
  fetched: readonly RunOut[],
  fetchStartedAt: number,
): RunOut[] {
  const out = fetched.map((f) => {
    const c = cached.find((r) => same(r, f));
    return c && c.revision > f.revision ? c : f;
  });
  for (const c of cached) {
    const late = (upsertedAt.get(c.id.toLowerCase()) ?? -Infinity) >= fetchStartedAt;
    if (late && !out.some((r) => same(r, c))) out.push(c);
  }
  return out;
}

/**
 * A `listRuns` answer from a cache (it may be any age) merged into the cache: it can only
 * bring a cached run's newer revision. It never drops a run, and never adds one, which
 * could reopen a run that has since closed.
 */
export function mergeCachedListed(cached: readonly RunOut[], fetched: readonly RunOut[]): RunOut[] {
  return cached.map((c) => {
    const f = fetched.find((r) => same(r, c));
    return f && f.revision > c.revision && LISTED.has(f.status) ? f : c;
  });
}

/**
 * The runs query: `listRuns`, merged into the cache by {@link mergeListed}. A fresh answer
 * also prunes the acked-runs record of what it covers. One served from a cache (the
 * service worker doesn't cache `/runs`, but an older one or an HTTP cache might) is
 * additive only ({@link mergeCachedListed}) and prunes nothing.
 */
export function runsQueryOptions(qc: QueryClient) {
  return queryOptions({
    queryKey: runsQueryKey(),
    queryFn: async ({ signal }) => {
      const startedAt = Date.now();
      const { data, response } = await listRuns({ signal, throwOnError: true });
      if (isCachedResponse(response)) return mergeCachedListed(cachedServerRuns(qc), data);
      await pruneAcked(startedAt);
      return mergeListed(cachedServerRuns(qc), data, startedAt);
    },
  });
}

/**
 * Put a run from a `run.event` response into the cache, synchronously (§7.3: "it uses the
 * response directly"): replace the cached copy unless that one is newer, drop it once it
 * closed, and drop runs merged into it (`aliases`). A list fetched earlier that lands
 * later can't undo it ({@link mergeListed}).
 */
export function upsertServerRun(qc: QueryClient, run: RunOut, now: number = Date.now()): void {
  upsertedAt.set(run.id.toLowerCase(), now);
  qc.setQueryData<RunOut[]>(runsQueryKey(), (old = []) => {
    const merged = new Set(run.aliases.map((a) => a.toLowerCase()));
    const cached = old.find((r) => same(r, run));
    if (cached && cached.revision > run.revision) return old;
    const rest = old.filter((r) => !same(r, run) && !merged.has(r.id.toLowerCase()));
    return LISTED.has(run.status) ? [...rest, run] : rest;
  });
}

/** The local view from the cache, the outbox and the acked record, outside React. */
export function localRunsNow(qc: QueryClient): LocalRun[] {
  return localRuns(cachedServerRuns(qc), getOutboxSnapshot().items, getAckedSnapshot());
}

/** Topics with an open run right now, for the badge's `dueCount`. */
export function openRunTopicsNow(qc: QueryClient): ReadonlySet<string> {
  return openRunTopics(localRunsNow(qc));
}

/** What `startRun` and `tapRun` need, on the page's outbox and query cache. */
export function runTapDeps(qc: QueryClient): RunTapDeps {
  return {
    outbox,
    serverRuns: () => cachedServerRuns(qc),
    acked: ackedItems,
    refresh: () => qc.query({ ...runsQueryOptions(qc), staleTime: 0 }).then(() => undefined),
  };
}
