import { useMemo, useState } from 'react';

import type { Step, Timing, TimingEdit } from '../../client';
import { fmtDuration } from '../../lib/runs/format';
import { Button, IconButton } from '../ui/Button';
import { Banner } from '../ui/Card';
import { Checkbox, Field, Input, Select } from '../ui/Field';
import { Icon } from '../ui/Icon';
import {
  checkTimingDraft,
  draftFromTiming,
  newPause,
  newSegment,
  originalInstants,
  withSegmentStep,
  type FieldErrors,
  type TimingDraft,
} from './timingEdit';

const LAP = '__lap__';

interface Props {
  timing: Timing;
  /** The run's version's steps. */
  steps: readonly Step[];
  /** Field errors from the server (paths relative to `timing`), and its banner message. */
  serverErrors: FieldErrors;
  serverMessage: string | null;
  saving: boolean;
  onSave: (edit: TimingEdit) => void;
  onCancel: () => void;
}

/**
 * The Edit times form (timers.md §3.8): the start, each segment's step (or lap) and end, the
 * skipped steps and the pauses. Durations update as you type; a save sends the whole
 * `TimingEdit`, checked first with the server's rules. The server's own 422 messages show on
 * the field they name.
 */
export function TimingEditor({
  timing,
  steps,
  serverErrors,
  serverMessage,
  saving,
  onSave,
  onCancel,
}: Props) {
  const [draft, setDraft] = useState<TimingDraft>(() => draftFromTiming(timing));
  const [submitted, setSubmitted] = useState(false);
  // Server errors stand until the field they name is edited.
  const [stale, setStale] = useState<Set<string>>(new Set());
  const [errorsSeen, setErrorsSeen] = useState(serverErrors);
  if (errorsSeen !== serverErrors) {
    // A new answer from the server: every field it names shows again.
    setErrorsSeen(serverErrors);
    setStale(new Set());
  }
  const originals = useMemo(() => originalInstants(timing), [timing]);
  const checked = checkTimingDraft(draft, steps, originals);

  const errorAt = (path: string): string | undefined =>
    (submitted ? checked.errors[path] : undefined) ??
    (stale.has(path) ? undefined : serverErrors[path]);
  const touch = (path: string) => setStale((s) => new Set(s).add(path));
  const update = (path: string, next: TimingDraft) => {
    touch(path);
    setDraft(next);
  };

  const used = new Set(draft.segments.map((s) => s.step).filter((k) => k !== null));
  const unreached = steps.filter((s) => !used.has(s.key));
  const formError = errorAt('') ?? errorAt('segments');

  return (
    <form
      noValidate
      className="flex flex-col gap-5"
      aria-label="Edit times"
      onSubmit={(e) => {
        e.preventDefault();
        setSubmitted(true);
        if (checked.edit) onSave(checked.edit);
      }}
    >
      {serverMessage ? <Banner title={serverMessage} /> : null}
      {formError ? (
        <p role="alert" className="text-sm font-medium text-danger">
          {formError}
        </p>
      ) : null}

      <Field label="Started" error={errorAt('started_at')}>
        {({ id, describedBy, invalid }) => (
          <Input
            id={id}
            type="datetime-local"
            step={1}
            aria-describedby={describedBy}
            aria-invalid={invalid || undefined}
            value={draft.started_at}
            onChange={(e) => update('started_at', { ...draft, started_at: e.target.value })}
          />
        )}
      </Field>

      <section aria-label="Segments" className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold text-ink-soft">Segments</h3>
        <ol className="flex flex-col gap-2">
          {draft.segments.map((seg, i) => {
            const n = String(i + 1);
            const shown = checked.segments[i];
            const stepError = errorAt(`segments.${String(i)}.step`);
            const endError = errorAt(`segments.${String(i)}.ended_at`);
            return (
              <li
                key={seg.uid}
                className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 rounded-xl border border-line bg-paper/40 p-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]"
              >
                <Field label={`Segment ${n}`} error={stepError}>
                  {({ id, describedBy, invalid }) => (
                    <Select
                      id={id}
                      aria-describedby={describedBy}
                      aria-invalid={invalid || undefined}
                      value={seg.kind === 'lap' ? LAP : (seg.step ?? '')}
                      onChange={(e) =>
                        update(
                          `segments.${String(i)}.step`,
                          withSegmentStep(draft, i, e.target.value === LAP ? null : e.target.value),
                        )
                      }
                    >
                      {steps.map((s) => (
                        <option key={s.key} value={s.key}>
                          {s.label}
                        </option>
                      ))}
                      {seg.kind === 'step' && seg.step && !steps.some((s) => s.key === seg.step) ? (
                        <option value={seg.step}>{seg.step}</option>
                      ) : null}
                      <option value={LAP}>Lap</option>
                    </Select>
                  )}
                </Field>
                <Field
                  label={`Segment ${n} ended`}
                  error={endError}
                  className="col-start-1 sm:col-start-auto"
                  hint={
                    shown?.active_ms != null
                      ? `${shown.label}: ${fmtDuration(shown.active_ms)}${
                          shown.paused_ms ? ` (${fmtDuration(shown.paused_ms)} paused)` : ''
                        }`
                      : undefined
                  }
                >
                  {({ id, describedBy, invalid }) => (
                    <Input
                      id={id}
                      type="datetime-local"
                      step={1}
                      aria-describedby={describedBy}
                      aria-invalid={invalid || undefined}
                      value={seg.ended_at}
                      onChange={(e) =>
                        update(`segments.${String(i)}.ended_at`, {
                          ...draft,
                          segments: draft.segments.map((s, j) =>
                            j === i ? { ...s, ended_at: e.target.value } : s,
                          ),
                        })
                      }
                    />
                  )}
                </Field>
                <IconButton
                  label={`Remove segment ${n}`}
                  size="sm"
                  disabled={draft.segments.length === 1}
                  className="col-start-2 row-start-1 mt-8 self-start hover:bg-danger-soft hover:text-danger sm:col-start-3"
                  onClick={() =>
                    update('segments', {
                      ...draft,
                      segments: draft.segments.filter((_, j) => j !== i),
                    })
                  }
                >
                  <Icon name="trash" className="size-4.5" />
                </IconButton>
              </li>
            );
          })}
        </ol>
        <Button
          size="md"
          className="self-start border-dashed"
          icon={<Icon name="plus" />}
          onClick={() =>
            update('segments', {
              ...draft,
              segments: [...draft.segments, newSegment(draft, steps)],
            })
          }
        >
          Add segment
        </Button>
      </section>

      {unreached.length > 0 ? (
        <section aria-label="Steps not timed" className="flex flex-col gap-2">
          <h3 className="text-sm font-semibold text-ink-soft">Steps without a segment</h3>
          <p className="text-xs text-muted">
            Tick a step that was skipped; leave it clear if the run stopped before it.
          </p>
          {unreached.map((s) => {
            const at = draft.skipped.indexOf(s.key);
            return (
              <div key={s.key}>
                <Checkbox
                  label={`Skipped ${s.label}`}
                  checked={at >= 0}
                  onChange={(e) =>
                    update(`skipped.${String(Math.max(at, 0))}`, {
                      ...draft,
                      skipped: e.target.checked
                        ? [...draft.skipped, s.key]
                        : draft.skipped.filter((k) => k !== s.key),
                    })
                  }
                />
                {at >= 0 && errorAt(`skipped.${String(at)}`) ? (
                  <p role="alert" className="text-sm font-medium text-danger">
                    {errorAt(`skipped.${String(at)}`)}
                  </p>
                ) : null}
              </div>
            );
          })}
        </section>
      ) : null}

      <section aria-label="Pauses" className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold text-ink-soft">Pauses</h3>
        {draft.pauses.length === 0 ? <p className="text-sm text-muted">No pauses.</p> : null}
        <ol className="flex flex-col gap-2">
          {draft.pauses.map((p, i) => {
            const n = String(i + 1);
            const set = (field: 'start' | 'end', value: string) =>
              update(`pauses.${String(i)}.${field}`, {
                ...draft,
                pauses: draft.pauses.map((x, j) => (j === i ? { ...x, [field]: value } : x)),
              });
            return (
              <li
                key={p.uid}
                className="grid grid-cols-[minmax(0,1fr)_auto] gap-2 rounded-xl border border-line bg-paper/40 p-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]"
              >
                <Field label={`Pause ${n} started`} error={errorAt(`pauses.${String(i)}.start`)}>
                  {({ id, describedBy, invalid }) => (
                    <Input
                      id={id}
                      type="datetime-local"
                      step={1}
                      aria-describedby={describedBy}
                      aria-invalid={invalid || undefined}
                      value={p.start}
                      onChange={(e) => set('start', e.target.value)}
                    />
                  )}
                </Field>
                <Field
                  label={`Pause ${n} ended`}
                  error={errorAt(`pauses.${String(i)}.end`)}
                  className="col-start-1 sm:col-start-auto"
                >
                  {({ id, describedBy, invalid }) => (
                    <Input
                      id={id}
                      type="datetime-local"
                      step={1}
                      aria-describedby={describedBy}
                      aria-invalid={invalid || undefined}
                      value={p.end}
                      onChange={(e) => set('end', e.target.value)}
                    />
                  )}
                </Field>
                <IconButton
                  label={`Remove pause ${n}`}
                  size="sm"
                  className="col-start-2 row-start-1 mt-8 self-start hover:bg-danger-soft hover:text-danger sm:col-start-3"
                  onClick={() =>
                    update('pauses', { ...draft, pauses: draft.pauses.filter((_, j) => j !== i) })
                  }
                >
                  <Icon name="trash" className="size-4.5" />
                </IconButton>
              </li>
            );
          })}
        </ol>
        <Button
          size="md"
          className="self-start border-dashed"
          icon={<Icon name="plus" />}
          onClick={() => update('pauses', { ...draft, pauses: [...draft.pauses, newPause(draft)] })}
        >
          Add pause
        </Button>
      </section>

      <p className="text-sm text-ink-soft" data-testid="edited-total">
        Total{' '}
        <strong className="font-mono tabular">
          {checked.active_ms === null ? '—' : fmtDuration(checked.active_ms)}
        </strong>
        {checked.paused_ms ? (
          <span className="text-muted"> · {fmtDuration(checked.paused_ms)} paused</span>
        ) : null}
      </p>

      <div className="flex justify-end gap-2">
        <Button size="lg" onClick={onCancel}>
          Cancel
        </Button>
        <Button type="submit" variant="primary" size="lg" loading={saving}>
          Save times
        </Button>
      </div>
    </form>
  );
}
