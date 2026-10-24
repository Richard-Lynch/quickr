/**
 * The open-runs hook (timers.md §7.3, §8.3): the server's runs, polled by the PWA's rules,
 * with this device's queued taps folded over them.
 *
 * `listRuns(status=open|finishing)` is read on load and on focus, every 10 s while any run
 * is open or a timed topic's page is visible, and after each of this device's own events
 * (the response patches the cache, `api/outboxEffects.ts`).
 */
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo } from 'react';

import { runTapDeps } from '../../api/runs';
import type { RunOut } from '../../client';
import { listRunsOptions } from '../../client/@tanstack/react-query.gen';
import type { OutboxItem } from '../outbox/types';
import { useOutbox } from '../outbox/useOutbox';
import type { RunTapDeps } from './actions';
import { isOpen, localRuns, openRunTopics, type LocalRun } from './localView';

export const RUNS_POLL_MS = 10_000;

const NO_RUNS: readonly RunOut[] = [];

export interface UseRuns {
  /** The local view: every open, finishing and just-closed run this device knows. */
  runs: readonly LocalRun[];
  /** Topics with an open run, for `dueCount` and `splitByDue`. */
  openTopics: ReadonlySet<string>;
  /** The server's answer has arrived at least once (or came from the persisted cache). */
  loaded: boolean;
  /** For `startRun` and `tapRun`. */
  deps: RunTapDeps;
}

/**
 * §7.3: poll every 10 s while any run of the local view is open (a queued start counts) or
 * a timed topic's page is visible; otherwise only on load, focus and this device's events.
 */
export function runsPollInterval(
  serverRuns: readonly RunOut[],
  items: readonly OutboxItem[],
  timedPageVisible: boolean,
): number | false {
  return timedPageVisible || localRuns(serverRuns, items).some(isOpen) ? RUNS_POLL_MS : false;
}

/**
 * The local run view. `timedPageVisible`: a timed topic's page is on screen, which polls
 * even with no run open (another device may start one).
 */
export function useRuns(opts: { timedPageVisible?: boolean } = {}): UseRuns {
  const qc = useQueryClient();
  const { items } = useOutbox();
  const timedPageVisible = opts.timedPageVisible === true;
  const query = useQuery({
    ...listRunsOptions(),
    refetchOnWindowFocus: 'always',
    // Re-evaluated after each fetch and on every render (new `items`).
    refetchInterval: (q) => runsPollInterval(q.state.data ?? NO_RUNS, items, timedPageVisible),
  });
  const serverRuns = query.data ?? NO_RUNS;
  const runs = useMemo(() => localRuns(serverRuns, items), [serverRuns, items]);
  const openTopics = useMemo(() => openRunTopics(runs), [runs]);
  const deps = useMemo(() => runTapDeps(qc), [qc]);
  return { runs, openTopics, loaded: query.data !== undefined, deps };
}
