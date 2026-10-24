import { QueryClient } from '@tanstack/react-query';

import { zProblem } from '../client/zod.gen';
import { keyMeta } from './cache';

/** Don't retry domain errors (4xx Problems) — only transient failures. */
function shouldRetry(failureCount: number, error: unknown): boolean {
  if (zProblem.safeParse(error).success) return false;
  return failureCount < 2;
}

/**
 * How long cached data is kept (in memory and in the IndexedDB snapshot). Must be
 * ≥ the persister's `maxAge`, or restored queries would be garbage-collected at once.
 */
export const CACHE_GC_TIME = 7 * 24 * 60 * 60 * 1000;

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 20_000,
        gcTime: CACHE_GC_TIME,
        retry: shouldRetry,
        // Run the queryFn even when the browser says offline: the service worker may
        // answer from its runtime cache. If it fails, the query pauses (keeping any
        // cached/persisted data on screen) and resumes when the connection returns.
        networkMode: 'offlineFirst',
      },
      // Plain mutations fail fast offline with a clear message instead of hanging
      // "pending" forever; durable writes go through the outbox (src/lib/outbox).
      mutations: { retry: false, networkMode: 'always' },
    },
  });
}

export type OperationId =
  | 'listTopics'
  | 'getTopic'
  | 'listTopicVersions'
  | 'listEntries'
  | 'getEntry'
  | 'getTopicStats'
  | 'getQuestionSeries'
  | 'getTopicTiming'
  | 'listRuns';

/** Invalidate every cached query for the given generated operations. */
export function invalidateOperations(qc: QueryClient, ids: readonly OperationId[]): Promise<void> {
  return qc.invalidateQueries({
    predicate: (q) => {
      const op = keyMeta(q.queryKey)?._id;
      return op !== undefined && (ids as readonly string[]).includes(op);
    },
  });
}

/** Everything whose numbers depend on the set of entries. */
export const ENTRY_DATA_OPS: readonly OperationId[] = [
  'listTopics',
  'getTopic',
  'listTopicVersions',
  'listEntries',
  'getTopicStats',
  'getQuestionSeries',
  // Timed entries' run times (timers.md §9.2): a stop, a finish or an Edit times changes them.
  'getTopicTiming',
];

/**
 * Anything that changes entries changes counts, stats and series too.
 * (Single-entry caches are updated/removed explicitly by the caller.)
 */
export function invalidateEntryData(qc: QueryClient): Promise<void> {
  return invalidateOperations(qc, ENTRY_DATA_OPS);
}

export function invalidateTopicData(qc: QueryClient): Promise<void> {
  return invalidateEntryData(qc);
}
