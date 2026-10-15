import { useId } from 'react';

import { inputHints, parseNumberInput } from '../../lib/answerSchema';
import type { Question } from '../../lib/questions';
import { cn } from '../ui/cn';
import { Input, Select, Textarea } from '../ui/Field';
import { Icon } from '../ui/Icon';

interface AnswerFieldProps {
  question: Question;
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
  error?: string | undefined;
  /** Keep this (possibly archived) enum value selectable — editing an old session. */
  keepValue?: string | undefined;
  disabled?: boolean;
  inputRef?: (el: HTMLElement | null) => void;
}

/** One question rendered as the right control for its type. */
export function AnswerField({
  question: q,
  value,
  onChange,
  onBlur,
  error,
  keepValue,
  disabled,
  inputRef,
}: AnswerFieldProps) {
  const id = useId();
  const hints = inputHints(q, keepValue);
  const errId = `${id}-err`;
  const helpId = `${id}-help`;
  const describedBy =
    [q.help_text ? helpId : null, error ? errId : null].filter(Boolean).join(' ') || undefined;
  const unit = (q.type === 'int' || q.type === 'double') && q.unit ? q.unit : null;
  const isGroup = hints.kind === 'chips';

  const labelEl = (
    <span className="flex items-baseline gap-2">
      <span className="text-[1.05rem] leading-snug font-semibold">{q.label}</span>
      {!q.required ? <span className="text-xs font-medium text-muted">optional</span> : null}
    </span>
  );

  return (
    <div
      className="flex flex-col gap-2"
      role={isGroup ? 'radiogroup' : undefined}
      aria-labelledby={isGroup ? `${id}-label` : undefined}
      aria-describedby={isGroup ? describedBy : undefined}
    >
      {isGroup ? <span id={`${id}-label`}>{labelEl}</span> : <label htmlFor={id}>{labelEl}</label>}
      {q.help_text ? (
        <p id={helpId} className="-mt-1 text-sm text-muted">
          {q.help_text}
        </p>
      ) : null}

      {hints.kind === 'number' ? (
        <NumberInput
          id={id}
          value={value}
          onChange={onChange}
          {...(onBlur ? { onBlur } : {})}
          step={hints.step}
          min={hints.min}
          max={hints.max}
          inputMode={hints.inputMode}
          unit={unit}
          invalid={Boolean(error)}
          describedBy={describedBy}
          disabled={disabled ?? false}
          inputRef={inputRef}
          integer={q.type === 'int'}
        />
      ) : hints.kind === 'text' ? (
        hints.multiline ? (
          <Textarea
            id={id}
            ref={inputRef}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onBlur={onBlur}
            maxLength={hints.maxLength}
            aria-invalid={error ? true : undefined}
            aria-describedby={describedBy}
            disabled={disabled}
            rows={3}
          />
        ) : (
          <Input
            id={id}
            ref={inputRef}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onBlur={onBlur}
            maxLength={hints.maxLength}
            aria-invalid={error ? true : undefined}
            aria-describedby={describedBy}
            disabled={disabled}
            enterKeyHint="next"
          />
        )
      ) : hints.kind === 'chips' ? (
        <div
          className={cn(
            'grid gap-2',
            hints.options.length <= 2
              ? 'grid-cols-2'
              : hints.options.length === 4
                ? 'grid-cols-2 sm:grid-cols-4'
                : 'grid-cols-2 sm:grid-cols-3',
          )}
        >
          {hints.options.map((o, i) => {
            const selected = value === o.value;
            return (
              <button
                key={o.value}
                type="button"
                role="radio"
                aria-checked={selected}
                disabled={disabled}
                ref={i === 0 ? inputRef : undefined}
                onClick={() => onChange(selected && !q.required ? '' : o.value)}
                onBlur={onBlur}
                className={cn(
                  'flex min-h-13 items-center justify-center gap-2 rounded-2xl border-2 px-3 py-2 text-center text-[0.95rem] leading-tight font-semibold transition-[background-color,border-color,color,transform] active:scale-[0.97]',
                  selected
                    ? 'border-accent bg-accent text-on-accent shadow-card'
                    : 'border-line-strong bg-surface text-ink hover:border-ink/40',
                  error && !selected ? 'border-danger/60' : null,
                  hints.options.length % 2 === 1 &&
                    i === hints.options.length - 1 &&
                    hints.options.length <= 3
                    ? 'col-span-2 sm:col-span-1'
                    : null,
                )}
              >
                {selected ? <Icon name="check" className="size-4" strokeWidth={3} /> : null}
                {o.label}
              </button>
            );
          })}
        </div>
      ) : (
        <Select
          id={id}
          ref={inputRef}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onBlur={onBlur}
          aria-invalid={error ? true : undefined}
          aria-describedby={describedBy}
          disabled={disabled}
        >
          <option value="">{q.required ? 'Choose…' : '— none —'}</option>
          {hints.options.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </Select>
      )}

      {error ? (
        <p id={errId} role="alert" className="text-sm font-medium text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
}

interface NumberInputProps {
  id: string;
  value: string;
  onChange: (v: string) => void;
  onBlur?: () => void;
  step: string;
  min: number | undefined;
  max: number | undefined;
  inputMode: 'numeric' | 'decimal' | 'text';
  unit: string | null;
  invalid: boolean;
  describedBy: string | undefined;
  disabled: boolean;
  integer: boolean;
  inputRef: ((el: HTMLElement | null) => void) | undefined;
}

function decimalsOf(step: string): number {
  const i = step.indexOf('.');
  return i === -1 ? 0 : step.length - i - 1;
}

/** Big numeric input with −/+ steppers sized for thumbs. */
function NumberInput({
  id,
  value,
  onChange,
  onBlur,
  step,
  min,
  max,
  inputMode,
  unit,
  invalid,
  describedBy,
  disabled,
  integer,
  inputRef,
}: NumberInputProps) {
  const stepN = step === 'any' ? 1 : Number(step);
  const places = step === 'any' ? 0 : decimalsOf(step);
  const current = parseNumberInput(value);

  const bump = (dir: 1 | -1) => {
    let base = current;
    if (base === null) base = dir === 1 ? (min ?? 0) : (max ?? min ?? 0);
    else base = base + dir * stepN;
    if (min !== undefined) base = Math.max(min, base);
    if (max !== undefined) base = Math.min(max, base);
    onChange(integer ? String(Math.round(base)) : base.toFixed(places));
  };

  const range =
    min !== undefined && max !== undefined
      ? `${min}–${max}`
      : min !== undefined
        ? `≥ ${min}`
        : max !== undefined
          ? `≤ ${max}`
          : null;

  return (
    <div className="flex items-stretch gap-2">
      <button
        type="button"
        aria-label="Decrease"
        tabIndex={-1}
        disabled={disabled || (current !== null && min !== undefined && current <= min)}
        onClick={() => bump(-1)}
        className="grid w-13 shrink-0 place-items-center rounded-xl border border-line-strong bg-surface text-2xl font-semibold text-ink-soft active:scale-95 active:bg-sunken disabled:opacity-35"
      >
        −
      </button>
      <div className="relative min-w-0 flex-1">
        <input
          id={id}
          ref={inputRef}
          type="text"
          inputMode={inputMode}
          autoComplete="off"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onBlur={onBlur}
          aria-invalid={invalid || undefined}
          aria-describedby={describedBy}
          disabled={disabled}
          placeholder={range ?? (integer ? '0' : '0.0')}
          enterKeyHint="next"
          className={cn(
            'h-13 w-full rounded-xl border border-line-strong bg-surface px-4 text-center font-mono text-xl font-semibold tabular outline-none placeholder:font-sans placeholder:text-base placeholder:font-normal placeholder:text-muted/70 focus:border-accent focus:ring-3 focus:ring-accent/20 aria-invalid:border-danger',
            unit ? 'pr-14' : null,
          )}
        />
        {unit ? (
          <span className="pointer-events-none absolute top-1/2 right-4 -translate-y-1/2 text-sm font-medium text-muted">
            {unit}
          </span>
        ) : null}
      </div>
      <button
        type="button"
        aria-label="Increase"
        tabIndex={-1}
        disabled={disabled || (current !== null && max !== undefined && current >= max)}
        onClick={() => bump(1)}
        className="grid w-13 shrink-0 place-items-center rounded-xl border border-line-strong bg-surface text-2xl font-semibold text-ink-soft active:scale-95 active:bg-sunken disabled:opacity-35"
      >
        +
      </button>
    </div>
  );
}
