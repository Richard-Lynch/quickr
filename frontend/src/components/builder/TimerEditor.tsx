import { useRef } from 'react';
import { useFieldArray, useFormContext, useFormState, useWatch } from 'react-hook-form';

import { FALLBACK_LIMITS } from '../../api/limits';
import type { Limits } from '../../client';
import {
  newDraftStep,
  takenTimerKeys,
  withStepLabel,
  type DraftLapType,
  type DraftStep,
  type DraftVariable,
  type TimerHistory,
  type TopicDraft,
} from '../../lib/builder';
import { Button } from '../ui/Button';
import { Switch } from '../ui/Switch';
import { fieldError } from './fieldError';
import { Icon } from '../ui/Icon';
import { LapTypesEditor } from './LapTypesEditor';
import { TimerItemRow } from './TimerItemRow';
import { VariablesEditor } from './VariablesEditor';

const NO_HISTORY: TimerHistory = { steps: [], laps: [] };

/**
 * The Timed switch and the timer's editors (timers.md §2.1, §11.5; timers2.md §1.6). A timed
 * topic's entries are runs: Start, then Next through the steps (none makes a plain stopwatch),
 * then Stop. Below the steps: the lap types, the variables, and each step's and lap type's
 * alerts.
 *
 * A published step keeps its key when renamed, so its stats join across versions; a new
 * step's key follows its label until it is published, avoiding the lap types' keys (one
 * namespace). Switching Timed off empties the timer's lists (so they don't block publishing)
 * and switching it back on restores them.
 *
 * `history`: every step and lap-type key the topic's versions have used. A new step named like
 * a retired one takes its key back; any other new step gets a key no version has used.
 */
export function TimerEditor({
  history = NO_HISTORY,
  limits = FALLBACK_LIMITS,
}: {
  history?: TimerHistory | undefined;
  limits?: Limits | undefined;
}) {
  const { control, setValue, getValues, register } = useFormContext<TopicDraft>();
  const { errors, isSubmitted } = useFormState({ control, name: 'steps' });
  const timed = useWatch({ control, name: 'timed' });
  const { fields, append, remove, move, replace } = useFieldArray({
    control,
    name: 'steps',
    keyName: 'fieldId',
  });
  const parked = useRef<{ steps: DraftStep[]; laps: DraftLapType[]; variables: DraftVariable[] }>({
    steps: [],
    laps: [],
    variables: [],
  });
  const addButton = useRef<HTMLButtonElement>(null);
  const steps = useWatch({ control, name: 'steps' });
  /** "Wipe down (step 2)", or "step 2" while it has no name. */
  const nameOf = (i: number) => {
    const label = steps[i]?.label.trim();
    return label ? `${label} (step ${String(i + 1)})` : `step ${String(i + 1)}`;
  };
  const listError = fieldError(errors, 'steps');

  const setTimed = (next: boolean) => {
    if (next) {
      replace(parked.current.steps);
      setValue('laps', parked.current.laps);
      setValue('variables', parked.current.variables);
    } else {
      parked.current = {
        steps: getValues('steps'),
        laps: getValues('laps'),
        variables: getValues('variables'),
      };
      replace([]);
      setValue('laps', []);
      setValue('variables', []);
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
            {fields.map((f, i) => (
              <TimerItemRow
                key={f.fieldId}
                owner="steps"
                index={i}
                uid={`step-${f.uid}`}
                count={fields.length}
                name={nameOf(i)}
                inputLabel={`Step ${String(i + 1)} name`}
                placeholder="Step name"
                keyTestId="step-key"
                limits={limits}
                registration={register(`steps.${i}.label`, {
                  onChange: (e: { target: { value: string } }) => {
                    const draft = getValues();
                    const cur = draft.steps[i];
                    if (!cur) return;
                    const taken = takenTimerKeys(draft, 'step', i, history);
                    const next = withStepLabel(cur, e.target.value, taken, history.steps);
                    if (next.key !== cur.key)
                      setValue(`steps.${i}.key`, next.key, { shouldValidate: isSubmitted });
                  },
                })}
                onMove={(to) => move(i, to)}
                onRemove={() => {
                  // Focus the step that takes its place, else the one before, else Add step.
                  const next = fields[i + 1] ?? fields[i - 1];
                  remove(i);
                  window.setTimeout(() => {
                    const el = next ? document.getElementById(`step-${next.uid}`) : null;
                    (el ?? addButton.current)?.focus();
                  }, 0);
                }}
              />
            ))}
          </ol>
          {listError ? (
            <p role="alert" className="text-sm font-medium text-danger">
              {listError}
            </p>
          ) : null}
          <Button
            ref={addButton}
            size="lg"
            onClick={add}
            className="border-dashed"
            icon={<Icon name="plus" />}
            disabled={fields.length >= limits.max_steps}
          >
            Add step
          </Button>
          <LapTypesEditor history={history} limits={limits} />
          <VariablesEditor limits={limits} />
        </>
      ) : null}
    </section>
  );
}
