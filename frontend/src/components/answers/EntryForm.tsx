import { zodResolver } from '@hookform/resolvers/zod';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Controller, useForm, useWatch, type Control, type UseFormReturn } from 'react-hook-form';
import { z } from 'zod';

import { applyFieldErrors, mapApiError, type FieldError } from '../../api/errors';
import { useLimits } from '../../api/limits';
import type { Limits } from '../../client';
import {
  buildAnswerSchema,
  hasInput,
  inputHints,
  type AnswerFormValues,
  type AnswerMap,
} from '../../lib/answerSchema';
import { capturedAtSchema, notesSchema, sourceSchema } from '../../lib/entryMeta';
import { formatWhen } from '../../lib/schedule';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import type { Question } from '../../lib/questions';
import { inputMaxLength } from '../../lib/text';
import { StickyActions } from '../AppShell';
import { Button } from '../ui/Button';
import { Banner, Card } from '../ui/Card';
import { cn } from '../ui/cn';
import { Field, Input, Textarea } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { AnswerField } from './AnswerField';

export interface EntryFormValues {
  answers: AnswerFormValues;
  captured_at: string;
  source: string;
  notes: string;
}

export interface EntryFormOutput {
  answers: AnswerMap;
  captured_at: string;
  source: string;
  notes: string;
}

export function buildEntrySchema(
  questions: readonly Question[],
  allowArchived: Readonly<Record<string, readonly string[]>>,
  limits: Limits,
) {
  return z.object({
    answers: buildAnswerSchema(questions, { allowArchived }),
    captured_at: capturedAtSchema(limits),
    source: sourceSchema(limits),
    notes: notesSchema(limits),
  });
}

/** "Same as last time": answers of the latest entry, still valid to log now. */
export interface Prefill {
  values: AnswerFormValues;
  /** When that entry was captured (ISO). */
  capturedAt: string;
  /** One-line summary, e.g. "Run · 30 min · 6". */
  summary: string;
}

interface EntryFormProps {
  questions: readonly Question[];
  defaultValues: EntryFormValues;
  /** Archived enum values this entry already holds (edit mode). */
  allowArchived?: Readonly<Record<string, readonly string[]>>;
  submitLabel: string;
  /**
   * Throw to have errors mapped onto fields; resolve to finish. Call
   * `allowNavigation()` before navigating away after a successful save.
   */
  onSubmit: (values: EntryFormOutput, helpers: SubmitHelpers) => Promise<void>;
  /** Shown beside the submit button. */
  secondaryAction?: ReactNode | ((helpers: SubmitHelpers) => ReactNode);
  /** Extra content between answers and meta fields. */
  children?: ReactNode;
  /** Values to reset to after a successful submit (log-another flow). */
  resetOnSuccess?: (submitted: EntryFormOutput) => EntryFormValues;
  /** A server error to show on mount (e.g. fixing a rejected offline entry). */
  initialError?: unknown;
  /** Ask before leaving with unsaved input (default on). */
  guardUnsaved?: boolean;
  /** Offer a one-tap "Same as last time" above the questions. */
  prefill?: Prefill | null | undefined;
  /** Focus (and scroll to) the first unanswered question on mount. */
  focusFirstEmpty?: boolean;
  /**
   * Save as soon as this (single-select) question is answered — single-question topics,
   * where the pick *is* the entry. Undo comes from the caller's toast.
   */
  submitOnPick?: string | undefined;
}

export interface SubmitHelpers {
  allowNavigation: () => void;
}

type FormField = `answers.${string}` | 'captured_at' | 'source' | 'notes';

export function EntryForm({
  questions,
  defaultValues,
  allowArchived,
  submitLabel,
  onSubmit,
  secondaryAction,
  children,
  resetOnSuccess,
  initialError,
  guardUnsaved = true,
  prefill,
  focusFirstEmpty = false,
  submitOnPick,
}: EntryFormProps) {
  const limits = useLimits();
  const schema = useMemo(
    () => buildEntrySchema(questions, allowArchived ?? {}, limits),
    [questions, allowArchived, limits],
  );
  const form = useForm<EntryFormValues, unknown, EntryFormOutput>({
    resolver: zodResolver(schema),
    defaultValues,
    mode: 'onTouched',
  });
  const keys = useMemo(() => new Set(questions.map((q) => q.key)), [questions]);
  const resolveField = (path: string): FormField | null => {
    // `answers.factors.2` (one bad option of a multi-select) lands on the question.
    const [root, key] = path.split('.');
    if (root === 'answers' && key && keys.has(key)) return `answers.${key}`;
    if (root === 'captured_at' || root === 'source' || root === 'notes') return root;
    return null;
  };
  const [banner, setBanner] = useState<{ message: string; extra: FieldError[] } | null>(() => {
    if (initialError === undefined) return null;
    const mapped = mapApiError(initialError);
    return {
      message: mapped.message,
      extra: mapped.fieldErrors.filter((fe) => resolveField(fe.path) === null),
    };
  });
  const guard = useUnsavedChangesGuard(guardUnsaved && form.formState.isDirty);

  useEffect(() => {
    if (initialError !== undefined) {
      // Put a rejected entry's server errors back on its fields.
      applyFieldErrors(mapApiError(initialError).fieldErrors, resolveField, form.setError);
      focusFirstError();
      return;
    }
    if (focusFirstEmpty) {
      const first = questions.find((q) => !hasInput(defaultValues.answers[q.key]));
      if (first) focusAnswer(form, first);
    }
    // mount only: later errors come from submits
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const submit = form.handleSubmit(async (values) => {
    setBanner(null);
    try {
      await onSubmit(values, { allowNavigation: guard.allowNavigation });
      if (resetOnSuccess) form.reset(resetOnSuccess(values));
    } catch (err) {
      const mapped = mapApiError(err);
      const unplaced = applyFieldErrors(mapped.fieldErrors, resolveField, form.setError);
      setBanner({ message: mapped.message, extra: unplaced });
      focusFirstError();
    }
  }, focusFirstError);

  /**
   * After a single-select pick, jump to the next unanswered *typed* question (number /
   * text) — synchronously, inside the tap, so mobile keyboards open. Chips don't need it.
   */
  const focusNextInput = (index: number) => {
    const values = form.getValues('answers');
    const next = questions.slice(index + 1).find((x) => !hasInput(values[x.key]));
    if (next && next.type !== 'enum') {
      try {
        form.setFocus(`answers.${next.key}`);
      } catch {
        // not focusable
      }
    }
  };

  const errors = form.formState.errors;
  const metaError = Boolean(errors.captured_at ?? errors.source ?? errors.notes);
  const [detailsOpen, setDetailsOpen] = useState(false);

  return (
    <form
      onSubmit={(e) => void submit(e)}
      onKeyDown={(e) => {
        // Enter ("next" on phone keyboards) in an answer moves on instead of saving early.
        const el = e.target as HTMLElement;
        if (e.key !== 'Enter' || el.tagName !== 'INPUT') return;
        const i = questions.findIndex((q) => el.closest(`#answer-${q.key}`));
        if (i === -1) return;
        const values = form.getValues('answers');
        const next = questions
          .slice(i + 1)
          .find((x) => !hasInput(values[x.key]) && x.type !== 'enum');
        if (next) {
          e.preventDefault();
          form.setFocus(`answers.${next.key}`);
        }
      }}
      noValidate
      className="flex flex-col gap-4"
    >
      {banner ? (
        <Banner title={banner.message}>
          {banner.extra.length > 0 ? (
            <ul className="mt-1 list-disc pl-4">
              {banner.extra.map((e) => (
                <li key={e.path + e.message}>
                  {e.path ? <code className="font-mono text-xs">{e.path}</code> : null} {e.message}
                </li>
              ))}
            </ul>
          ) : null}
        </Banner>
      ) : null}

      {prefill && !submitOnPick && !sameInputs(prefill.values, defaultValues.answers) ? (
        <SameAsLast form={form} prefill={prefill} questions={questions} />
      ) : null}

      <Card className="flex flex-col divide-y divide-dashed divide-line">
        {questions.map((q, i) => (
          <div
            key={q.key}
            id={`answer-${q.key}`}
            className="animate-rise scroll-mt-24 scroll-mb-32 p-4 sm:p-5"
            style={{ animationDelay: `${Math.min(i, 10) * 30}ms` }}
          >
            <Controller
              control={form.control}
              name={`answers.${q.key}`}
              render={({ field, fieldState }) => (
                <AnswerField
                  question={q}
                  value={field.value}
                  onChange={(v) => {
                    field.onChange(v);
                    if (submitOnPick === q.key && hasInput(v)) void submit();
                    else if (focusFirstEmpty && isPick(q) && hasInput(v)) focusNextInput(i);
                  }}
                  onBlur={field.onBlur}
                  inputRef={field.ref}
                  error={fieldState.error?.message}
                  keepValues={allowArchived?.[q.key]}
                />
              )}
            />
          </div>
        ))}
      </Card>
      {submitOnPick ? (
        <p className="-mt-1 px-1 text-sm text-muted">Tap an answer to log it right away.</p>
      ) : null}

      {children}

      <details
        className="group rounded-card border border-line bg-surface/60 open:bg-surface"
        open={detailsOpen || metaError}
        onToggle={(e) => setDetailsOpen(e.currentTarget.open)}
      >
        <summary className="flex min-h-13 cursor-pointer list-none items-center gap-3 px-4 text-sm font-semibold text-ink-soft select-none">
          <Icon name="clock" className="size-4.5 text-muted" />
          <span className="min-w-0 flex-1 truncate">
            Details
            <span className="ml-2 font-normal text-muted">
              <MetaSummary control={form.control} />
            </span>
          </span>
          {metaError ? <Icon name="alert" className="size-4 text-danger" /> : null}
          <Icon name="chevronDown" className="size-4 transition-transform group-open:rotate-180" />
        </summary>
        <div className="grid gap-4 px-4 pt-1 pb-4 sm:grid-cols-2">
          <Field label="Captured at" error={errors.captured_at?.message}>
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                type="datetime-local"
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                {...form.register('captured_at')}
              />
            )}
          </Field>
          <Field label="Source" hint="Remembered on this device" error={errors.source?.message}>
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                autoCapitalize="none"
                autoComplete="off"
                maxLength={inputMaxLength(limits.max_source_length)}
                list="quickr-sources"
                {...form.register('source')}
              />
            )}
          </Field>
          <datalist id="quickr-sources">
            <option value="phone" />
            <option value="tablet" />
            <option value="desktop" />
            <option value="watch" />
          </datalist>
          <Field label="Notes" optional className="sm:col-span-2" error={errors.notes?.message}>
            {({ id, describedBy, invalid }) => (
              <Textarea
                id={id}
                rows={2}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                {...form.register('notes')}
              />
            )}
          </Field>
        </div>
      </details>

      <StickyActions>
        {typeof secondaryAction === 'function'
          ? secondaryAction({ allowNavigation: guard.allowNavigation })
          : secondaryAction}
        <Button
          type="submit"
          variant="primary"
          size="lg"
          className="flex-1 sm:flex-none"
          loading={form.formState.isSubmitting}
          icon={<Icon name="check" strokeWidth={2.6} />}
        >
          {submitLabel}
        </Button>
      </StickyActions>
      {guard.dialog}
    </form>
  );
}

/** One tap fills every answer with the previous entry's; a second tap undoes it. */
function SameAsLast({
  form,
  prefill,
  questions,
}: {
  form: UseFormReturn<EntryFormValues, unknown, EntryFormOutput>;
  prefill: Prefill;
  questions: readonly Question[];
}) {
  const [before, setBefore] = useState<AnswerFormValues | null>(null);
  const applied = before !== null;
  const apply = () => {
    const current = form.getValues('answers');
    setBefore(current);
    for (const q of questions) {
      const v = prefill.values[q.key];
      if (v !== undefined)
        form.setValue(`answers.${q.key}`, v, { shouldDirty: true, shouldValidate: true });
    }
  };
  const undo = () => {
    if (!before) return;
    for (const q of questions) {
      const v = before[q.key];
      if (v !== undefined) form.setValue(`answers.${q.key}`, v, { shouldDirty: true });
    }
    form.clearErrors('answers');
    setBefore(null);
  };
  return (
    <button
      type="button"
      onClick={applied ? undo : apply}
      aria-pressed={applied}
      className={cn(
        'flex min-h-14 w-full items-center gap-3 rounded-card border px-4 py-2.5 text-left transition-[transform,background-color,border-color] active:scale-[0.99]',
        applied
          ? 'border-accent/50 bg-accent-soft'
          : 'border-dashed border-line-strong bg-surface/70 hover:border-ink/40',
      )}
    >
      <span
        className={cn(
          'grid size-9 shrink-0 place-items-center rounded-full',
          applied ? 'bg-accent text-on-accent' : 'bg-sunken text-ink-soft',
        )}
      >
        <Icon name={applied ? 'check' : 'restore'} className="size-4.5" strokeWidth={2.4} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block font-semibold">
          {applied ? 'Filled in from last time' : 'Same as last time'}
        </span>
        <span className="block truncate text-sm text-muted">
          {prefill.summary} · {formatWhen(prefill.capturedAt)}
        </span>
      </span>
      <span className="shrink-0 text-sm font-semibold text-accent-strong">
        {applied ? 'Undo' : 'Fill'}
      </span>
    </button>
  );
}

function MetaSummary({ control }: { control: Control<EntryFormValues, unknown, EntryFormOutput> }) {
  const [source, capturedAt] = useWatch({ control, name: ['source', 'captured_at'] });
  const when = capturedAt ? capturedAt.replace('T', ' ') : '';
  return <>{[when, source].filter(Boolean).join(' · ') || '—'}</>;
}

/** Whether "Same as last time" would change nothing (e.g. a prefilled number). */
function sameInputs(a: AnswerFormValues, b: AnswerFormValues): boolean {
  return Object.keys(a).every((k) => JSON.stringify(a[k]) === JSON.stringify(b[k]));
}

/** Single-select enum: one tap answers it. */
function isPick(q: Question): boolean {
  return q.type === 'enum' && !q.multiple;
}

/**
 * Bring the first unanswered question into view. Text and number inputs get focus (ready
 * to type); chips are only scrolled to — a focus ring on an unpicked chip reads as
 * "selected".
 */
function focusAnswer(
  form: UseFormReturn<EntryFormValues, unknown, EntryFormOutput>,
  q: Question,
): void {
  window.requestAnimationFrame(() => {
    if (q.type === 'enum' && inputHints(q).kind !== 'select') {
      document.getElementById(`answer-${q.key}`)?.scrollIntoView({ block: 'nearest' });
      return;
    }
    try {
      form.setFocus(`answers.${q.key}`);
    } catch {
      // the field has no focusable element (shouldn't happen)
    }
  });
}

function focusFirstError(): void {
  window.requestAnimationFrame(() => {
    const el = document.querySelector<HTMLElement>('[aria-invalid="true"], [role="alert"]');
    el?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    if (el && 'focus' in el && el.tagName !== 'P') el.focus({ preventScroll: true });
  });
}
