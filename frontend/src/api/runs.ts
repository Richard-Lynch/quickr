/**
 * The PWA's run data (timers.md §7.3): the server's open and finishing runs are one cached
 * `listRuns` answer, refreshed by polling (`lib/runs/useRuns.ts`) and patched with every
 * `run.event` response this device gets (`outboxEffects.ts`). The local view folds the
 * acked and queued taps over it (`lib/runs/localView.ts`, `lib/runs/acked.ts`).
 */
import { queryOptions, type QueryClient } from '@tanstack/react-query';

import { listRuns, type FeedDeletion, type RunOut } from '../client';
import { listRunsQueryKey } from '../client/@tanstack/react-query.gen';
import { getOutboxSnapshot, isOnline, outbox } from '../lib/outbox/client';
import { isCachedResponse } from '../lib/runs/serverClock';
import type { RunEventPayload } from '../lib/outbox/kinds';
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

/** A marker is forgotten this long after its last write (timers2.md §5.2). */
export const RUN_MARKER_MAX_AGE_MS = 30 * 24 * 60 * 60_000;

/**
 * `run_closed(id, revision)` markers (timers2.md §5.2), by lowercase id: the revision a run
 * closed at, or Infinity for a run deleted with its topic or an id merged into another run
 * (an alias is never a run of its own). Not tombstones: a run upsert with a higher revision
 * (a reopen) beats one. In memory for the session, like the cache they guard; the bound of
 * §5.2 (revision is monotonic per run) is what makes that enough.
 */
const markers = new Map<string, { revision: number; at: number }>();

/** Every marker write is `max(existing, new)`: a marker is only ever raised. */
const mark = (id: string, revision: number) => {
  const key = id.toLowerCase();
  const now = Date.now();
  markers.set(key, { revision: Math.max(markerOf(key) ?? -Infinity, revision), at: now });
};

/** The run's marker revision, if it has one (pruned after 30 days). */
function markerOf(id: string): number | undefined {
  const key = id.toLowerCase();
  const m = markers.get(key);
  if (!m) return undefined;
  if (Date.now() - m.at > RUN_MARKER_MAX_AGE_MS) {
    markers.delete(key);
    return undefined;
  }
  return m.revision;
}

/** Tests: forget the markers (module state, like the cache they guard). */
export function clearRunMarkers(): void {
  markers.clear();
}

/** A listed (feed) upsert at or below the run's marker is stale: it would reopen the run. */
const buried = (r: RunOut) => (markerOf(r.id) ?? -Infinity) >= r.revision;

export function cachedServerRuns(qc: QueryClient): RunOut[] {
  return qc.getQueryData<RunOut[]>(runsQueryKey()) ?? [];
}

/**
 * A `listRuns` answer merged into the cache it lands on: a cached copy with a higher
 * revision wins, a run a response put in the cache after the fetch began stays even if
 * the (older) list lacks it, and a row at or below its run's marker is dropped. A row
 * above it is a reopen (here or elsewhere): it applies, and clears the marker (§5.2).
 */
export function mergeListed(
  cached: readonly RunOut[],
  fetched: readonly RunOut[],
  fetchStartedAt: number,
): RunOut[] {
  const out = fetched
    .filter((f) => !buried(f))
    .map((f) => {
      markers.delete(f.id.toLowerCase());
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

/** The acked event behind a `run.event` response: its type, and whether it applied. */
export interface RunAck {
  type: RunEventPayload['event']['type'];
  applied: boolean;
}

/**
 * Put a run from a `run.event` response into the cache, synchronously (§7.3: "it uses the
 * response directly"), under timers2.md §5.2's revision rules, and drop runs merged into it
 * (`aliases`, fenced for good). Let `local` be the cached row, or the run's marker:
 * - an open or finishing run applies iff its revision is above the row's (equal replaces
 *   it: the same state); against a marker, iff above it **and** `ack` is an applied
 *   reopen (a delayed ack of an older tap never reopens a run). Applying clears the marker;
 * - a closed one (`stopped`, `discarded`) against a row applies iff its revision is above
 *   the row's (else the row is newer, a reopen: a no-op), deleting the row and writing the
 *   marker; with no row it raises the marker.
 * A list fetched earlier that lands later can't undo it ({@link mergeListed}).
 */
export function upsertServerRun(
  qc: QueryClient,
  run: RunOut,
  opts: { ack?: RunAck; now?: number } = {},
): void {
  const key = run.id.toLowerCase();
  for (const alias of run.aliases) mark(alias, Infinity);
  const old = cachedServerRuns(qc);
  const cached = old.find((r) => same(r, run));
  const merged = new Set(run.aliases.map((a) => a.toLowerCase()));
  const rest = old.filter((r) => !same(r, run) && !merged.has(r.id.toLowerCase()));
  const put = (runs: RunOut[]) => {
    qc.setQueryData<RunOut[]>(runsQueryKey(), runs);
  };
  if (!LISTED.has(run.status)) {
    if (cached && cached.revision >= run.revision) return;
    mark(run.id, run.revision);
    put(rest);
    return;
  }
  if (cached) {
    if (cached.revision > run.revision) return;
  } else {
    const marker = markerOf(key);
    const reopen = opts.ack === undefined || (opts.ack.type === 'reopen' && opts.ack.applied);
    if (marker !== undefined && !(run.revision > marker && reopen)) return;
  }
  markers.delete(key);
  upsertedAt.set(key, opts.now ?? Date.now());
  put([...rest, run]);
}

/**
 * A `run` deletion (`FeedDeletion`, timers2.md §5.1: the run closed, or was deleted with its
 * topic) under §5.2's rules: against a cached row it applies iff its revision is above the
 * row's, deleting the row (and fencing its aliases for good); it writes, or raises, the
 * marker. A null `revision` (a topic cascade) fences for good. The PWA has no feed today: its closes come from its own responses
 * ({@link upsertServerRun}); this is the same rule for a deletion it learns of.
 */
export function applyRunDeletion(
  qc: QueryClient,
  deletion: Pick<FeedDeletion, 'id' | 'revision'>,
): void {
  const revision = deletion.revision ?? Infinity;
  const old = cachedServerRuns(qc);
  const cached = old.find((r) => r.id.toLowerCase() === deletion.id.toLowerCase());
  if (cached && cached.revision >= revision) return;
  mark(deletion.id, revision);
  if (!cached) return;
  for (const alias of cached.aliases) mark(alias, Infinity);
  qc.setQueryData<RunOut[]>(
    runsQueryKey(),
    old.filter((r) => r !== cached),
  );
}

/** The local view from the cache, the outbox and the acked record, outside React. */
export function localRunsNow(qc: QueryClient): LocalRun[] {
  return localRuns(cachedServerRuns(qc), getOutboxSnapshot().items, getAckedSnapshot());
}

/** Topics with an open run right now, for the badge's `dueCount`. */
export function openRunTopicsNow(qc: QueryClient): ReadonlySet<string> {
  return openRunTopics(localRunsNow(qc));
}

/** How long a tap waits for its one `listRuns` refresh before going on without it. */
export const TAP_REFRESH_TIMEOUT_MS = 3_000;

/**
 * One `listRuns` fetch for a tap that missed its run, best effort: taps are serialised,
 * so it must always settle. Skipped offline; no retries and no pausing for the network
 * (the app's defaults would wait for it to come back); failures and timeouts are ignored.
 */
export function refreshRunsForTap(
  qc: QueryClient,
  timeoutMs: number = TAP_REFRESH_TIMEOUT_MS,
): Promise<void> {
  if (!isOnline()) return Promise.resolve();
  const fetched = qc
    .query({ ...runsQueryOptions(qc), staleTime: 0, retry: false, networkMode: 'always' })
    .then(
      () => undefined,
      () => undefined,
    );
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, timeoutMs);
  });
  return Promise.race([fetched, timeout]).finally(() => {
    clearTimeout(timer);
  });
}

/** What `startRun` and `tapRun` need, on the page's outbox and query cache. */
export function runTapDeps(qc: QueryClient, refreshTimeoutMs?: number): RunTapDeps {
  return {
    outbox,
    serverRuns: () => cachedServerRuns(qc),
    acked: ackedItems,
    refresh: () => refreshRunsForTap(qc, refreshTimeoutMs),
  };
}
