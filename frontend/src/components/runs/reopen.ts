/**
 * "Resume run" from the idle surfaces (active-surfaces.md §2.4, §3.3, §6.3; timers2.md §5.3):
 * the record page's Resume under Start, the idle tile's "Resume · {total}" and the stop
 * toast's Resume. They offer the topic's latest entry while M1's `resumableInView` says so
 * (an unedited timed entry within 15 minutes of its stop, the topic's latest stop, no locally
 * open run: OQ-1, A15), and send a `reopen` aimed at that entry's `timing.terminal_id`.
 */
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { useCallback } from 'react';

import { lastEntryOptions } from '../../api/entries';
import type { EntryOut, TopicVersionOut } from '../../client';
import { getEntryOptions } from '../../client/@tanstack/react-query.gen';
import { outbox } from '../../lib/outbox/client';
import { isRunEvent } from '../../lib/outbox/kinds';
import type { EntryRef, RunContext } from '../../lib/runs/actions';
import { projectTiming, timingFromWire, timingToWire } from '../../lib/runs/fold';
import { parseInstant } from '../../lib/runs/instant';
import { optimisticEntries, runById, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import { contextFor } from './context';
import { resumableInView } from './model';
import { useServerNow } from './RunClock';
import { useToast } from '../ui/Toast';
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
 * The topic's candidates: the optimistic entries of its queued stops (§8.3), the run row of
 * which is still local, and the server's latest entry (`lastEntryOptions`) unless a queued
 * stop of the same run supersedes it (a re-stop after a reopen: its time is newer).
 */
function candidatesOf(
  topicId: string,
  served: EntryOut | undefined,
  runs: readonly LocalRun[],
): Candidate[] {
  const out: Candidate[] = [];
  const topic = topicId.toLowerCase();
  for (const e of optimisticEntries(runs)) {
    if (e.topic_id.toLowerCase() !== topic) continue;
    const wire = timingToWire(e.timing);
    out.push({
      id: e.id,
      topic_id: e.topic_id,
      version: e.version,
      timing: { ...wire, skipped: [...wire.skipped] },
      revision: null,
    });
  }
  if (served && !out.some((c) => c.id.toLowerCase() === served.id.toLowerCase()))
    out.push(withLocalStop(served, runs));
  return out;
}

/**
 * The server's entry, with its timing as the local view has it when the run was stopped again
 * here since (a re-stop after a reopen updates the entry, so it makes no optimistic one): the
 * newer stop's time and total, its `terminal_id`; the server's `edited` and revision stay.
 */
function withLocalStop(served: EntryOut, runs: readonly LocalRun[]): Candidate {
  const t = served.timing;
  const run = runById(runs, served.id);
  if (!t || run?.status !== 'stopped' || run.state.ended_at === null) return served;
  if (run.state.ended_at <= parseInstant(t.ended_at)) return served;
  const wire = timingToWire(projectTiming(run.state, { steps: run.steps ?? [] }));
  return { ...served, timing: { ...wire, skipped: [...wire.skipped], edited: t.edited } };
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
): Promise<unknown> {
  const ref = entryRefOf(entry);
  return taps.tap(entry.id, ctx, 'reopen', {}, undefined, ref ? { entry: ref } : {});
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
    onReopen: () => void sendReopen(taps, ctx, latest),
  };
}

/** The server's entry of the run: the latest-entry cache, else `getEntry`; none offline or yet. */
async function entryOfRun(
  qc: QueryClient,
  slug: string,
  runId: string,
): Promise<EntryOut | undefined> {
  const id = runId.toLowerCase();
  const cached = qc
    .getQueryData(lastEntryOptions(slug).queryKey)
    ?.items.find((e) => e.id.toLowerCase() === id);
  if (cached) return cached;
  try {
    return await qc.query({
      ...getEntryOptions({ path: { entry_id: id } }),
      staleTime: 0,
      retry: false,
    });
  } catch {
    return undefined;
  }
}

/** Whether a stop of the run other than `stopId` is queued here (a re-stop since). */
async function restoppedHere(runId: string, stopId: string): Promise<boolean> {
  const run = runId.toLowerCase();
  return (await outbox.list()).some(
    (i) =>
      isRunEvent(i) &&
      i.status === 'pending' &&
      i.payload.event.type === 'stop' &&
      i.id.toLowerCase() !== stopId &&
      [i.payload.run_id, ...(i.payload.run_aliases ?? [])].some((id) => id.toLowerCase() === run),
  );
}

/**
 * The stop toast's Resume (§3.2, §6.3): the reopen of the stop `stopId` just made, for as long
 * as the toast is up (`REOPEN_WINDOW_MS`). At the tap it is checked again: the run's entry
 * (cached, or fetched), when there is one, must still end with that stop, unedited, and no
 * later stop of the run may be queued here; without an entry (the stop is still queued) the
 * run row is local. Otherwise, or when `tapRun` refuses (another open run, A15), the toast
 * says it can't.
 */
export function useReopenAfterStop(): (
  topic: Pick<TopicRef, 'slug'>,
  run: Pick<LocalRun, 'id'>,
  stopId: string,
  ctx: RunContext,
) => () => void {
  const qc = useQueryClient();
  const taps = useRunActions();
  const { toast } = useToast();
  return useCallback(
    (topic, run, stopId, ctx) => () => {
      const stop = stopId.toLowerCase();
      void (async () => {
        const entry = await entryOfRun(qc, topic.slug, run.id);
        const t = entry?.timing;
        // The entry, when there is one, still ends with this stop, unedited; and no later
        // stop of the run is queued here (its run row would aim the reopen at that one).
        const current = t ? !t.edited && t.terminal_id?.toLowerCase() === stop : true;
        let sent: unknown = null;
        if (current && !(await restoppedHere(run.id, stop)))
          sent = entry ? await sendReopen(taps, ctx, entry) : await taps.tap(run.id, ctx, 'reopen');
        if (sent === null) toast({ title: 'That run can’t be resumed now', tone: 'info' });
      })();
    },
    [qc, taps, toast],
  );
}
