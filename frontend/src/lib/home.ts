/** The home screen's sections (`TopicsPage`, sorted by due). */
import type { TopicSummary } from '../client';
import { isDueNow } from './schedule';

export interface Sections<T> {
  due: T[];
  upcoming: T[];
  other: T[];
}

/** What {@link splitByDue} reads of a topic. */
export type SplittableTopic = Pick<TopicSummary, 'id' | 'status' | 'schedule' | 'due'>;

/** What {@link dueCount} reads of a topic. */
export type CountableTopic = Pick<TopicSummary, 'id' | 'status' | 'due'>;

/**
 * Ids of the topics with an open run (running or paused). A finishing run isn't open: its
 * topic keeps its due state (timers.md §11.1).
 */
export type OpenRunTopics = ReadonlySet<string>;

/** For callers that have no run data yet. */
export const NO_OPEN_RUNS: OpenRunTopics = new Set();

/**
 * Whether a topic counts as due: active, due now, and without an open run (a timed topic
 * with an open run shows "Running" instead of its due state, timers.md §11.1).
 */
export function countsAsDue(t: CountableTopic, now: Date, openRuns: OpenRunTopics): boolean {
  return t.status === 'active' && !openRuns.has(t.id) && isDueNow(t.due, now);
}

/**
 * The number of due topics: the one count behind the home screen's "Due now" and the app
 * icon badge (`api/dueBadge.ts`), timers.md §11.1.
 */
export function dueCount(
  topics: readonly CountableTopic[],
  now: Date,
  openRuns: OpenRunTopics,
): number {
  return topics.filter((t) => countsAsDue(t, now, openRuns)).length;
}

/**
 * Split a due-sorted list into "Due now" ({@link countsAsDue}), "Coming up" (active and
 * scheduled) and the rest, keeping the server's order within "Due now" and the rest
 * (longest overdue first). "Coming up" is re-sorted by `next_due_at` (soonest first, none
 * last; stable).
 *
 * `shared/fixtures/home-due-vectors.json` pins this for the iOS port.
 */
export function splitByDue<T extends SplittableTopic>(
  items: readonly T[],
  now: Date,
  openRuns: OpenRunTopics,
): Sections<T> {
  const out: Sections<T> = { due: [], upcoming: [], other: [] };
  for (const t of items) {
    if (countsAsDue(t, now, openRuns)) out.due.push(t);
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
