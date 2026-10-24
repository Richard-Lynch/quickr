/**
 * The PWA's run data (timers.md §7.3): the server's open and finishing runs are one cached
 * `listRuns` answer, refreshed by polling (`lib/runs/useRuns.ts`) and patched with every
 * `run.event` response this device gets (`outboxEffects.ts`). The local view folds the
 * queued taps over it (`lib/runs/localView.ts`).
 */
import type { QueryClient } from '@tanstack/react-query';

import type { RunOut } from '../client';
import { listRunsQueryKey } from '../client/@tanstack/react-query.gen';
import { getOutboxSnapshot, outbox } from '../lib/outbox/client';
import type { RunTapDeps } from '../lib/runs/actions';
import { localRuns, openRunTopics, type LocalRun } from '../lib/runs/localView';

/** The one `listRuns` query: open and finishing runs of every topic. */
export const runsQueryKey = () => listRunsQueryKey();

/** `listRuns` lists open and finishing runs only; any other status leaves the cache. */
const LISTED: ReadonlySet<RunOut['status']> = new Set(['running', 'paused', 'finishing']);

export function cachedServerRuns(qc: QueryClient): RunOut[] {
  return qc.getQueryData<RunOut[]>(runsQueryKey()) ?? [];
}

/**
 * Put a run from a `run.event` response into the cache (§7.3: "it uses the response
 * directly"): replace the cached copy unless that one is newer, drop it once it closed, and
 * drop runs merged into it (`aliases`). A `listRuns` refetch already in flight is
 * cancelled, so a list read before this event can't bring back an older state.
 */
export async function upsertServerRun(qc: QueryClient, run: RunOut): Promise<void> {
  await qc.cancelQueries({ queryKey: runsQueryKey(), exact: true });
  qc.setQueryData<RunOut[]>(runsQueryKey(), (old = []) => {
    const merged = new Set(run.aliases.map((a) => a.toLowerCase()));
    const same = (r: RunOut) => r.id.toLowerCase() === run.id.toLowerCase();
    const cached = old.find(same);
    if (cached && cached.revision > run.revision) return old;
    const rest = old.filter((r) => !same(r) && !merged.has(r.id.toLowerCase()));
    return LISTED.has(run.status) ? [...rest, run] : rest;
  });
}

/** The local view from the cache and the outbox snapshot, outside React. */
export function localRunsNow(qc: QueryClient): LocalRun[] {
  return localRuns(cachedServerRuns(qc), getOutboxSnapshot().items);
}

/** Topics with an open run right now, for the badge's `dueCount`. */
export function openRunTopicsNow(qc: QueryClient): ReadonlySet<string> {
  return openRunTopics(localRunsNow(qc));
}

/** What `startRun` and `tapRun` need, on the page's outbox and query cache. */
export function runTapDeps(qc: QueryClient): RunTapDeps {
  return { outbox, serverRuns: () => cachedServerRuns(qc) };
}
