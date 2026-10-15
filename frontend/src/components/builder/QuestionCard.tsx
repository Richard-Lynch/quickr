import { useFormContext, useWatch } from 'react-hook-form';

import { toSnakeKey, uniqueKey, type TopicDraft } from '../../lib/builder';
import { TYPE_META, type QuestionType } from '../../lib/questions';
import { IconButton } from '../ui/Button';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Checkbox, Field, Input, Textarea } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { fieldError } from './fieldError';
import { OptionsEditor } from './OptionsEditor';

export const TYPE_TONE: Record<QuestionType, string> = {
  int: 'bg-series-2/15 text-series-2',
  double: 'bg-series-3/15 text-series-3',
  str: 'bg-series-4/15 text-series-4',
  enum: 'bg-series-1/15 text-series-1',
};

export function TypeChip({
  type,
  className,
}: {
  type: QuestionType;
  className?: string | undefined;
}) {
  return (
    <span
      className={cn(
        'inline-flex h-6 items-center rounded-md px-1.5 font-mono text-[0.7rem] font-bold tracking-wide uppercase',
        TYPE_TONE[type],
        className,
      )}
    >
      {TYPE_META[type].short}
    </span>
  );
}

interface Props {
  index: number;
  count: number;
  expanded: boolean;
  onToggle: () => void;
  onMove: (to: number) => void;
  onRemove: () => void;
}

export function QuestionCard({ index, count, expanded, onToggle, onMove, onRemove }: Props) {
  const { control, register, setValue, getValues, formState } = useFormContext<TopicDraft>();
  const base = `questions.${index}` as const;
  const q = useWatch({ control, name: base });
  const err = (field: string) => fieldError(formState.errors, `${base}.${field}`);
  const hasErrors =
    fieldError(formState.errors, base) !== undefined || hasNestedError(formState.errors, index);

  const labelReg = register(`${base}.label`, {
    onChange: (e: { target: { value: string } }) => {
      const cur = getValues(base);
      if (cur.keyEdited || cur.locked) return;
      const taken = getValues('questions')
        .filter((_, j) => j !== index)
        .map((x) => x.key);
      const label = e.target.value;
      setValue(`${base}.key`, label.trim() ? uniqueKey(toSnakeKey(label), taken) : '', {
        shouldValidate: formState.isSubmitted,
      });
    },
  });
  const keyReg = register(`${base}.key`, { onChange: () => setValue(`${base}.keyEdited`, true) });

  const numeric = q.type === 'int' || q.type === 'double';

  return (
    <div
      className={cn(
        'rounded-card border bg-surface shadow-card transition-colors',
        hasErrors ? 'border-danger/60' : expanded ? 'border-line-strong' : 'border-line',
      )}
    >
      <div className="flex items-center gap-1 py-1.5 pr-1.5 pl-3">
        <button
          type="button"
          onClick={onToggle}
          aria-expanded={expanded}
          className="flex min-h-11 min-w-0 flex-1 items-center gap-2.5 text-left"
        >
          <span className="w-5 shrink-0 font-mono text-xs text-muted">{index + 1}</span>
          <TypeChip type={q.type} />
          <span className="min-w-0 flex-1">
            <span className={cn('block truncate font-semibold', !q.label && 'text-muted')}>
              {q.label || 'Untitled question'}
            </span>
            {!expanded ? (
              <span className="block truncate font-mono text-xs text-muted">{q.key || '—'}</span>
            ) : null}
          </span>
          {hasErrors ? <Icon name="alert" className="size-4 text-danger" /> : null}
          {q.locked ? (
            <Badge className="max-sm:hidden">published</Badge>
          ) : (
            <Badge tone="accent" className="max-sm:hidden">
              new
            </Badge>
          )}
        </button>
        <IconButton
          label="Move up"
          size="sm"
          disabled={index === 0}
          onClick={() => onMove(index - 1)}
        >
          <Icon name="up" className="size-4.5" />
        </IconButton>
        <IconButton
          label="Move down"
          size="sm"
          disabled={index === count - 1}
          onClick={() => onMove(index + 1)}
        >
          <Icon name="down" className="size-4.5" />
        </IconButton>
        <IconButton
          label="Remove question"
          size="sm"
          onClick={onRemove}
          disabled={count === 1}
          className="hover:bg-danger-soft hover:text-danger"
        >
          <Icon name="trash" className="size-4.5" />
        </IconButton>
      </div>

      {expanded ? (
        <div className="flex flex-col gap-4 border-t border-dashed border-line p-4">
          {fieldError(formState.errors, base) ? (
            <p
              role="alert"
              className="rounded-xl bg-danger-soft px-3 py-2 text-sm font-medium text-danger"
            >
              {fieldError(formState.errors, base)}
            </p>
          ) : null}
          <Field label="Question" error={err('label')}>
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                placeholder={placeholderFor(q.type)}
               
                {...labelReg}
              />
            )}
          </Field>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Key"
              error={err('key')}
              hint={
                q.locked
                  ? 'Published keys never change'
                  : q.keyEdited
                    ? 'Edited by hand'
                    : 'Follows the question text'
              }
              aside={q.locked ? <Icon name="check" className="size-3.5 text-muted" /> : null}
            >
              {({ id, describedBy, invalid }) => (
                <Input
                  id={id}
                  aria-describedby={describedBy}
                  aria-invalid={invalid || undefined}
                  readOnly={q.locked}
                  autoCapitalize="none"
                  autoCorrect="off"
                  spellCheck={false}
                  className="font-mono read-only:bg-sunken read-only:text-muted"
                  {...keyReg}
                />
              )}
            </Field>
            <Field
              label="Type"
              hint={q.locked ? 'Types are fixed once published' : TYPE_META[q.type].hint}
            >
              {({ id }) => (
                <div
                  id={id}
                  className="flex h-12 items-center gap-2 rounded-xl border border-line bg-sunken px-3.5 text-muted"
                >
                  <TypeChip type={q.type} />
                  {TYPE_META[q.type].label}
                </div>
              )}
            </Field>
          </div>
          <Field label="Help text" optional error={err('help_text')}>
            {({ id, describedBy }) => (
              <Textarea
                id={id}
                aria-describedby={describedBy}
                rows={2}
                className="min-h-0"
                placeholder="Shown under the question"
                {...register(`${base}.help_text`)}
              />
            )}
          </Field>
          <Checkbox
            label="Required"
            hint="Must be answered to save an entry"
            {...register(`${base}.required`)}
          />

          {numeric ? (
            <div
              className={cn(
                'grid gap-3',
                q.type === 'double' ? 'grid-cols-2 sm:grid-cols-4' : 'grid-cols-3',
              )}
            >
              <NumField label="Min" error={err('min')} {...register(`${base}.min`, { deps: [`${base}.max`] })} />
              <NumField label="Max" error={err('max')} {...register(`${base}.max`, { deps: [`${base}.min`] })} />
              {q.type === 'double' ? (
                <NumField
                  label="Decimals"
                  error={err('decimals')}
                  {...register(`${base}.decimals`)}
                />
              ) : null}
              <Field label="Unit" optional error={err('unit')}>
                {({ id, describedBy }) => (
                  <Input
                    id={id}
                    aria-describedby={describedBy}
                    placeholder="kg, h…"
                    {...register(`${base}.unit`)}
                  />
                )}
              </Field>
            </div>
          ) : null}

          {q.type === 'str' ? (
            <>
              <div className="grid grid-cols-2 gap-3">
                <NumField
                  label="Min length"
                  error={err('min_length')}
                  {...register(`${base}.min_length`, { deps: [`${base}.max_length`] })}
                />
                <NumField
                  label="Max length"
                  error={err('max_length')}
                  {...register(`${base}.max_length`, { deps: [`${base}.min_length`] })}
                />
              </div>
              <Checkbox
                label="Multiline"
                hint="Show a text area instead of a single line"
                {...register(`${base}.multiline`)}
              />
            </>
          ) : null}

          {q.type === 'enum' ? <OptionsEditor index={index} /> : null}
        </div>
      ) : null}
    </div>
  );
}

function placeholderFor(type: QuestionType): string {
  switch (type) {
    case 'int':
      return 'e.g. Glasses of water';
    case 'double':
      return 'e.g. Hours slept';
    case 'str':
      return 'e.g. What went well?';
    case 'enum':
      return 'e.g. How do you feel?';
  }
}

function NumField({
  label,
  error,
  ...rest
}: { label: string; error: string | undefined } & React.ComponentProps<'input'>) {
  return (
    <Field label={label} error={error}>
      {({ id, describedBy, invalid }) => (
        <Input
          id={id}
          inputMode="decimal"
          autoComplete="off"
          aria-describedby={describedBy}
          aria-invalid={invalid || undefined}
          className="font-mono"
          placeholder="—"
          {...rest}
        />
      )}
    </Field>
  );
}

function hasNestedError(errors: unknown, index: number): boolean {
  if (typeof errors !== 'object' || errors === null) return false;
  const qs = (errors as { questions?: unknown }).questions;
  if (typeof qs !== 'object' || qs === null) return false;
  const e = (qs as Record<number, unknown>)[index];
  return typeof e === 'object' && e !== null && Object.keys(e).length > 0;
}
