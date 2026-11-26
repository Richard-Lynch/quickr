import { useRef, type ChangeEvent } from 'react';
import { useFieldArray, useFormContext, useFormState } from 'react-hook-form';

import type { Limits } from '../../client';
import { newDraftVariable, type TopicDraft } from '../../lib/builder';
import { Button, IconButton } from '../ui/Button';
import { cn } from '../ui/cn';
import { Input } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { fieldError } from './fieldError';

/**
 * The timer's variables (timers2.md §1.6): named durations the alerts refer to (`t`, `rest`).
 * A name is lowercased as it is typed (the server stores it so); a duration is typed as `m:ss`
 * or `h:mm:ss` and sent as ms.
 */
export function VariablesEditor({ limits }: { limits: Limits }) {
  const { control, register } = useFormContext<TopicDraft>();
  const { errors } = useFormState({ control, name: 'variables' });
  const { fields, append, remove } = useFieldArray({
    control,
    name: 'variables',
    keyName: 'fieldId',
  });
  const addButton = useRef<HTMLButtonElement>(null);
  const listError = fieldError(errors, 'variables');

  const add = () => {
    const v = newDraftVariable();
    append(v, { shouldFocus: false });
    window.setTimeout(() => {
      document.getElementById(`variable-${v.uid}`)?.focus();
    }, 0);
  };

  return (
    <div className="flex flex-col gap-2">
      <div>
        <h3 className="font-display text-base font-semibold tracking-tight">
          Variables{' '}
          <span className="font-mono text-sm font-normal text-muted">{fields.length}</span>
        </h3>
        <p className="text-sm text-muted">
          Durations your alerts use by name: <code className="font-mono">t/2</code>,{' '}
          <code className="font-mono">t+30s</code>.
        </p>
      </div>
      {fields.length > 0 ? (
        <ol className="flex flex-col gap-2">
          {fields.map((f, i) => {
            const nameError = fieldError(errors, `variables.${i}.name`);
            const durationError = fieldError(errors, `variables.${i}.duration`);
            const nameReg = register(`variables.${i}.name`);
            const lowercase = (e: ChangeEvent<HTMLInputElement>) => {
              const el = e.target;
              const lower = el.value.toLowerCase();
              if (lower !== el.value) {
                const [start, end] = [el.selectionStart, el.selectionEnd];
                el.value = lower;
                el.setSelectionRange(start, end);
              }
              return nameReg.onChange(e);
            };
            const nameErrorId = `variable-${f.uid}-name-error`;
            const durationErrorId = `variable-${f.uid}-duration-error`;
            return (
              <li
                key={f.fieldId}
                className={cn(
                  'flex flex-col gap-1 rounded-card border bg-surface px-3 py-2 shadow-card',
                  nameError || durationError ? 'border-danger/60' : 'border-line',
                )}
              >
                <div className="flex items-center gap-2">
                  <Input
                    id={`variable-${f.uid}`}
                    aria-label={`Variable ${String(i + 1)} name`}
                    aria-invalid={nameError ? true : undefined}
                    aria-describedby={nameError ? nameErrorId : undefined}
                    placeholder="t"
                    autoCapitalize="none"
                    autoCorrect="off"
                    spellCheck={false}
                    maxLength={limits.max_var_name_length}
                    className="h-11 min-w-0 flex-1 font-mono"
                    {...nameReg}
                    onChange={(e) => void lowercase(e)}
                  />
                  <span aria-hidden className="text-muted">
                    =
                  </span>
                  <Input
                    aria-label={`Variable ${String(i + 1)} duration`}
                    aria-invalid={durationError ? true : undefined}
                    aria-describedby={durationError ? durationErrorId : undefined}
                    placeholder="m:ss"
                    autoComplete="off"
                    className="h-11 w-28 shrink-0 font-mono tabular-nums"
                    {...register(`variables.${i}.duration`)}
                  />
                  <IconButton
                    label={`Remove variable ${String(i + 1)}`}
                    size="sm"
                    onClick={() => {
                      const next = fields[i + 1] ?? fields[i - 1];
                      remove(i);
                      window.setTimeout(() => {
                        const el = next ? document.getElementById(`variable-${next.uid}`) : null;
                        (el ?? addButton.current)?.focus();
                      }, 0);
                    }}
                    className="hover:bg-danger-soft hover:text-danger"
                  >
                    <Icon name="trash" className="size-4.5" />
                  </IconButton>
                </div>
                {nameError ? (
                  <p id={nameErrorId} role="alert" className="text-sm font-medium text-danger">
                    {nameError}
                  </p>
                ) : null}
                {durationError ? (
                  <p id={durationErrorId} role="alert" className="text-sm font-medium text-danger">
                    {durationError}
                  </p>
                ) : null}
              </li>
            );
          })}
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
        disabled={fields.length >= limits.max_variables}
      >
        Add variable
      </Button>
    </div>
  );
}
