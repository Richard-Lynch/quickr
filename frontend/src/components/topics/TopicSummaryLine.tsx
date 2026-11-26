import type { ReactNode } from 'react';

import type { EntryOut, Timer } from '../../client';
import { entrySummary } from '../../lib/entrySummary';
import type { Question } from '../../lib/questions';

/**
 * The idle tile's second line (content-display.md §5): the topic's last entry as its summary
 * line (§1), one line, tail-truncated. No entry, or nothing to say (`''`), shows `fallback`
 * instead ("4 entries · 4 days ago" from the tile), so an empty line never renders.
 * `questions` null (the `getTopic` prefetch not in yet) renders the timing part only.
 */
export function TopicSummaryLine({
  entry,
  questions,
  timer,
  fallback,
}: {
  entry: EntryOut | null;
  /** The entry's version's questions; null while they load. */
  questions: readonly Question[] | null;
  /** The topic's current timer (lap-type labels); null for an untimed topic. */
  timer: Timer | null;
  fallback: ReactNode;
}) {
  const summary = entry ? entrySummary(entry.answers, entry.timing, questions ?? [], timer) : '';
  if (!summary) return <>{fallback}</>;
  // `block min-w-0 max-w-full` so the ellipsis applies inside the tile's wrapping flex row.
  return (
    <span
      className="block max-w-full min-w-0 truncate text-ink-soft"
      data-testid="topic-summary"
      title={summary}
    >
      {summary}
    </span>
  );
}
