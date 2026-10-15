import { useId } from 'react';

import {
  inputHints,
  parseNumberInput,
  selectionBounds,
  selectionHint,
  type AnswerInput,
  type ChipOption,
} from '../../lib/answerSchema';
import type { EnumQuestionOutput, Question } from '../../lib/questions';
import { cn } from '../ui/cn';
import { Input, Select, Textarea } from '../ui/Field';
import { Icon } from '../ui/Icon';

interface AnswerFieldProps {
  question: Question;
  value: AnswerInput;
  onChange: (value: AnswerInput) => void;
  onBlur?: () => void;
  error?: string | undefined;
  /** Keep these (possibly archived) enum values selectable — editing an old entry. */
  keepValues?: readonly string[] | undefined;
  disabled?: boolean;
  inputRef?: (el: HTMLElement | null) => void;
}

const asText = (v: AnswerInput): string => (Array.isArray(v) ? (v[0] ?? '') : v);
const asList = (v: AnswerInput): string[] => (Array.isArray(v) ? v : v ? [v] : []);

/** One question rendered as the right control for its type. */
export function AnswerField({
  question: q,
  value,
  onChange,
  onBlur,
  error,
  keepValues,
  disabled,
  inputRef,
}: AnswerFieldProps) {
  const id = useId();
  const hints = inputHints(q, keepValues);
  const errId = `${id}-err`;
  const helpId = `${id}-help`;
  const describedBy =
    [q.help_text ? helpId : null, error ? errId : null].filter(Boolean).join(' ') || undefined;
  const unit = (q.type === 'int' || q.type === 'double') && q.unit ? q.unit : null;
  const isGroup = hints.kind === 'chips' || hints.kind === 'multi';
  const text = asText(value);

  const labelEl = (
    <span className="flex items-baseline gap-2">
      <span className="text-[1.05rem] leading-snug font-semibold">{q.label}</span>
      {!q.required ? <span className="text-xs font-medium text-muted">optional</span> : null}
      {hints.kind === 'multi' && q.type === 'enum' ? (
        <MultiCount question={q} count={asList(value).length} />
      ) : null}
    </span>
  );

  return (
    <div
      className="flex flex-col gap-2"
      role={hints.kind === 'chips' ? 'radiogroup' : hints.kind === 'multi' ? 'group' : undefined}
      aria-labelledby={isGroup ? `${id}-label` : undefined}
      aria-describedby={isGroup ? describedBy : undefined}
      aria-invalid={isGroup && error ? true : undefined}
      aria-required={isGroup && q.required ? true : undefined}
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
          value={text}
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
            value={text}
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
            value={text}
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
        <ChipGrid count={hints.options.length}>
          {hints.options.map((o, i) => {
            const selected = text === o.value;
            return (
              <Chip
                key={o.value}
                option={o}
                role="radio"
                selected={selected}
                invalid={Boolean(error)}
                disabled={disabled}
                wide={
                  hints.options.length % 2 === 1 &&
                  i === hints.options.length - 1 &&
                  hints.options.length <= 3
                }
                inputRef={i === 0 ? inputRef : undefined}
                onBlur={onBlur}
                onClick={() => onChange(selected && !q.required ? '' : o.value)}
              />
            );
          })}
        </ChipGrid>
      ) : hints.kind === 'multi' && q.type === 'enum' ? (
        <MultiChips
          question={q}
          options={hints.options}
          value={asList(value)}
          onChange={onChange}
          onBlur={onBlur}
          invalid={Boolean(error)}
          disabled={disabled}
          inputRef={inputRef}
        />
      ) : (
        <Select
          id={id}
          ref={inputRef}
          value={text}
          onChange={(e) => onChange(e.target.value)}
          onBlur={onBlur}
          aria-invalid={error ? true : undefined}
          aria-describedby={describedBy}
          disabled={disabled}
        >
          <option value="">{q.required ? 'Choose…' : '— none —'}</option>
          {hints.kind === 'select'
            ? hints.options.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))
            : null}
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

function ChipGrid({ count, children }: { count: number; children: React.ReactNode }) {
  return (
    <div
      className={cn(
        'grid gap-2',
        count <= 2
          ? 'grid-cols-2'
          : count === 4
            ? 'grid-cols-2 sm:grid-cols-4'
            : 'grid-cols-2 sm:grid-cols-3',
      )}
    >
      {children}
    </div>
  );
}

function Chip({
  option,
  role,
  selected,
  invalid,
  disabled,
  dimmed,
  wide,
  inputRef,
  onBlur,
  onClick,
}: {
  option: ChipOption;
  role: 'radio' | 'checkbox';
  selected: boolean;
  invalid: boolean;
  disabled?: boolean | undefined;
  /** At the selection limit: still focusable (and announced), but visibly unavailable. */
  dimmed?: boolean;
  wide?: boolean;
  inputRef?: ((el: HTMLElement | null) => void) | undefined;
  onBlur?: (() => void) | undefined;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role={role}
      aria-checked={selected}
      aria-disabled={dimmed ? true : undefined}
      disabled={disabled}
      ref={inputRef}
      onClick={onClick}
      onBlur={onBlur}
      className={cn(
        'flex min-h-13 items-center justify-center gap-2 rounded-2xl border-2 px-3 py-2 text-center text-[0.95rem] leading-tight font-semibold transition-transform active:scale-[0.97]',
        selected
          ? 'border-accent bg-accent text-on-accent shadow-card'
          : 'border-line-strong bg-surface text-ink hover:border-ink/40',
        invalid && !selected ? 'border-danger/60' : null,
        dimmed ? 'opacity-45' : null,
        wide ? 'col-span-2 sm:col-span-1' : null,
      )}
    >
      {selected ? <Icon name="check" className="size-4" strokeWidth={3} /> : null}
      {option.label}
    </button>
  );
}

function MultiCount({ question: q, count }: { question: EnumQuestionOutput; count: number }) {
  return (
    <span
      className="ml-auto shrink-0 font-mono text-xs font-medium text-muted tabular"
      aria-live="polite"
    >
      {count > 0 ? `${String(count)} selected · ` : ''}
      {selectionHint(q).toLowerCase()}
    </span>
  );
}

/** Multi-select: chips toggle on/off (checkbox semantics), the limit greys out the rest. */
function MultiChips({
  question: q,
  options,
  value,
  onChange,
  onBlur,
  invalid,
  disabled,
  inputRef,
}: {
  question: EnumQuestionOutput;
  options: ChipOption[];
  value: string[];
  onChange: (v: string[]) => void;
  onBlur?: (() => void) | undefined;
  invalid: boolean;
  disabled?: boolean | undefined;
  inputRef?: ((el: HTMLElement | null) => void) | undefined;
}) {
  const { max } = selectionBounds(q);
  const full = max !== null && value.length >= max;
  const order = new Map(q.options.map((o, i) => [o.value, i]));
  return (
    <ChipGrid count={options.length}>
      {options.map((o, i) => {
        const selected = value.includes(o.value);
        return (
          <Chip
            key={o.value}
            option={o}
            role="checkbox"
            selected={selected}
            invalid={invalid}
            disabled={disabled}
            dimmed={full && !selected}
            wide={options.length % 2 === 1 && i === options.length - 1 && options.length <= 3}
            inputRef={i === 0 ? inputRef : undefined}
            onBlur={onBlur}
            onClick={() => {
              if (selected) onChange(value.filter((v) => v !== o.value));
              else if (!full)
                onChange(
                  [...value, o.value].sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0)),
                );
            }}
          />
        );
      })}
    </ChipGrid>
  );
}
export interface NumberInputProps {
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
export function NumberInput({
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
