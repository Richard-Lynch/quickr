/**
 * Keep the app icon badge equal to the number of due topics.
 *
 * Fed from the query cache: whenever an unfiltered topic list (`listTopics` without a
 * search, active topics) changes — fetched, refetched, patched optimistically after a
 * log — the due count is recomputed and pushed to the Badging API. 0 clears the badge.
 * Topics with an open run don't count (timers.md §11.1), so the cached runs and the
 * outbox (a queued start opens a run at once) recompute it too.
 */
import type { InfiniteData, Query, QueryClient } from '@tanstack/react-query';

import type { TopicPage, TopicSummary } from '../client';
import { setAppBadge } from '../lib/badge';
import { dueCount } from '../lib/home';
import { subscribeOutboxSnapshot } from '../lib/outbox/client';
import { keyMeta } from './cache';
import { openRunTopicsNow } from './runs';

function topicsOf(data: unknown): TopicSummary[] | null {
  if (typeof data !== 'object' || data === null) return null;
  if ('pages' in data) return (data as InfiniteData<TopicPage>).pages.flatMap((p) => p.items);
  if ('items' in data) return (data as TopicPage).items;
  return null;
}

export function connectDueBadge(qc: QueryClient): () => void {
  let last: number | null = null;
  const update = () => {
    // Union of every unfiltered list in the cache, de-duplicated by id.
    const byId = new Map<string, TopicSummary>();
    for (const q of qc.getQueryCache().findAll()) {
      const m = keyMeta(q.queryKey);
      if (m?._id !== 'listTopics') continue;
      const query = m.query ?? {};
      if (query.q || (query.status && query.status !== 'active') || query.due_only) continue;
      for (const t of topicsOf(q.state.data) ?? []) byId.set(t.id, t);
    }
    if (byId.size === 0 && last === null) return;
    const n = dueCount([...byId.values()], new Date(), openRunTopicsNow(qc));
    if (n === last) return;
    last = n;
    void setAppBadge(n);
  };
  const unsubscribe = qc.getQueryCache().subscribe((e) => {
    if (e.type === 'updated' || e.type === 'added' || e.type === 'removed') {
      const { queryKey } = e.query as Query;
      const op = keyMeta(queryKey)?._id;
      if (op === 'listTopics' || op === 'listRuns') update();
    }
  });
  const unsubscribeOutbox = subscribeOutboxSnapshot(update);
  // Slots fall due while the app is open, without any data change.
  const timer = window.setInterval(update, 60_000);
  update();
  return () => {
    unsubscribe();
    unsubscribeOutbox();
    window.clearInterval(timer);
  };
}
