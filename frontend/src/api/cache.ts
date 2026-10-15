/**
 * Typed helpers for optimistic cache edits on top of the generated query keys
 * (`[{ _id: operationId, path, query, _infinite? }]`).
 *
 * Pattern (TanStack "onMutate / rollback"):
 *   onMutate:  await cancelOperations(qc, ops); const snap = snapshotOperations(qc, ops);
 *              patchTopics(...) / patchSessions(...); return { snap };
 *   onError:   restoreSnapshot(qc, ctx.snap);
 *   onSettled: invalidateOperations(qc, ops);
 */
import type { InfiniteData, QueryClient, QueryKey } from '@tanstack/react-query';

import type { SessionOut, SessionPage, TopicPage, TopicSummary } from '../client';
import type { OperationId } from './queryClient';

interface KeyMeta {
  _id: string;
  _infinite?: boolean;
  path?: Record<string, unknown>;
  query?: Record<string, unknown>;
}

export function keyMeta(key: QueryKey): KeyMeta | undefined {
  const first: unknown = key[0];
  if (typeof first === 'object' && first !== null && '_id' in first) {
    return typeof first._id === 'string' ? (first as KeyMeta) : undefined;
  }
  return undefined;
}

function predicateFor(ops: readonly OperationId[]) {
  return ({ queryKey }: { queryKey: QueryKey }) => {
    const id = keyMeta(queryKey)?._id;
    return id !== undefined && (ops as readonly string[]).includes(id);
  };
}

export type CacheSnapshot = readonly (readonly [QueryKey, unknown])[];

export function cancelOperations(qc: QueryClient, ops: readonly OperationId[]): Promise<void> {
  return qc.cancelQueries({ predicate: predicateFor(ops) });
}

export function snapshotOperations(qc: QueryClient, ops: readonly OperationId[]): CacheSnapshot {
  return qc.getQueriesData({ predicate: predicateFor(ops) });
}

export function restoreSnapshot(qc: QueryClient, snap: CacheSnapshot): void {
  for (const [key, data] of snap) qc.setQueryData(key, data);
}

function isInfinite<T>(data: unknown): data is InfiniteData<T> {
  return typeof data === 'object' && data !== null && 'pages' in data && Array.isArray(data.pages);
}

/** Apply `fn` to every page-shaped cache entry of `op` (plain or infinite). */
function mapPages<P extends { items: unknown[] }>(
  qc: QueryClient,
  op: OperationId,
  keyFilter: (meta: KeyMeta) => boolean,
  fn: (page: P, index: number) => P,
): void {
  qc.setQueriesData<P | InfiniteData<P>>(
    {
      predicate: ({ queryKey }) => {
        const m = keyMeta(queryKey);
        return m?._id === op && keyFilter(m);
      },
    },
    (data) => {
      if (data === undefined) return data;
      if (isInfinite<P>(data)) return { ...data, pages: data.pages.map(fn) };
      return fn(data as P, 0);
    },
  );
}

export type TopicMatch = (t: Pick<TopicSummary, 'id' | 'slug'>) => boolean;

export const topicIs =
  (ref: { id?: string; slug?: string }): TopicMatch =>
  (t) =>
    (ref.id !== undefined && t.id === ref.id) || (ref.slug !== undefined && t.slug === ref.slug);

/**
 * Patch a topic everywhere it is cached: `getTopic` and every `listTopics` page.
 * Return `null` from `patch` to drop it from lists (e.g. archived under the "active" filter).
 */
export function patchTopics(
  qc: QueryClient,
  match: TopicMatch,
  patch: (t: TopicSummary) => Partial<TopicSummary> | null,
): void {
  qc.setQueriesData<TopicSummary>(
    { predicate: ({ queryKey }) => keyMeta(queryKey)?._id === 'getTopic' },
    (t) => {
      if (!t || !match(t)) return t;
      const p = patch(t);
      return p ? { ...t, ...p } : t;
    },
  );
  mapPages<TopicPage>(
    qc,
    'listTopics',
    () => true,
    (page) => {
      let removed = 0;
      const items = page.items.flatMap((t) => {
        if (!match(t)) return [t];
        const p = patch(t);
        if (p === null) {
          removed++;
          return [];
        }
        return [{ ...t, ...p }];
      });
      return { ...page, items, total: page.total - removed };
    },
  );
}

/** Topic-scoped session lists are keyed by `path.ref` (slug in the UI, id in the outbox). */
export function sessionListIsFor(topic: { id: string; slug: string }) {
  return (m: KeyMeta) => {
    const ref = m.path?.ref;
    return ref === topic.id || ref === topic.slug;
  };
}

/** Patch / remove sessions in every `listSessions` page and `getSession` entry. */
export function patchSessions(
  qc: QueryClient,
  fn: (s: SessionOut) => SessionOut | null,
  keyFilter: (m: KeyMeta) => boolean = () => true,
): void {
  mapPages<SessionPage>(qc, 'listSessions', keyFilter, (page) => {
    let removed = 0;
    const items = page.items.flatMap((s) => {
      const next = fn(s);
      if (next === null) {
        removed++;
        return [];
      }
      return [next];
    });
    return { ...page, items, total: page.total - removed };
  });
  qc.setQueriesData<SessionOut>(
    { predicate: ({ queryKey }) => keyMeta(queryKey)?._id === 'getSession' },
    (s) => (s ? (fn(s) ?? s) : s),
  );
}

/** Put a freshly created session at the top of a topic's cached lists (no flicker). */
export function prependSession(
  qc: QueryClient,
  topic: { id: string; slug: string },
  session: SessionOut,
): void {
  mapPages<SessionPage>(qc, 'listSessions', sessionListIsFor(topic), (page, i) =>
    i === 0 && !page.items.some((s) => s.id === session.id)
      ? { ...page, items: [session, ...page.items], total: page.total + 1 }
      : page,
  );
}
