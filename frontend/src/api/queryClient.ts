import { QueryClient, type QueryKey } from '@tanstack/react-query';

import { zProblem } from '../client/zod.gen';

/** Don't retry domain errors (4xx Problems) — only transient failures. */
function shouldRetry(failureCount: number, error: unknown): boolean {
  if (zProblem.safeParse(error).success) return false;
  return failureCount < 2;
}

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 20_000,
        retry: shouldRetry,
      },
      mutations: { retry: false },
    },
  });
}

type OperationId =
  | 'listTopics'
  | 'getTopic'
  | 'listTopicVersions'
  | 'listSessions'
  | 'getSession'
  | 'getTopicStats'
  | 'getQuestionSeries';

/** Generated query keys are `[{ _id: operationId, path, query, ... }]`. */
function operationOf(key: QueryKey): string | undefined {
  const first: unknown = key[0];
  if (typeof first === 'object' && first !== null && '_id' in first) {
    const id = first._id;
    return typeof id === 'string' ? id : undefined;
  }
  return undefined;
}

/** Invalidate every cached query for the given generated operations. */
export function invalidateOperations(qc: QueryClient, ids: readonly OperationId[]): Promise<void> {
  return qc.invalidateQueries({
    predicate: (q) => {
      const op = operationOf(q.queryKey);
      return op !== undefined && (ids as readonly string[]).includes(op);
    },
  });
}

/**
 * Anything that changes sessions changes counts, stats and series too.
 * (Single-session caches are updated/removed explicitly by the caller.)
 */
export function invalidateSessionData(qc: QueryClient): Promise<void> {
  return invalidateOperations(qc, [
    'listTopics',
    'getTopic',
    'listTopicVersions',
    'listSessions',
    'getTopicStats',
    'getQuestionSeries',
  ]);
}

export function invalidateTopicData(qc: QueryClient): Promise<void> {
  return invalidateSessionData(qc);
}
