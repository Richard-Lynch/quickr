/**
 * Which topics' run controls are on screen now, outside the running bar: the bar leaves those
 * topics' runs out, so no primary shows twice (active-surfaces.md §6.3, the user's "no
 * duplicated controls"). A surface that renders an open run's primary registers its topic while
 * it is mounted; the topics page's "Active now" cards do (§6.2). The run panel is left out by
 * the bar's own route check (`RunningBar`).
 *
 * A running topic the topics page doesn't list (a search, a status filter, a later page) has no
 * card, so it keeps its bar row.
 */
import { useLayoutEffect, useSyncExternalStore } from 'react';

/** How many mounted surfaces show each topic's controls, by lowercase topic id. */
const counts = new Map<string, number>();
let shown: ReadonlySet<string> = new Set();
const listeners = new Set<() => void>();

const publish = () => {
  shown = new Set(counts.keys());
  for (const l of listeners) l();
};

const subscribe = (onChange: () => void) => {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
};

/**
 * Marks `topicId`'s run controls as on screen while the caller is mounted (null: none). A
 * layout effect, so the bar drops its row before the page paints with both.
 */
export function useRunControlsOnScreen(topicId: string | null): void {
  useLayoutEffect(() => {
    if (topicId === null) return;
    const key = topicId.toLowerCase();
    counts.set(key, (counts.get(key) ?? 0) + 1);
    publish();
    return () => {
      const n = (counts.get(key) ?? 1) - 1;
      if (n > 0) counts.set(key, n);
      else counts.delete(key);
      publish();
    };
  }, [topicId]);
}

/** The topics (lowercase ids) whose run controls are on screen outside the bar. */
export function useTopicsWithControlsOnScreen(): ReadonlySet<string> {
  return useSyncExternalStore(subscribe, () => shown);
}
