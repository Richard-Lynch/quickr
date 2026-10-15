import { useState } from 'react';
import { useFieldArray, useFormContext, useWatch } from 'react-hook-form';

import { newDraftOption, toSnakeKey, uniqueKey, type TopicDraft } from '../../lib/builder';
import { Button, IconButton } from '../ui/Button';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { fieldError } from './fieldError';

/**
 * Enum options: add / relabel / reorder / archive. Options that exist in a
 * published version are locked — their value can't change and they can only be
 * archived (removing would orphan historic answers). New ones can be deleted.
 */
export function OptionsEditor({ index }: { index: number }) {
  const { control, register, setValue, getValues, formState } = useFormContext<TopicDraft>();
  const name = `questions.${index}.options` as const;
  const { fields, append, remove, move } = useFieldArray({ control, name, keyName: 'fieldId' });
  const options = useWatch({ control, name });
  const [draft, setDraft] = useState('');
  const groupError = fieldError(formState.errors, `questions.${index}.options`);

  const add = () => {
    const label = draft.trim();
    if (!label) return;
    append(
      newDraftOption(
        label,
        getValues(name).map((o) => o.value),
      ),
    );
    setDraft('');
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-semibold text-ink-soft">Options</span>
        <span className="text-xs text-muted">≤ 6 render as chips, more as a dropdown</span>
      </div>
      <ul className="flex flex-col gap-2">
        {fields.map((f, i) => {
          const o = options[i] ?? f;
          const labelErr = fieldError(formState.errors, `${name}.${i}.label`);
          const valueErr = fieldError(formState.errors, `${name}.${i}.value`);
          const labelReg = register(`${name}.${i}.label`, {
            onChange: (e: { target: { value: string } }) => {
              const cur = getValues(`${name}.${i}`);
              if (cur.locked || cur.valueEdited) return;
              const taken = getValues(name)
                .filter((_, j) => j !== i)
                .map((x) => x.value);
              setValue(
                `${name}.${i}.value`,
                uniqueKey(toSnakeKey(e.target.value) || 'option', taken),
                {
                  shouldValidate: formState.isSubmitted,
                },
              );
            },
          });
          const valueReg = register(`${name}.${i}.value`, {
            onChange: () => setValue(`${name}.${i}.valueEdited`, true),
          });
          return (
            <li
              key={f.fieldId}
              className={cn(
                'flex items-start gap-1.5 rounded-xl border border-line bg-paper/50 p-1.5',
                o.archived && 'opacity-60',
              )}
            >
              <div className="flex shrink-0 flex-col">
                <IconButton
                  label="Move option up"
                  size="sm"
                  disabled={i === 0}
                  onClick={() => move(i, i - 1)}
                  className="size-7"
                >
                  <Icon name="up" className="size-4" />
                </IconButton>
                <IconButton
                  label="Move option down"
                  size="sm"
                  disabled={i === fields.length - 1}
                  onClick={() => move(i, i + 1)}
                  className="size-7"
                >
                  <Icon name="down" className="size-4" />
                </IconButton>
              </div>
              <div className="flex min-w-0 flex-1 flex-col gap-1">
                <input
                  {...labelReg}
                  aria-label={`Option ${i + 1} label`}
                  aria-invalid={labelErr ? true : undefined}
                  className={cn(
                    'h-10 w-full rounded-lg border border-line-strong bg-surface px-3 outline-none focus:border-accent aria-invalid:border-danger',
                    o.archived && 'line-through',
                  )}
                />
                <div className="flex items-center gap-1.5">
                  <span className="font-mono text-[0.7rem] text-muted">value</span>
                  <input
                    {...valueReg}
                    aria-label={`Option ${i + 1} value`}
                    aria-invalid={valueErr ? true : undefined}
                    readOnly={o.locked}
                    autoCapitalize="none"
                    spellCheck={false}
                    className="h-7 min-w-0 flex-1 rounded-md border border-transparent bg-transparent px-1.5 font-mono text-xs outline-none read-only:text-muted hover:border-line focus:border-accent aria-invalid:border-danger"
                    style={{ fontSize: '12px' }}
                  />
                  {o.locked ? <Badge className="h-5 text-[0.65rem]">published</Badge> : null}
                </div>
                {(labelErr ?? valueErr) ? (
                  <p role="alert" className="text-xs font-medium text-danger">
                    {labelErr ?? valueErr}
                  </p>
                ) : null}
              </div>
              {o.locked ? (
                <Button
                  size="sm"
                  variant="ghost"
                  className="h-10 px-2.5 text-xs"
                  onClick={() =>
                    setValue(`${name}.${i}.archived`, !o.archived, {
                      shouldDirty: true,
                      shouldValidate: formState.isSubmitted,
                    })
                  }
                  icon={<Icon name={o.archived ? 'restore' : 'archive'} className="size-4" />}
                >
                  {o.archived ? 'Restore' : 'Archive'}
                </Button>
              ) : (
                <IconButton
                  label={`Delete option ${i + 1}`}
                  size="sm"
                  onClick={() => remove(i)}
                  className="mt-0.5 text-danger hover:bg-danger-soft hover:text-danger"
                >
                  <Icon name="trash" className="size-4" />
                </IconButton>
              )}
            </li>
          );
        })}
      </ul>
      <div className="flex gap-2">
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              add();
            }
          }}
          placeholder="Add an option…"
          aria-label="New option label"
          enterKeyHint="done"
          className="h-11 min-w-0 flex-1 rounded-xl border border-dashed border-line-strong bg-surface px-3 outline-none focus:border-solid focus:border-accent"
        />
        <Button
          onClick={add}
          disabled={!draft.trim()}
          icon={<Icon name="plus" className="size-4" />}
        >
          Add
        </Button>
      </div>
      {groupError ? (
        <p role="alert" className="text-sm font-medium text-danger">
          {groupError}
        </p>
      ) : null}
    </div>
  );
}
