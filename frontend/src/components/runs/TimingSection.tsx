import { useState } from 'react';

import { mapApiError } from '../../api/errors';
import { useUpdateEntry } from '../../api/mutations';
import type { EntryOut, Step, Timing, TimingEdit } from '../../client';
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
 */
export function TimingSection({ entry, steps }: Props) {
  const timing = entry.timing;
  const update = useUpdateEntry();
  const { toast } = useToast();
  const [editing, setEditing] = useState(false);
  const [server, setServer] = useState<{ errors: FieldErrors; message: string | null }>({
    errors: {},
    message: null,
  });
  const label = (key: string) => steps.find((s) => s.key === key)?.label ?? key;

  const save = async (edit: TimingEdit) => {
    try {
      await update.mutateAsync({
        path: { entry_id: entry.id },
        body: { timing: edit, expected_revision: entry.revision },
      });
      setEditing(false);
      setServer({ errors: {}, message: null });
      toast({ title: 'Times updated' });
    } catch (err) {
      const mapped = mapApiError(err);
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
        onClick={() => {
          setServer({ errors: {}, message: null });
          setEditing(true);
        }}
      >
        Edit times
      </Button>
      <Sheet
        open={editing}
        onClose={() => setEditing(false)}
        wide
        title="Edit times"
        description="The run’s end is the entry’s time. Later taps on this run are ignored once you save."
      >
        {editing ? (
          <TimingEditor
            timing={timing}
            steps={steps}
            serverErrors={server.errors}
            serverMessage={server.message}
            saving={update.isPending}
            onSave={(edit) => void save(edit)}
            onCancel={() => setEditing(false)}
          />
        ) : null}
      </Sheet>
    </Card>
  );
}
