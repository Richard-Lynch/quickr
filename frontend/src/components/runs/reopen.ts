/**
 * "Resume run" from the idle surfaces (active-surfaces.md §2.4, §3.3, §6.3; timers2.md §5.3):
 * the record page's Resume under Start, the idle tile's "Resume · {total}" and the stop
 * toast's Resume. They offer the topic's latest entry while M1's `resumableInView` says so
 * (an unedited timed entry within 15 minutes of its stop, the topic's latest stop, no locally
 * open run: OQ-1, A15), and send a `reopen` aimed at that entry's `timing.terminal_id`.
 */
import { useQueryClient } from '@tanstack/react-query';
import { useCallback } from 'react';

import { lastEntryOptions } from '../../api/entries';
import type { EntryOut, TopicVersionOut } from '../../client';
import type { EntryRef, RunContext } from '../../lib/runs/actions';
import { timingFromWire, timingToWire } from '../../lib/runs/fold';
import { parseInstant } from '../../lib/runs/instant';
import { optimisticEntries, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import { contextFor } from './context';
import { resumableInView } from './model';
import { useServerNow } from './RunClock';
import { useRunActions, type RunActions } from './useRunActions';

type TopicRef = RunContext['topic'];

/** The Resume a surface shows: the entry's active time, and the tap that reopens it. */
export interface ReopenOffer {
  /** The topic's name, for the accessible name (§1.3). */
  topic: string;
  totalMs: number;
  onReopen: () => void;
}

/** An entry the offer can be made from: the server's, or a queued stop's optimistic one. */
type Candidate = Pick<EntryOut, 'id' | 'topic_id' | 'version' | 'timing'> & {
  /** The server's revision; null for an optimistic entry (its run is in the local view). */
  revision: number | null;
};

/**
 * The topic's candidates: the server's latest entry (`lastEntryOptions`) and the optimistic
 * entries of its queued stops (§8.3), the run row of which is still local.
 */
function candidatesOf(
  topicId: string,
  served: EntryOut | undefined,
  runs: readonly LocalRun[],
): Candidate[] {
  const out: Candidate[] = served ? [served] : [];
  const topic = topicId.toLowerCase();
  for (const e of optimisticEntries(runs)) {
    if (e.topic_id.toLowerCase() !== topic) continue;
    if (out.some((c) => c.id.toLowerCase() === e.id.toLowerCase())) continue;
    const wire = timingToWire(e.timing);
    out.push({
      id: e.id,
      topic_id: e.topic_id,
      version: e.version,
      timing: { ...wire, skipped: [...wire.skipped] },
      revision: null,
    });
  }
  return out;
}

/** The candidate whose stop is the latest (ties broken by id, as `resumableInView` does). */
function latestOf(candidates: readonly Candidate[]): Candidate | undefined {
  let best: Candidate | undefined;
  let bestEnd = -Infinity;
  for (const c of candidates) {
    if (!c.timing) continue;
    const end = parseInstant(c.timing.ended_at);
    if (end > bestEnd || (end === bestEnd && best && c.id.toLowerCase() > best.id.toLowerCase())) {
      best = c;
      bestEnd = end;
    }
  }
  return best;
}

/** The entry a reopen is sent from, when no run row is local (timers2.md §5.3). */
function entryRefOf(c: Pick<Candidate, 'id' | 'timing' | 'revision'>): EntryRef | undefined {
  if (!c.timing || c.revision === null) return undefined;
  return { id: c.id, timing: timingFromWire(c.timing), revision: c.revision };
}

/**
 * Send the `reopen` of `entry`'s run: on the run row when it is still local (its
 * `terminal_id` is the entry's), otherwise from the entry, whose `timing.terminal_id` the
 * tap aims at. Nothing is sent while the topic has another open run (`tapRun`, A15).
 */
function sendReopen(
  taps: RunActions,
  ctx: RunContext,
  entry: Pick<Candidate, 'id' | 'timing' | 'revision'>,
): void {
  const ref = entryRefOf(entry);
  void taps.tap(entry.id, ctx, 'reopen', {}, undefined, ref ? { entry: ref } : {});
}

/**
 * The Resume offer of `topic`'s latest entry, or null when there is none (§2.4, §3.3, §6.3).
 * `served` is the server's latest entry of the topic; `enabled` false (not idle, archived)
 * offers nothing. It ticks while an offer is up, so it goes when the window ends.
 */
export function useReopenOffer(
  topic: TopicRef,
  versions: readonly TopicVersionOut[] | undefined,
  served: EntryOut | undefined,
  enabled: boolean,
): ReopenOffer | null {
  const { runs } = useRuns();
  const taps = useRunActions();
  const candidates = enabled ? candidatesOf(topic.id, served, runs) : [];
  const latest = latestOf(candidates);
  const now = useServerNow(latest !== undefined);
  if (!latest?.timing || !resumableInView(latest, candidates, runs, now)) return null;
  const ctx = contextFor(topic, versions, latest.version);
  if (!ctx) return null;
  return {
    topic: topic.name,
    totalMs: latest.timing.active_ms,
    onReopen: () => sendReopen(taps, ctx, latest),
  };
}

/**
 * The stop toast's Resume (§3.2, §6.3): the reopen of the run Stop just ended, for as long as
 * the toast is up (`REOPEN_WINDOW_MS`). The run row is local right after the stop; once it
 * has gone, the server's entry of the run (from the query cache) is the target's source.
 */
export function useReopenAfterStop(): (
  topic: Pick<TopicRef, 'slug'>,
  run: Pick<LocalRun, 'id'>,
  ctx: RunContext,
) => () => void {
  const qc = useQueryClient();
  const taps = useRunActions();
  return useCallback(
    (topic, run, ctx) => () => {
      const served = qc
        .getQueryData(lastEntryOptions(topic.slug).queryKey)
        ?.items.find((e) => e.id.toLowerCase() === run.id.toLowerCase());
      sendReopen(taps, ctx, served ?? { id: run.id, timing: null, revision: null });
    },
    [qc, taps],
  );
}
