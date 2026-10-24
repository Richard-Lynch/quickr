import { useRef } from 'react';
import { useFieldArray, useFormContext, useWatch } from 'react-hook-form';

import {
  MAX_STEPS,
  newDraftStep,
  withStepLabel,
  type DraftStep,
  type TopicDraft,
} from '../../lib/builder';
import { Button, IconButton } from '../ui/Button';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Input } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { Switch } from '../ui/Switch';
import { fieldError } from './fieldError';

/**
 * The Timed switch and the steps editor (timers.md §2.1, §11.5). A timed topic's entries are
 * runs: Start, then Next through the steps (none makes a plain stopwatch), then Stop.
 *
 * A published step keeps its key when renamed, so its stats join across versions; a new
 * step's key follows its label until it is published. Switching Timed off empties the steps
 * (so they don't block publishing) and switching it back on restores them.
 */
export function TimerEditor() {
  const { control, setValue, getValues, register, formState } = useFormContext<TopicDraft>();
  const timed = useWatch({ control, name: 'timed' });
  const { fields, append, remove, move, replace } = useFieldArray({
    control,
    name: 'steps',
    keyName: 'fieldId',
  });
  const parked = useRef<DraftStep[]>([]);
  const listError = fieldError(formState.errors, 'steps');

  const setTimed = (next: boolean) => {
    if (next) {
      replace(parked.current);
    } else {
      parked.current = getValues('steps');
      replace([]);
    }
    setValue('timed', next, { shouldDirty: true });
  };

  const add = () => {
    const step = newDraftStep('', []);
    append(step, { shouldFocus: false });
    window.setTimeout(() => {
      document.getElementById(`step-${step.uid}`)?.focus();
    }, 0);
  };

  return (
    <section className="flex flex-col gap-3" aria-label="Timing">
      <div className="flex items-center justify-between gap-3 rounded-card border border-line bg-surface p-4 shadow-card">
        <div className="min-w-0">
          <h2 className="font-display text-lg font-semibold tracking-tight">Timed</h2>
          <p className="text-sm text-muted">
            {timed
              ? 'Each entry is a run: Start, Next through the steps, then Stop.'
              : 'Time each entry with Start and Stop, and optional named steps.'}
          </p>
        </div>
        <Switch checked={timed} onChange={setTimed} label="Timed" />
      </div>

      {timed ? (
        <>
          <div className="flex items-end justify-between">
            <h3 className="font-display text-base font-semibold tracking-tight">
              Steps{' '}
              <span className="font-mono text-sm font-normal text-muted">{fields.length}</span>
            </h3>
          </div>
          {fields.length === 0 ? (
            <p className="text-sm text-muted" data-testid="no-steps">
              No steps: a plain stopwatch, with laps.
            </p>
          ) : null}
          <ol className="flex flex-col gap-2">
            {fields.map((f, i) => {
              const labelError = fieldError(formState.errors, `steps.${i}.label`);
              const keyError = fieldError(formState.errors, `steps.${i}.key`);
              const reg = register(`steps.${i}.label`, {
                onChange: (e: { target: { value: string } }) => {
                  const all = getValues('steps');
                  const cur = all[i];
                  if (!cur) return;
                  const taken = all.filter((_, j) => j !== i).map((s) => s.key);
                  const next = withStepLabel(cur, e.target.value, taken);
                  if (next.key !== cur.key)
                    setValue(`steps.${i}.key`, next.key, { shouldValidate: formState.isSubmitted });
                },
              });
              return (
                <li
                  key={f.fieldId}
                  className={cn(
                    'flex flex-col gap-1 rounded-card border bg-surface px-3 py-2 shadow-card',
                    labelError || keyError ? 'border-danger/60' : 'border-line',
                  )}
                >
                  <div className="flex items-center gap-1">
                    <span className="w-5 shrink-0 font-mono text-xs text-muted">{i + 1}</span>
                    <Input
                      id={`step-${f.uid}`}
                      aria-label={`Step ${String(i + 1)} name`}
                      aria-invalid={labelError ? true : undefined}
                      placeholder="Step name"
                      className="h-11 flex-1"
                      {...reg}
                    />
                    <IconButton
                      label="Move step up"
                      size="sm"
                      disabled={i === 0}
                      onClick={() => move(i, i - 1)}
                    >
                      <Icon name="up" className="size-4.5" />
                    </IconButton>
                    <IconButton
                      label="Move step down"
                      size="sm"
                      disabled={i === fields.length - 1}
                      onClick={() => move(i, i + 1)}
                    >
                      <Icon name="down" className="size-4.5" />
                    </IconButton>
                    <IconButton
                      label="Remove step"
                      size="sm"
                      onClick={() => remove(i)}
                      className="hover:bg-danger-soft hover:text-danger"
                    >
                      <Icon name="trash" className="size-4.5" />
                    </IconButton>
                  </div>
                  <StepKey index={i} />
                  {labelError || keyError ? (
                    <p role="alert" className="pl-6 text-sm font-medium text-danger">
                      {labelError ?? keyError}
                    </p>
                  ) : null}
                </li>
              );
            })}
          </ol>
          {listError ? (
            <p role="alert" className="text-sm font-medium text-danger">
              {listError}
            </p>
          ) : null}
          <Button
            size="lg"
            onClick={add}
            className="border-dashed"
            icon={<Icon name="plus" />}
            disabled={fields.length >= MAX_STEPS}
          >
            Add step
          </Button>
        </>
      ) : null}
    </section>
  );
}

/** The step's key, and whether it is published (its key then never changes). */
function StepKey({ index }: { index: number }) {
  const { control } = useFormContext<TopicDraft>();
  const step = useWatch({ control, name: `steps.${index}` });
  return (
    <p className="flex items-center gap-2 pl-6 text-xs text-muted">
      <span className="font-mono" data-testid="step-key">
        {step.key || '—'}
      </span>
      {step.locked ? <Badge>published</Badge> : <Badge tone="accent">new</Badge>}
    </p>
  );
}
