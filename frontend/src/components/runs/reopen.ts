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
import { runTapDeps, TAP_REFRESH_TIMEOUT_MS } from '../../api/runs';
import type { EntryOut, TopicVersionOut } from '../../client';
import { isOnline } from '../../lib/outbox/client';
import { isRunEvent } from '../../lib/outbox/kinds';
import type { EntryRef, RunContext } from '../../lib/runs/actions';
import { projectTiming, timingFromWire, timingToWire } from '../../lib/runs/fold';
import { serverNow } from '../../lib/runs/clock';
import { parseInstant } from '../../lib/runs/instant';
import { serverOffset } from '../../lib/runs/serverClock';
import { localRuns, optimisticEntries, runById, type LocalRun } from '../../lib/runs/localView';
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

/**
 * Refresh the topic's latest entry (`lastEntryOptions`) for a tap: the cached one may predate
 * a re-stop, an edit or a later run, here or elsewhere. Bounded like `tapRun`'s refresh
 * (`TAP_REFRESH_TIMEOUT_MS`); offline, failed or slow, the cache stays as it was.
 */
function refreshLatestEntry(qc: QueryClient, slug: string): Promise<void> {
  if (!isOnline()) return Promise.resolve();
  const fetched = qc
    .query({ ...lastEntryOptions(slug), staleTime: 0, retry: false, networkMode: 'always' })
    .then(
      () => undefined,
      () => undefined,
    );
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, TAP_REFRESH_TIMEOUT_MS);
  });
  return Promise.race([fetched, timeout]).finally(() => {
    clearTimeout(timer);
  });
}

/**
 * The local view at the tap (as `tapRun` builds it: the cached server runs, the outbox, the
 * acked items), and the ids (lowercase) of the run's stops queued here, not yet sent. A
 * toast's callback outlives the component that made it, so the view is read now.
 */
async function viewAtTap(
  qc: QueryClient,
  runId: string,
): Promise<{ runs: LocalRun[]; stops: string[] }> {
  const deps = runTapDeps(qc);
  const items = await deps.outbox.list();
  const runs = localRuns(deps.serverRuns(), items, (await deps.acked?.()) ?? []);
  const run = runId.toLowerCase();
  const stops = items
    .filter(
      (i) =>
        isRunEvent(i) &&
        i.status === 'pending' &&
        i.payload.event.type === 'stop' &&
        [i.payload.run_id, ...(i.payload.run_aliases ?? [])].some((id) => id.toLowerCase() === run),
    )
    .map((i) => i.id.toLowerCase());
  return { runs, stops };
}

/**
 * Send the reopen of the stop `stopId` of `run`, or nothing (null) when it is no longer that
 * stop's to make, as the view is at the tap: another stop of the run is queued here (a
 * re-stop since), or the run row ends otherwise; the stop sent, the topic's latest entry
 * (refreshed first) isn't the run's ending with that stop (§6.3 keys Resume on the last entry);
 * or `resumableInView` says no (edited, past the window, a later stop of the topic, an open
 * run: OQ-1, A15).
 */
async function reopenStop(
  qc: QueryClient,
  taps: RunActions,
  slug: string,
  runId: string,
  stopId: string,
  ctx: RunContext,
): Promise<unknown> {
  // Sent, the server's entry is refreshed first; the view is read after that wait.
  if (!(await viewAtTap(qc, runId)).stops.includes(stopId)) await refreshLatestEntry(qc, slug);
  const { runs, stops } = await viewAtTap(qc, runId);
  if (stops.some((id) => id !== stopId)) return null;
  const row = runById(runs, runId);
  // The run row, while it is in the view, ends with that stop (not a later one, nor open).
  if (row && row.state.terminal_id?.toLowerCase() !== stopId) return null;
  const queued = row !== undefined && stops.includes(stopId);
  const optimistic = candidatesOf(ctx.topic.id, undefined, runs);
  const latest = qc.getQueryData(lastEntryOptions(slug).queryKey)?.items[0];
  const ours = latest?.id.toLowerCase() === runId.toLowerCase() ? latest : undefined;
  // Queued, its entry is the optimistic one, or (a re-stop of a reopened run, which updates
  // its entry) the server's with the row's stop. Sent, the topic's latest entry is the run's.
  const entry: Candidate | undefined = queued
    ? (optimistic.find((c) => c.id.toLowerCase() === runId.toLowerCase()) ??
      (ours ? withLocalStop(ours, runs) : undefined))
    : ours;
  if (entry?.timing?.terminal_id?.toLowerCase() !== stopId) return null;
  const now = serverNow(Date.now(), serverOffset());
  if (!resumableInView(entry, [...optimistic, ...(latest ? [latest] : [])], runs, now)) return null;
  return sendReopen(taps, ctx, entry);
}

/**
 * The stop toast's Resume (§3.2, §6.3): the reopen of the stop `stopId` just made, for as long
 * as the toast is up (`REOPEN_WINDOW_MS`), checked again at the tap (`reopenStop`). When it
 * can't be (or `tapRun` refuses), the toast says so.
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
      void reopenStop(qc, taps, topic.slug, run.id, stop, ctx).then((sent) => {
        if (sent === null) toast({ title: 'That run can’t be resumed now', tone: 'info' });
      });
    },
    [qc, taps, toast],
  );
}
