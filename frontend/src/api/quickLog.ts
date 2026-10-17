/**
 * One-tap logging from a topic tile: through the outbox (durable, works offline),
 * optimistic (counts, "Due now" update at once via the outbox effects) and with an Undo
 * toast instead of any confirmation.
 *
 * Undo works whether or not the entry has reached the server yet: the outbox item id is
 * the entry id, so a queued entry is simply discarded and a sent one is deleted by id.
 */
import { useQueryClient } from '@tanstack/react-query';
import { useCallback } from 'react';

import type { TopicSummary } from '../client';
import { getEntryQueryKey } from '../client/@tanstack/react-query.gen';
import { deleteEntry } from '../client/sdk.gen';
import { useToast } from '../components/ui/Toast';
import { toOffsetIso } from '../lib/dates';
import { outbox } from '../lib/outbox/client';
import { rememberedSource } from '../lib/storage';
import { UNDO_WINDOW_MS } from '../lib/undo';
import { uuid } from '../lib/uuid';
import { patchEntries } from './cache';
import { recordEntry } from './entries';
import { errorMessage } from './errors';
import { invalidateEntryData } from './queryClient';

type Topic = Pick<TopicSummary, 'id' | 'slug' | 'name' | 'current_version'>;

export interface QuickLogOptions {
  /** Human text of what was logged, e.g. "Mild" or "3 glasses". */
  label: string;
}

/** Undo a just-logged entry by its id (discard if still queued, else delete). */
export function useUndoLog() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useCallback(
    async (id: string, topic: Topic) => {
      // Still queued (offline / in flight): drop it — the outbox effects roll back counts.
      const discarded = await outbox.discard(id);
      if (discarded) {
        // It may have been mid-flight: make sure the server doesn't keep it. The delete
        // reserves the id even if the create hasn't arrived yet (204 either way), so a
        // late create gets 409 entry_deleted and is never stored.
        void deleteEntry({ path: { entry_id: id } }).catch(() => undefined);
      } else {
        try {
          await deleteEntry({ path: { entry_id: id }, throwOnError: true });
          patchEntries(qc, (e) => (e.id === id ? null : e));
          qc.removeQueries({ queryKey: getEntryQueryKey({ path: { entry_id: id } }) });
        } catch (err) {
          toast({
            title: 'Couldn’t undo',
            description: `${errorMessage(err)} — delete it from ${topic.name} › Entries.`,
            tone: 'danger',
          });
          return;
        }
      }
      void invalidateEntryData(qc);
      toast({ title: 'Undone', description: `${topic.name} entry removed.`, tone: 'info' });
    },
    [qc, toast],
  );
}

export function useQuickLog() {
  const { toast } = useToast();
  const undo = useUndoLog();
  return useCallback(
    async (topic: Topic, answers: Record<string, number | string>, { label }: QuickLogOptions) => {
      const id = uuid();
      const result = await recordEntry(
        { id: topic.id, slug: topic.slug, name: topic.name },
        {
          answers,
          captured_at: toOffsetIso(new Date()),
          source: rememberedSource(),
          version: topic.current_version,
        },
        // Don't hold the UI for the server: the tile already shows the result.
        { id, waitMs: 2_500 },
      );
      if (result.status === 'failed') {
        toast({
          title: `Couldn’t log ${topic.name}`,
          description: errorMessage(result.error),
          tone: 'danger',
        });
        return result;
      }
      toast({
        title: `Logged ${label}`,
        description:
          result.status === 'sent' ? topic.name : `${topic.name} · saved on this device, will sync`,
        tone: result.status === 'sent' ? 'ok' : 'info',
        duration: UNDO_WINDOW_MS,
        action: { label: 'Undo', onClick: () => void undo(id, topic) },
      });
      return result;
    },
    [toast, undo],
  );
}
