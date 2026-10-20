import { useMemo } from 'react';
import { useFieldArray, useFormContext, useWatch, type FieldErrors } from 'react-hook-form';

import { useLimits } from '../../api/limits';
import {
  ALL_DAYS,
  DAY_LABELS,
  describeSchedule,
  nextScheduleTime,
  scheduleFromDraft,
  timeZoneOptions,
  type IntervalUnit,
  type ScheduleDraft,
  type ScheduleKind,
} from '../../lib/schedule';
import { fieldError } from '../builder/fieldError';
import { Button, IconButton } from '../ui/Button';
import { cn } from '../ui/cn';
import { Field, Input, Select } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { Segmented } from '../ui/Segmented';
import { Switch } from '../ui/Switch';

/** Any form with a `schedule` draft (the topic builder, the topic settings form). */
interface WithSchedule {
  schedule: ScheduleDraft;
}

const KINDS: { value: ScheduleKind; label: string }[] = [
  { value: 'none', label: 'None' },
  { value: 'daily', label: 'Daily' },
  { value: 'interval', label: 'Every…' },
];

const UNITS: { value: IntervalUnit; label: string }[] = [
  { value: 'minutes', label: 'minutes' },
  { value: 'hours', label: 'hours' },
  { value: 'days', label: 'days' },
];

const PRESETS: { label: string; days: number[] }[] = [
  { label: 'Every day', days: [...ALL_DAYS] },
  { label: 'Weekdays', days: [1, 2, 3, 4, 5] },
  { label: 'Weekends', days: [6, 7] },
];

/**
 * Schedule fields: none / daily (times, weekdays) / interval (every N units), time zone
 * and the per-topic notification toggle. Validation lives in the form's schema
 * (`makeScheduleSchema`), so errors (client or server) show next to each field.
 */
export function ScheduleEditor() {
  const { control, register, setValue, formState } = useFormContext<WithSchedule>();
  const limits = useLimits();
  const draft = useWatch({ control, name: 'schedule' });
  const times = useFieldArray({ control, name: 'schedule.times' });
  const errors = formState.errors as FieldErrors;
  const err = (path: string) => fieldError(errors, `schedule.${path}`);
  const zones = useMemo(() => timeZoneOptions(draft.timezone), [draft.timezone]);
  const preview = scheduleFromDraft(draft, limits);
  const set = <K extends keyof ScheduleDraft>(key: K, value: ScheduleDraft[K]) => {
    setValue(`schedule.${key}`, value as never, {
      shouldDirty: true,
      shouldValidate: formState.isSubmitted,
    });
  };

  const toggleDay = (d: number) => {
    const next = draft.days.includes(d) ? draft.days.filter((x) => x !== d) : [...draft.days, d];
    set(
      'days',
      next.sort((a, b) => a - b),
    );
  };

  return (
    <div className="flex flex-col gap-4">
      <Segmented
        label="Schedule"
        size="md"
        value={draft.kind}
        onChange={(k) => set('kind', k)}
        options={KINDS}
        className="w-full [&>label]:flex-1"
      />

      {draft.kind === 'none' ? (
        <p className="text-sm text-muted">
          No reminders. Add a schedule to see when it’s due and get notified.
        </p>
      ) : null}

      {draft.kind === 'daily' ? (
        <>
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1.5 text-sm font-semibold text-ink-soft">At</legend>
            <ul className="flex flex-wrap gap-2">
              {times.fields.map((f, i) => {
                const e = err(`times.${String(i)}.value`);
                return (
                  <li key={f.id} className="flex flex-col gap-1">
                    <div className="flex items-center gap-1 rounded-xl border border-line-strong bg-surface pr-1 focus-within:border-accent">
                      <input
                        type="time"
                        aria-label={`Time ${String(i + 1)}`}
                        aria-invalid={e ? true : undefined}
                        className="h-12 w-28 rounded-xl bg-transparent pl-3 font-mono text-lg font-semibold tabular outline-none"
                        {...register(`schedule.times.${i}.value`)}
                      />
                      {times.fields.length > 1 ? (
                        <IconButton
                          label={`Remove time ${String(i + 1)}`}
                          size="sm"
                          onClick={() => times.remove(i)}
                        >
                          <Icon name="x" className="size-4" />
                        </IconButton>
                      ) : null}
                    </div>
                    {e ? (
                      <p role="alert" className="max-w-36 text-xs font-medium text-danger">
                        {e}
                      </p>
                    ) : null}
                  </li>
                );
              })}
              {times.fields.length < limits.schedule_max_times ? (
                <li>
                  <Button
                    className="h-12 border-dashed"
                    icon={<Icon name="plus" className="size-4" />}
                    onClick={() => times.append({ value: nextScheduleTime(draft.times) })}
                  >
                    Time
                  </Button>
                </li>
              ) : null}
            </ul>
            {err('times') ? (
              <p role="alert" className="text-sm font-medium text-danger">
                {err('times')}
              </p>
            ) : null}
          </fieldset>

          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1.5 flex w-full items-baseline justify-between text-sm font-semibold text-ink-soft">
              On
            </legend>
            <div className="grid grid-cols-7 gap-1.5" role="group" aria-label="Weekdays">
              {DAY_LABELS.map((d) => {
                const on = draft.days.includes(d.value);
                return (
                  <button
                    key={d.value}
                    type="button"
                    aria-pressed={on}
                    onClick={() => toggleDay(d.value)}
                    className={cn(
                      'h-11 rounded-xl border-2 text-sm font-semibold transition-transform active:scale-95',
                      on
                        ? 'border-accent bg-accent text-on-accent'
                        : 'border-line-strong bg-surface text-ink-soft',
                      err('days') && 'border-danger/60',
                    )}
                  >
                    {d.short}
                  </button>
                );
              })}
            </div>
            <div className="flex flex-wrap gap-1.5">
              {PRESETS.map((p) => {
                const active = p.days.join() === [...draft.days].sort((a, b) => a - b).join();
                return (
                  <button
                    key={p.label}
                    type="button"
                    onClick={() => set('days', p.days)}
                    aria-pressed={active}
                    className={cn(
                      'h-9 rounded-full px-3 text-[0.8rem] font-semibold',
                      active ? 'bg-ink text-paper' : 'bg-sunken text-ink-soft hover:text-ink',
                    )}
                  >
                    {p.label}
                  </button>
                );
              })}
            </div>
            {err('days') ? (
              <p role="alert" className="text-sm font-medium text-danger">
                {err('days')}
              </p>
            ) : null}
          </fieldset>
        </>
      ) : null}

      {draft.kind === 'interval' ? (
        <Field label="Every" error={err('every')} hint="Counted from your latest entry">
          {({ id, describedBy, invalid }) => (
            <div className="flex gap-2">
              <Input
                id={id}
                inputMode="numeric"
                autoComplete="off"
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                className="w-24 text-center font-mono text-lg font-semibold"
                {...register('schedule.every')}
              />
              <div className="flex-1">
                <Select
                  aria-label="Unit"
                  value={draft.unit}
                  onChange={(e) => set('unit', e.target.value as IntervalUnit)}
                >
                  {UNITS.map((u) => (
                    <option key={u.value} value={u.value}>
                      {u.label}
                    </option>
                  ))}
                </Select>
              </div>
            </div>
          )}
        </Field>
      ) : null}

      {draft.kind !== 'none' ? (
        <>
          <Field label="Time zone" error={err('timezone')}>
            {({ id, describedBy, invalid }) => (
              <Select
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                {...register('schedule.timezone')}
              >
                {zones.map((z) => (
                  <option key={z} value={z}>
                    {z.replace(/_/g, ' ')}
                  </option>
                ))}
              </Select>
            )}
          </Field>
          <div className="flex items-center gap-3 rounded-xl bg-sunken/60 px-3 py-2.5">
            <Icon name="bell" className="size-5 text-accent" />
            <div className="min-w-0 flex-1">
              <p className="text-[0.95rem] font-semibold">Notify me when it’s due</p>
              <p className="text-xs text-muted">Needs notifications on in Settings</p>
            </div>
            <Switch
              label="Notify me when it’s due"
              checked={draft.notify}
              onChange={(v) => set('notify', v)}
            />
          </div>
          <p className="text-sm text-muted" aria-live="polite">
            {preview.ok ? describeSchedule(preview.schedule) : 'Fix the schedule above'}
          </p>
        </>
      ) : null}
    </div>
  );
}
