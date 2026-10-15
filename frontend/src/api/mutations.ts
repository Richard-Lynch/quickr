/**
 * Mutations with optimistic updates (TanStack onMutate → rollback on error → refetch on
 * settle). Pages use these instead of the raw generated `*Mutation()` options.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query';

import {
  archiveTopicMutation,
  getEntryQueryKey,
  getTopicQueryKey,
  unarchiveTopicMutation,
  updateEntryMutation,
  updateTopicMutation,
} from '../client/@tanstack/react-query.gen';
import { deleteEntry } from '../client/sdk.gen';
import type { EntryOut, EntryUpdate, TopicDetail, TopicSummary } from '../client';
import { useToast } from '../components/ui/Toast';
import type { ScheduleInput, ScheduleOutput } from '../lib/schedule';
import { scheduleUndoable, UNDO_WINDOW_MS } from '../lib/undo';
import {
  cancelOperations,
  patchEntries,
  patchTopics,
  restoreSnapshot,
  snapshotOperations,
  topicIs,
  type CacheSnapshot,
} from './cache';
import { errorMessage } from './errors';
import {
  invalidateOperations,
  invalidateEntryData,
  ENTRY_DATA_OPS,
  type OperationId,
} from './queryClient';

interface Ctx {
  snap: CacheSnapshot;
}

/** Best-effort local application of a EntryUpdate (the server response replaces it). */
export function applyEntryUpdate(s: EntryOut, body: EntryUpdate): EntryOut {
  let answers = s.answers;
  if (body.answers) {
    const patch = body.answers;
    answers = answers.flatMap((a) => {
      if (!(a.key in patch)) return [a];
      const v = patch[a.key];
      if (v === null || v === undefined) return [];
      return typeof v === typeof a.value ? [{ ...a, value: v } as typeof a] : [a];
    });
  }
  return {
    ...s,
    answers,
    ...(body.source != null ? { source: body.source } : {}),
    ...(body.captured_at != null ? { captured_at: body.captured_at } : {}),
    ...(body.notes != null ? { notes: body.notes } : {}),
  };
}

const ENTRY_OPS: readonly OperationId[] = ['listEntries', 'getEntry'];

export function useUpdateEntry() {
  const qc = useQueryClient();
  return useMutation({
    ...updateEntryMutation(),
    onMutate: async (vars): Promise<Ctx> => {
      await cancelOperations(qc, ENTRY_OPS);
      const snap = snapshotOperations(qc, ENTRY_OPS);
      patchEntries(qc, (s) => (s.id === vars.path.entry_id ? applyEntryUpdate(s, vars.body) : s));
      return { snap };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx) restoreSnapshot(qc, ctx.snap);
    },
    onSuccess: (updated) => {
      qc.setQueryData(getEntryQueryKey({ path: { entry_id: updated.id } }), updated);
      patchEntries(qc, (s) => (s.id === updated.id ? updated : s));
    },
    onSettled: () => invalidateEntryData(qc),
  });
}

/**
 * Delete with an Undo toast instead of a blocking confirm: the entry disappears from
 * every cached list at once, and the DELETE is only sent when the undo window closes
 * (or the app is hidden). Failure restores the caches and says so.
 */
export function useDeleteEntryWithUndo() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return (entry: EntryOut, topic: Pick<TopicSummary, 'id' | 'slug'>) => {
    void cancelOperations(qc, ENTRY_DATA_OPS);
    const snap = snapshotOperations(qc, [...ENTRY_DATA_OPS, 'getEntry']);
    patchEntries(qc, (s) => (s.id === entry.id ? null : s));
    patchTopics(qc, topicIs(topic), (t) => ({ entry_count: Math.max(0, t.entry_count - 1) }));

    const pending = scheduleUndoable(async () => {
      try {
        await deleteEntry({ path: { entry_id: entry.id }, throwOnError: true });
        qc.removeQueries({ queryKey: getEntryQueryKey({ path: { entry_id: entry.id } }) });
      } catch (err) {
        restoreSnapshot(qc, snap);
        toast({ title: 'Delete failed', description: errorMessage(err), tone: 'danger' });
      } finally {
        void invalidateEntryData(qc);
      }
    }, UNDO_WINDOW_MS);

    toast({
      title: 'Entry deleted',
      duration: UNDO_WINDOW_MS,
      action: {
        label: 'Undo',
        onClick: () => {
          if (pending.undo()) {
            restoreSnapshot(qc, snap);
            toast({ title: 'Entry restored', tone: 'info' });
          }
        },
      },
    });
  };
}

const TOPIC_OPS: readonly OperationId[] = ['getTopic', 'listTopics'];

function setTopicDetail(qc: ReturnType<typeof useQueryClient>, t: TopicDetail): void {
  qc.setQueryData(getTopicQueryKey({ path: { ref: t.slug } }), t);
}

/** Archive / unarchive with the status flipped immediately everywhere it's cached. */
export function useSetTopicArchived() {
  const qc = useQueryClient();
  const archive = useMutation(archiveTopicMutation());
  const unarchive = useMutation(unarchiveTopicMutation());
  const run = async (topic: TopicSummary, archived: boolean): Promise<TopicDetail> => {
    await cancelOperations(qc, TOPIC_OPS);
    const snap = snapshotOperations(qc, TOPIC_OPS);
    const now = new Date().toISOString();
    patchTopics(qc, topicIs(topic), () => ({
      status: archived ? 'archived' : 'active',
      archived_at: archived ? now : null,
    }));
    try {
      const vars = { path: { ref: topic.slug } };
      const t = archived ? await archive.mutateAsync(vars) : await unarchive.mutateAsync(vars);
      setTopicDetail(qc, t);
      return t;
    } catch (err) {
      restoreSnapshot(qc, snap);
      throw err;
    } finally {
      void invalidateOperations(qc, TOPIC_OPS);
    }
  };
  return { run, isPending: archive.isPending || unarchive.isPending };
}

/**
 * Schedule changes show immediately (the schedule text, the "Due now" section loses a
 * topic whose schedule was removed); the server's due status replaces ours on success.
 */
export function useUpdateTopicSchedule() {
  const qc = useQueryClient();
  return useMutation({
    ...updateTopicMutation(),
    onMutate: async (vars): Promise<Ctx> => {
      await cancelOperations(qc, TOPIC_OPS);
      const snap = snapshotOperations(qc, TOPIC_OPS);
      const { schedule } = vars.body;
      if (schedule !== undefined) {
        patchTopics(qc, topicIs({ slug: vars.path.ref, id: vars.path.ref }), (t) => ({
          schedule: schedule === null ? null : scheduleOutputOf(schedule),
          // A new/changed schedule is never due right away (see README "Schedules").
          due:
            schedule === null
              ? null
              : t.due
                ? { ...t.due, is_due: false, due_since: null }
                : { is_due: false, due_since: null, next_due_at: null, last_entry_at: null },
        }));
      }
      return { snap };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx) restoreSnapshot(qc, ctx.snap);
    },
    onSuccess: (updated) => {
      setTopicDetail(qc, updated);
      patchTopics(qc, topicIs(updated), () => ({
        schedule: updated.schedule,
        schedule_updated_at: updated.schedule_updated_at,
        due: updated.due,
      }));
    },
    onSettled: () => invalidateOperations(qc, TOPIC_OPS),
  });
}

/** Fill the defaults the server would (for the optimistic copy only). */
function scheduleOutputOf(s: ScheduleInput): ScheduleOutput {
  if ('every_minutes' in s) {
    return {
      kind: 'interval',
      every_minutes: s.every_minutes,
      timezone: s.timezone,
      notify: s.notify ?? true,
    };
  }
  return {
    kind: 'daily',
    times: [...s.times].sort(),
    days: [...(s.days ?? [1, 2, 3, 4, 5, 6, 7])].sort((a, b) => a - b),
    timezone: s.timezone,
    notify: s.notify ?? true,
  };
}

/**
 * Topic name/description edits show immediately. A slug change moves the cache key,
 * so it is not applied optimistically (the caller navigates to the new URL on success).
 */
export function useUpdateTopicMeta() {
  const qc = useQueryClient();
  return useMutation({
    ...updateTopicMutation(),
    onMutate: async (vars): Promise<Ctx> => {
      await cancelOperations(qc, TOPIC_OPS);
      const snap = snapshotOperations(qc, TOPIC_OPS);
      const { name, description } = vars.body;
      patchTopics(qc, topicIs({ slug: vars.path.ref, id: vars.path.ref }), () => ({
        ...(name != null ? { name } : {}),
        ...(description != null ? { description } : {}),
      }));
      return { snap };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx) restoreSnapshot(qc, ctx.snap);
    },
    onSuccess: (updated) => {
      setTopicDetail(qc, updated);
    },
    onSettled: () => invalidateOperations(qc, TOPIC_OPS),
  });
}
