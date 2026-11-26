import { useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router';

import { mapApiError } from '../../api/errors';
import { useUpdateEntry } from '../../api/mutations';
import type { EntryOut, StepInput as Step, Timing, TimingEdit } from '../../client';
import { getEntryOptions, getEntryQueryKey } from '../../client/@tanstack/react-query.gen';
import { formatDateTime } from '../../lib/dates';
import {
  removeControl,
  resumableFromDetail,
  spokenDuration,
  timingRows,
  type TimingRow,
} from '../../lib/entryTiming';
import { kickOutbox } from '../../lib/outbox/client';
import { useOutbox } from '../../lib/outbox/useOutbox';
import { tapRun, type EntryRef, type RunContext } from '../../lib/runs/actions';
import { timingFromWire, timingToWire } from '../../lib/runs/fold';
import { fmtDuration } from '../../lib/runs/format';
import { isOpen, projectedEntryTiming } from '../../lib/runs/localView';
import type { LapType } from '../../lib/runs/types';
import { useRuns } from '../../lib/runs/useRuns';
import { Button, IconButton } from '../ui/Button';
import { Badge, Card } from '../ui/Card';
import { Icon } from '../ui/Icon';
import { ConfirmSheet, Sheet } from '../ui/Sheet';
import { useToast } from '../ui/Toast';
import { TimingEditor } from './TimingEditor';
import { timingFieldOf, type FieldErrors } from './timingEdit';

interface Props {
  entry: EntryOut & { timing: Timing };
  /** The run's version's steps (labels for skipped steps, and the editor's choices). */
  steps: readonly Step[];
  /** The run's version's lap types (the lap-type badges' labels, and the editor's). */
  laps?: readonly LapType[];
  /**
   * The run's context for its Remove and Resume taps (content-display.md §3.2): its topic,
   * version, steps and lap types. Null hides both.
   */
  ctx?: RunContext | null;
  /** Device time, epoch ms (Resume's window). */
  now?: () => number;
}

/** What a Remove asks before it is sent (content-display.md §3.2). */
interface RemoveAsk {
  target: string;
  pause: boolean;
}

/**
 * A timed entry's times on its edit page (timers.md §11.1, §11.5): start, end, total and
 * paused time, each segment and, in the same list, the pauses between the segments they fall
 * in (content-display.md §3.2, `timingRows`), the skipped steps, and Edit times. Rows are
 * `entry.timing.segment.<i>` and `entry.timing.pause.<i>`, 0-based in `timing.segments` and
 * `timing.pauses`. The edit is a PATCH with
 * `timing` and `expected_revision`, online like every other PWA entry edit (`useUpdateEntry`);
 * the server's 422 field errors show on the fields they name.
 *
 * The form edits the times as they were when it opened, and saves against that revision. If
 * the entry has changed since (a 409 `stale_revision`, or a newer revision fetched while the
 * form is open), saving stops until the user reloads the times: a draft is never re-based
 * silently, nor saved against a revision it wasn't made from.
 */
export function TimingSection({ entry, steps, laps = [], ctx = null, now = Date.now }: Props) {
  const { items } = useOutbox();
  const { runs, deps } = useRuns();
  const navigate = useNavigate();
  // A14: this device's queued removes of the run, applied to the entry's timing until the
  // ack replaces the entry (revision unchanged here, a pending mark meanwhile).
  const projected = useMemo(
    () => projectedEntryTiming({ id: entry.id, timing: timingFromWire(entry.timing) }, items),
    [entry.id, entry.timing, items],
  );
  const pending = projected.pending;
  const timing: Timing = pending
    ? { ...timingToWire(projected.timing), skipped: [...projected.timing.skipped] }
    : entry.timing;
  const [ask, setAsk] = useState<RemoveAsk | null>(null);
  const [tapping, setTapping] = useState<'remove' | 'reopen' | null>(null);
  // A15: the server would refuse a reopen while the topic has another open run.
  const topicBusy =
    ctx !== null &&
    runs.some((r) => r.topic_id === ctx.topic.id && (isOpen(r) || r.status === 'finishing'));
  const canResume =
    ctx !== null && !pending && !topicBusy && resumableFromDetail(entry.timing, now());
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

  /** The entry the taps are made from: the server's, as the targets are its ids (§5.3). */
  const ref = (): EntryRef => ({
    id: entry.id,
    timing: timingFromWire(entry.timing),
    revision: entry.revision,
  });

  const remove = async (target: string) => {
    if (!ctx) return;
    setTapping('remove');
    try {
      const item = await tapRun(deps, entry.id, ctx, 'remove', {}, { target, entry: ref() });
      if (item) void kickOutbox(true);
      else toast({ title: 'That can’t be removed now', tone: 'danger' });
    } catch (err) {
      toast({
        title: 'That wasn’t removed',
        description: mapApiError(err).message,
        tone: 'danger',
      });
    } finally {
      setTapping(null);
      setAsk(null);
    }
  };

  const resume = async () => {
    if (!ctx) return;
    setTapping('reopen');
    try {
      const item = await tapRun(deps, entry.id, ctx, 'reopen', {}, { entry: ref() });
      if (!item) {
        toast({ title: 'This run can’t be resumed now', tone: 'danger' });
        return;
      }
      void kickOutbox(true);
      // The run panel shows the run "Resuming…" until the ack (timers2.md §5.3).
      void navigate(`/t/${ctx.topic.slug}/record`);
    } catch (err) {
      toast({
        title: 'The run wasn’t resumed',
        description: mapApiError(err).message,
        tone: 'danger',
      });
    } finally {
      setTapping(null);
    }
  };

  const lapTypeLabel = (key: string) => laps.find((l) => l.key === key)?.label ?? key;

  /** The row's Remove button, if it has one (content-display.md §3.2). */
  const removeButton = (row: TimingRow, name: string) => {
    const control = ctx ? removeControl(row, timing) : { kind: 'none' as const };
    if (control.kind === 'none') return null;
    const testId =
      row.kind === 'pause'
        ? `entry.timing.pause.remove.${String(row.index)}`
        : `entry.timing.remove.${String(row.index)}`;
    return (
      <IconButton
        label={`Remove ${name}`}
        size="sm"
        data-testid={testId}
        disabled={control.kind === 'disabled' || tapping !== null}
        title={
          control.kind === 'disabled'
            ? 'This lap follows the last step: change it with Edit times'
            : `Remove ${name}`
        }
        className="-my-1.5 hover:bg-danger-soft hover:text-danger"
        onClick={() => {
          if (control.kind === 'remove')
            setAsk({ target: control.target, pause: row.kind === 'pause' });
        }}
      >
        <Icon name="x" className="size-4" />
      </IconButton>
    );
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
        {pending ? (
          <Badge tone="info">
            <span data-testid="entry.timing.pending" className="inline-flex items-center gap-1">
              <Icon name="clock" className="size-3.5" /> Waiting to sync
            </span>
          </Badge>
        ) : null}
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
        {timingRows(timing).map((row) =>
          row.kind === 'pause' ? (
            <li
              key={`pause-${String(row.index)}`}
              className="flex items-center gap-3 py-1.5 text-sm text-muted"
              data-testid={`entry.timing.pause.${String(row.index)}`}
              aria-label={`Paused, ${spokenDuration(row.ms)}`}
            >
              <span className="grid w-5 shrink-0 place-items-start" aria-hidden>
                <Icon name="pause" className="size-3.5" />
              </span>
              <span className="flex-1">
                Paused · <span className="font-mono tabular">{fmtDuration(row.ms)}</span>
              </span>
              {removeButton(row, `pause, ${fmtDuration(row.ms)}`)}
            </li>
          ) : (
            <li
              key={`segment-${String(row.index)}`}
              className="flex items-baseline gap-3 py-1.5"
              data-testid={`entry.timing.segment.${String(row.index)}`}
            >
              <span className="w-5 shrink-0 font-mono text-xs text-muted">{row.index + 1}</span>
              <span
                className={row.segment.kind === 'lap' ? 'flex-1 text-ink-soft italic' : 'flex-1'}
              >
                {row.segment.kind === 'step' && row.segment.step
                  ? label(row.segment.step)
                  : row.segment.label}
              </span>
              {row.segment.kind === 'lap' && row.segment.lap_type !== null ? (
                <Badge className="self-center">
                  <span data-testid={`entry.timing.laptype.${String(row.index)}`}>
                    {lapTypeLabel(row.segment.lap_type)}
                  </span>
                </Badge>
              ) : null}
              {row.segment.paused_ms > 0 ? (
                <span className="text-xs text-muted">
                  {fmtDuration(row.segment.paused_ms)} paused
                </span>
              ) : null}
              <span className="font-mono text-sm font-semibold tabular">
                {fmtDuration(row.segment.active_ms)}
              </span>
              {removeButton(row, row.segment.label)}
            </li>
          ),
        )}
      </ol>
      {timing.skipped.length > 0 ? (
        <p className="text-sm text-muted">Skipped: {timing.skipped.map(label).join(', ')}</p>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {canResume ? (
          <Button
            variant="primary"
            icon={<Icon name="play" />}
            data-testid="entry-resume"
            loading={tapping === 'reopen'}
            disabled={tapping !== null}
            onClick={() => void resume()}
          >
            {tapping === 'reopen' ? 'Resuming…' : 'Resume run'}
          </Button>
        ) : null}
        {/* A save now would mark the run edited and void the queued remove (timers2.md
            §3.6): the times can be edited once it is acked. */}
        <Button
          icon={<Icon name="clock" />}
          disabled={pending}
          title={pending ? 'Waiting for a removal to sync' : undefined}
          onClick={() => open(entry.revision, entry.timing)}
        >
          Edit times
        </Button>
      </div>
      <ConfirmSheet
        open={ask !== null}
        onClose={() => setAsk(null)}
        onConfirm={() => {
          if (ask) void remove(ask.target);
        }}
        title={ask?.pause ? 'Remove this pause?' : 'Remove this lap?'}
        body={
          <p>{ask?.pause ? 'Its time becomes active.' : 'Its time joins the previous segment.'}</p>
        }
        confirmLabel="Remove"
        danger
        busy={tapping === 'remove'}
      />
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
            laps={laps}
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
