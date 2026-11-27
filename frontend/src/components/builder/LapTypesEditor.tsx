import { useRef } from 'react';
import { useFieldArray, useFormContext, useFormState, useWatch } from 'react-hook-form';

import type { Limits } from '../../client';
import {
  newDraftLapType,
  takenTimerKeys,
  withLapTypeLabel,
  type TimerHistory,
  type TopicDraft,
} from '../../lib/builder';
import { inputMaxLength } from '../../lib/text';
import { Button } from '../ui/Button';
import { Icon } from '../ui/Icon';
import { fieldError } from './fieldError';
import { TimerItemRow } from './TimerItemRow';

/**
 * The timer's lap types (timers2.md §1.1, §1.6): none makes laps "Lap 1, Lap 2…"; one renames
 * them ("Cig 1, Cig 2"); two or more alternate ("Run 1, Rest 1, Run 2…"). A lap type's key
 * shares the steps' namespace: a new one's follows its label, avoiding the steps' keys and every
 * key the topic has used, unless it is named like a retired lap type, whose key it takes back.
 * A published one keeps its key when renamed.
 */
export function LapTypesEditor({ history, limits }: { history: TimerHistory; limits: Limits }) {
  const { control, register, getValues, setValue } = useFormContext<TopicDraft>();
  const { errors, isSubmitted } = useFormState({ control, name: 'laps' });
  const { fields, append, remove, move } = useFieldArray({
    control,
    name: 'laps',
    keyName: 'fieldId',
  });
  const laps = useWatch({ control, name: 'laps' });
  const addButton = useRef<HTMLButtonElement>(null);
  const listError = fieldError(errors, 'laps');
  const nameOf = (i: number) => {
    const label = laps[i]?.label.trim();
    return label ? `${label} (lap type ${String(i + 1)})` : `lap type ${String(i + 1)}`;
  };

  const add = () => {
    const lap = newDraftLapType('', []);
    append(lap, { shouldFocus: false });
    window.setTimeout(() => {
      document.getElementById(`lap-${lap.uid}`)?.focus();
    }, 0);
  };

  return (
    <div className="flex flex-col gap-2">
      <div>
        <h3 className="font-display text-base font-semibold tracking-tight">
          Lap types{' '}
          <span className="font-mono text-sm font-normal text-muted">{fields.length}</span>
        </h3>
        <p className="text-sm text-muted">
          {fields.length === 0
            ? 'None: laps are Lap 1, Lap 2… One renames them; two or more take turns.'
            : fields.length === 1
              ? 'Every lap is this type, numbered.'
              : 'Laps take turns through these, in order.'}
        </p>
      </div>
      {fields.length > 0 ? (
        <ol className="flex flex-col gap-2">
          {fields.map((f, i) => (
            <TimerItemRow
              key={f.fieldId}
              owner="laps"
              index={i}
              uid={`lap-${f.uid}`}
              count={fields.length}
              name={nameOf(i)}
              inputLabel={`Lap type ${String(i + 1)} name`}
              placeholder="Lap type name"
              keyTestId="lap-type-key"
              maxLength={inputMaxLength(limits.max_short_label_length)}
              limits={limits}
              registration={register(`laps.${i}.label`, {
                onChange: (e: { target: { value: string } }) => {
                  const draft = getValues();
                  const cur = draft.laps[i];
                  if (!cur) return;
                  const taken = takenTimerKeys(draft, 'lap', i, history);
                  const next = withLapTypeLabel(cur, e.target.value, taken, history);
                  if (next.key !== cur.key)
                    setValue(`laps.${i}.key`, next.key, { shouldValidate: isSubmitted });
                },
              })}
              onMove={(to) => move(i, to)}
              onRemove={() => {
                const next = fields[i + 1] ?? fields[i - 1];
                remove(i);
                window.setTimeout(() => {
                  const el = next ? document.getElementById(`lap-${next.uid}`) : null;
                  (el ?? addButton.current)?.focus();
                }, 0);
              }}
            />
          ))}
        </ol>
      ) : null}
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
        disabled={fields.length >= limits.max_lap_types}
      >
        Add lap type
      </Button>
    </div>
  );
}
