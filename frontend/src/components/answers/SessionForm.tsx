import { zodResolver } from '@hookform/resolvers/zod';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Controller, useForm, useWatch, type Control } from 'react-hook-form';
import { z } from 'zod';

import { applyFieldErrors, mapApiError, type FieldError } from '../../api/errors';
import { zSessionCreate } from '../../client/zod.gen';
import { buildAnswerSchema, type AnswerFormValues, type AnswerMap } from '../../lib/answerSchema';
import { localInputToIso } from '../../lib/dates';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import type { Question } from '../../lib/questions';
import { StickyActions } from '../AppShell';
import { Button } from '../ui/Button';
import { Banner, Card } from '../ui/Card';
import { Field, Input, Textarea } from '../ui/Field';
import { Icon } from '../ui/Icon';
import { AnswerField } from './AnswerField';

export interface SessionFormValues {
  answers: AnswerFormValues;
  captured_at: string;
  source: string;
  notes: string;
}

export interface SessionFormOutput {
  answers: AnswerMap;
  captured_at: string;
  source: string;
  notes: string;
}

function buildSchema(questions: readonly Question[], allowArchived: Record<string, string>) {
  return z.object({
    answers: buildAnswerSchema(questions, { allowArchived }),
    captured_at: z
      .string()
      .transform((v, ctx) => {
        const iso = localInputToIso(v);
        if (iso === null) {
          ctx.addIssue({ code: 'custom', message: 'Pick a date and time' });
          return z.NEVER;
        }
        return iso;
      })
      .pipe(zSessionCreate.shape.captured_at.unwrap().unwrap()),
    source: z
      .string()
      .trim()
      .min(1, 'Where did this come from?')
      .max(100, 'At most 100 characters'),
    notes: z.string().trim().max(5000, 'At most 5000 characters'),
  });
}

interface SessionFormProps {
  questions: readonly Question[];
  defaultValues: SessionFormValues;
  /** Archived enum values this session already holds (edit mode). */
  allowArchived?: Record<string, string>;
  submitLabel: string;
  /**
   * Throw to have errors mapped onto fields; resolve to finish. Call
   * `allowNavigation()` before navigating away after a successful save.
   */
  onSubmit: (values: SessionFormOutput, helpers: SubmitHelpers) => Promise<void>;
  /** Shown beside the submit button. */
  secondaryAction?: ReactNode | ((helpers: SubmitHelpers) => ReactNode);
  /** Extra content between answers and meta fields. */
  children?: ReactNode;
  /** Values to reset to after a successful submit (record-another flow). */
  resetOnSuccess?: (submitted: SessionFormOutput) => SessionFormValues;
  /** A server error to show on mount (e.g. fixing a rejected offline entry). */
  initialError?: unknown;
  /** Ask before leaving with unsaved input (default on). */
  guardUnsaved?: boolean;
}

export interface SubmitHelpers {
  allowNavigation: () => void;
}

type FormField = `answers.${string}` | 'captured_at' | 'source' | 'notes';

export function SessionForm({
  questions,
  defaultValues,
  allowArchived = {},
  submitLabel,
  onSubmit,
  secondaryAction,
  children,
  resetOnSuccess,
  initialError,
  guardUnsaved = true,
}: SessionFormProps) {
  const schema = useMemo(() => buildSchema(questions, allowArchived), [questions, allowArchived]);
  const form = useForm<SessionFormValues, unknown, SessionFormOutput>({
    resolver: zodResolver(schema),
    defaultValues,
    mode: 'onTouched',
  });
  const keys = useMemo(() => new Set(questions.map((q) => q.key)), [questions]);
  const resolveField = (path: string): FormField | null => {
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

  // Put a rejected entry's server errors back on its fields.
  useEffect(() => {
    if (initialError === undefined) return;
    applyFieldErrors(mapApiError(initialError).fieldErrors, resolveField, form.setError);
    focusFirstError();
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

  const errors = form.formState.errors;

  return (
    <form onSubmit={(e) => void submit(e)} noValidate className="flex flex-col gap-5">
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

      <Card className="flex flex-col divide-y divide-dashed divide-line">
        {questions.map((q, i) => (
          <div
            key={q.key}
            className="animate-rise p-4 sm:p-5"
            style={{ animationDelay: `${Math.min(i, 10) * 30}ms` }}
          >
            <Controller
              control={form.control}
              name={`answers.${q.key}`}
              render={({ field, fieldState }) => (
                <AnswerField
                  question={q}
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  inputRef={field.ref}
                  error={fieldState.error?.message}
                  keepValue={allowArchived[q.key]}
                />
              )}
            />
          </div>
        ))}
      </Card>

      {children}

      <details
        className="group rounded-card border border-line bg-surface/60 open:bg-surface"
        open={Boolean(errors.captured_at ?? errors.source ?? errors.notes)}
      >
        <summary className="flex min-h-13 cursor-pointer list-none items-center gap-3 px-4 text-sm font-semibold text-ink-soft select-none">
          <Icon name="clock" className="size-4.5 text-muted" />
          <span className="flex-1">
            When, where & notes
            <span className="ml-2 font-normal text-muted">
              <MetaSummary control={form.control} />
            </span>
          </span>
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

function MetaSummary({
  control,
}: {
  control: Control<SessionFormValues, unknown, SessionFormOutput>;
}) {
  const [source, capturedAt] = useWatch({ control, name: ['source', 'captured_at'] });
  const when = capturedAt ? capturedAt.replace('T', ' ') : '';
  return <>{[when, source].filter(Boolean).join(' · ') || '—'}</>;
}

function focusFirstError(): void {
  window.requestAnimationFrame(() => {
    const el = document.querySelector<HTMLElement>('[aria-invalid="true"], [role="alert"]');
    el?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    if (el && 'focus' in el && el.tagName !== 'P') el.focus({ preventScroll: true });
  });
}
