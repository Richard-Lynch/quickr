/** The home screen's sections (`TopicsPage`, sorted by due). */
import type { TopicSummary } from '../client';
import { isDueNow } from './schedule';

export interface Sections<T> {
  due: T[];
  upcoming: T[];
  other: T[];
}

/** What {@link splitByDue} reads of a topic. */
export type SplittableTopic = Pick<TopicSummary, 'status' | 'schedule' | 'due'>;

/**
 * Split a due-sorted list into "Due now", "Coming up" (active and scheduled) and the
 * rest, keeping the server's order within "Due now" and the rest (longest overdue
 * first). "Coming up" is re-sorted by `next_due_at` (soonest first, none last; stable).
 *
 * `shared/fixtures/home-due-vectors.json` pins this for the iOS port.
 */
export function splitByDue<T extends SplittableTopic>(items: readonly T[], now: Date): Sections<T> {
  const out: Sections<T> = { due: [], upcoming: [], other: [] };
  for (const t of items) {
    if (t.status === 'active' && isDueNow(t.due, now)) out.due.push(t);
    else if (t.status === 'active' && t.schedule) out.upcoming.push(t);
    else out.other.push(t);
  }
  out.upcoming.sort(
    (a, b) =>
      Date.parse(a.due?.next_due_at ?? '9999-12-31') -
      Date.parse(b.due?.next_due_at ?? '9999-12-31'),
  );
  return out;
}
