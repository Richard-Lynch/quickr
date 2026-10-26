import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';

import { mapApiError } from '../../api/errors';
import { useUpdateEntry } from '../../api/mutations';
import type { EntryOut, Step, Timing, TimingEdit } from '../../client';
import { getEntryOptions, getEntryQueryKey } from '../../client/@tanstack/react-query.gen';
import { formatDateTime } from '../../lib/dates';
import { fmtDuration } from '../../lib/runs/format';
import { Button } from '../ui/Button';
import { Badge, Card } from '../ui/Card';
import { Icon } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';
import { useToast } from '../ui/Toast';
import { TimingEditor } from './TimingEditor';
import { timingFieldOf, type FieldErrors } from './timingEdit';

interface Props {
  entry: EntryOut & { timing: Timing };
  /** The run's version's steps (labels for skipped steps, and the editor's choices). */
  steps: readonly Step[];
}

/**
 * A timed entry's times on its edit page (timers.md §11.1, §11.5): start, end, total and
 * paused time, each segment, the skipped steps, and Edit times. The edit is a PATCH with
 * `timing` and `expected_revision`, online like every other PWA entry edit (`useUpdateEntry`);
 * the server's 422 field errors show on the fields they name.
 *
 * The form edits the times as they were when it opened, and saves against that revision. If
 * the entry has changed since (a 409 `stale_revision`, or a newer revision fetched while the
 * form is open), saving stops until the user reloads the times: a draft is never re-based
 * silently, nor saved against a revision it wasn't made from.
 */
export function TimingSection({ entry, steps }: Props) {
  const timing = entry.timing;
  const update = useUpdateEntry();
  const qc = useQueryClient();
  const { toast } = useToast();
  /** What the open form edits: the times and the revision they came from. */
  const [opened, setOpened] = useState<{ revision: number; timing: Timing; at: number } | null>(
    null,
  );
  const [conflict, setConflict] = useState(false);
  const [reloading, setReloading] = useState(false);
  const editing = opened !== null;
  const stale = opened !== null && (conflict || entry.revision !== opened.revision);
  const [server, setServer] = useState<{ errors: FieldErrors; message: string | null }>({
    errors: {},
    message: null,
  });
  const label = (key: string) => steps.find((s) => s.key === key)?.label ?? key;

  const open = (revision: number, times: Timing) => {
    setServer({ errors: {}, message: null });
    setConflict(false);
    // `at` remounts the form (a fresh draft) on every open and reload.
    setOpened((o) => ({ revision, timing: times, at: (o?.at ?? 0) + 1 }));
  };

  const reload = async () => {
    setReloading(true);
    try {
      const fresh = await qc.query({
        ...getEntryOptions({ path: { entry_id: entry.id } }),
        staleTime: 0,
      });
      if (fresh.timing) open(fresh.revision, fresh.timing);
    } catch (err) {
      setServer({ errors: {}, message: mapApiError(err).message });
    } finally {
      setReloading(false);
    }
  };

  const save = async (edit: TimingEdit) => {
    if (!opened) return;
    try {
      await update.mutateAsync({
        path: { entry_id: entry.id },
        body: { timing: edit, expected_revision: opened.revision },
      });
      setOpened(null);
      setServer({ errors: {}, message: null });
      toast({ title: 'Times updated' });
    } catch (err) {
      const mapped = mapApiError(err);
      if (mapped.code === 'stale_revision') {
        setConflict(true);
        setServer({ errors: {}, message: null });
        void qc.invalidateQueries({ queryKey: getEntryQueryKey({ path: { entry_id: entry.id } }) });
        return;
      }
      const errors: FieldErrors = {};
      for (const fe of mapped.fieldErrors) {
        const path = timingFieldOf(fe.path);
        if (path !== null) errors[path] ??= fe.message;
      }
      setServer({ errors, message: mapped.message });
    }
  };

  return (
    <Card className="flex flex-col gap-4 p-4 sm:p-5" role="region" aria-label="Timing">
      <header className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-lg leading-tight font-semibold">Timing</h2>
          <p className="mt-0.5 text-sm text-muted">
            {formatDateTime(timing.started_at)} → {formatDateTime(timing.ended_at)}
          </p>
        </div>
        {timing.edited ? <Badge tone="info">edited</Badge> : null}
        {timing.complete ? null : <Badge tone="warn">incomplete</Badge>}
      </header>
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-4xl leading-none font-bold tabular" data-testid="run-total">
          {fmtDuration(timing.active_ms)}
        </span>
        {timing.paused_ms > 0 ? (
          <span className="text-sm text-muted">{fmtDuration(timing.paused_ms)} paused</span>
        ) : null}
      </div>
      <ol className="flex flex-col divide-y divide-dashed divide-line" aria-label="Segments">
        {timing.segments.map((s, i) => (
          <li key={`${String(i)}-${s.started_at}`} className="flex items-baseline gap-3 py-1.5">
            <span className="w-5 shrink-0 font-mono text-xs text-muted">{i + 1}</span>
            <span className={s.kind === 'lap' ? 'flex-1 text-ink-soft italic' : 'flex-1'}>
              {s.kind === 'step' && s.step ? label(s.step) : s.label}
            </span>
            {s.paused_ms > 0 ? (
              <span className="text-xs text-muted">{fmtDuration(s.paused_ms)} paused</span>
            ) : null}
            <span className="font-mono text-sm font-semibold tabular">
              {fmtDuration(s.active_ms)}
            </span>
          </li>
        ))}
      </ol>
      {timing.skipped.length > 0 ? (
        <p className="text-sm text-muted">Skipped: {timing.skipped.map(label).join(', ')}</p>
      ) : null}
      <Button
        className="self-start"
        icon={<Icon name="clock" />}
        onClick={() => open(entry.revision, timing)}
      >
        Edit times
      </Button>
      <Sheet
        open={editing}
        onClose={() => setOpened(null)}
        wide
        title="Edit times"
        description="The run’s end is the entry’s time. Later taps on this run are ignored once you save."
      >
        {opened ? (
          <TimingEditor
            key={opened.at}
            timing={opened.timing}
            steps={steps}
            serverErrors={server.errors}
            serverMessage={server.message}
            saving={update.isPending}
            stale={stale ? { onReload: () => void reload(), reloading } : null}
            onSave={(edit) => void save(edit)}
            onCancel={() => setOpened(null)}
          />
        ) : null}
      </Sheet>
    </Card>
  );
}
