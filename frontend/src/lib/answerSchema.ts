/**
 * Dynamic zod schema for answering a topic version's questions.
 *
 * Form state is always strings (what inputs produce; '' means "left blank").
 * The schema validates the same rules the backend enforces in
 * `services/answers.py` and transforms into the API's answer map
 * (`number | string | null` per key).
 */
import { z } from 'zod';

import type { SessionOut } from '../client';
import { activeOptions, type Question } from './questions';

export type AnswerValue = number | string | null;
export type AnswerFormValues = Record<string, string>;
export type AnswerMap = Record<string, AnswerValue>;

export interface AnswerSchemaOptions {
  /**
   * key -> archived enum value that is still accepted (editing a session that
   * already holds it). Mirrors `allowed_archived` on the backend.
   */
  allowArchived?: Readonly<Record<string, string>>;
}

const INT_RE = /^[+-]?\d+$/;
const NUM_RE = /^[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?$/;

export function parseNumberInput(raw: string): number | null {
  const s = raw.trim();
  if (!NUM_RE.test(s)) return null;
  const n = Number(s.replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

function fmtBound(n: number): string {
  return String(n);
}

type Ctx = z.core.$RefinementCtx<string | undefined>;

function issue(ctx: Ctx, message: string): typeof z.NEVER {
  ctx.addIssue({ code: 'custom', message });
  return z.NEVER;
}

function checkRange(
  ctx: Ctx,
  n: number,
  min: number | null,
  max: number | null,
  unit: string | null,
): number {
  const u = unit ? ` ${unit}` : '';
  if (min !== null && n < min) return issue(ctx, `Must be at least ${fmtBound(min)}${u}`);
  if (max !== null && n > max) return issue(ctx, `Must be at most ${fmtBound(max)}${u}`);
  return n;
}

export function answerFieldSchema(
  q: Question,
  opts: AnswerSchemaOptions = {},
): z.ZodType<AnswerValue, string | undefined> {
  return z
    .string()
    .optional()
    .transform((raw, ctx): AnswerValue => {
      const value = (raw ?? '').trim();
      if (value === '') {
        if (q.required) return issue(ctx, 'Required');
        return null;
      }
      switch (q.type) {
        case 'int': {
          if (!INT_RE.test(value)) return issue(ctx, 'Enter a whole number');
          const n = Number(value);
          if (!Number.isSafeInteger(n)) return issue(ctx, 'Number is too large');
          return checkRange(ctx, n, q.min, q.max, q.unit);
        }
        case 'double': {
          const n = parseNumberInput(value);
          if (n === null) return issue(ctx, 'Enter a number');
          return checkRange(ctx, n, q.min, q.max, q.unit);
        }
        case 'str': {
          if (value.length < q.min_length)
            return issue(ctx, `At least ${q.min_length} characters (${value.length} so far)`);
          if (value.length > q.max_length)
            return issue(ctx, `At most ${q.max_length} characters (${value.length} entered)`);
          return value;
        }
        case 'enum': {
          const option = q.options.find((o) => o.value === value);
          if (!option) return issue(ctx, 'Pick one of the options');
          if (option.archived && opts.allowArchived?.[q.key] !== value) {
            return issue(ctx, 'That option has been retired');
          }
          return value;
        }
      }
    });
}

/** Build the schema for a whole answer map. Keys are question keys. */
export function buildAnswerSchema(
  questions: readonly Question[],
  opts: AnswerSchemaOptions = {},
): z.ZodType<AnswerMap, AnswerFormValues> {
  const shape: Record<string, z.ZodType<AnswerValue, string | undefined>> = {};
  for (const q of questions) shape[q.key] = answerFieldSchema(q, opts);
  // Fields tolerate `undefined` (unregistered inputs), but forms always supply
  // strings — expose the stricter input type so it lines up with RHF values.
  return z.object(shape) as unknown as z.ZodType<AnswerMap, AnswerFormValues>;
}

/** Blank form state for a set of questions. */
export function emptyAnswerValues(questions: readonly Question[]): AnswerFormValues {
  return Object.fromEntries(questions.map((q) => [q.key, '']));
}

/** Form state pre-filled from an existing session's answers. */
export function answerValuesFromSession(
  questions: readonly Question[],
  answers: SessionOut['answers'],
): AnswerFormValues {
  const byKey = new Map(answers.map((a) => [a.key, a.value]));
  return Object.fromEntries(
    questions.map((q) => {
      const v = byKey.get(q.key);
      return [q.key, v === undefined ? '' : String(v)];
    }),
  );
}

/** Archived enum values a session already holds — still valid when editing it. */
export function archivedValuesInSession(
  questions: readonly Question[],
  answers: SessionOut['answers'],
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const q of questions) {
    if (q.type !== 'enum') continue;
    const a = answers.find((x) => x.key === q.key);
    if (
      a &&
      typeof a.value === 'string' &&
      q.options.some((o) => o.value === a.value && o.archived)
    ) {
      out[q.key] = a.value;
    }
  }
  return out;
}

/** Drop unanswered (null) values — the API treats absent and null identically on create. */
export function compactAnswers(answers: AnswerMap): AnswerMap {
  return Object.fromEntries(Object.entries(answers).filter(([, v]) => v !== null));
}

export type InputHints =
  | {
      kind: 'number';
      inputMode: 'numeric' | 'decimal' | 'text';
      step: string;
      min?: number;
      max?: number;
    }
  | { kind: 'text'; multiline: boolean; maxLength: number }
  | { kind: 'chips'; options: { value: string; label: string }[] }
  | { kind: 'select'; options: { value: string; label: string }[] };

/** Max number of options rendered as tappable chips; more use a select. */
export const CHIP_LIMIT = 6;

/** How a question should be rendered as an input. */
export function inputHints(q: Question, keepValue?: string): InputHints {
  switch (q.type) {
    case 'int':
    case 'double': {
      const negative = q.min === null || q.min < 0;
      const step = q.type === 'int' ? '1' : q.decimals !== null ? String(10 ** -q.decimals) : 'any';
      return {
        kind: 'number',
        // Mobile numeric keypads have no minus key; fall back to text when negatives are allowed.
        inputMode: negative ? 'text' : q.type === 'int' ? 'numeric' : 'decimal',
        step: q.type === 'double' && q.decimals !== null ? Number(step).toFixed(q.decimals) : step,
        ...(q.min !== null ? { min: q.min } : {}),
        ...(q.max !== null ? { max: q.max } : {}),
      };
    }
    case 'str':
      return { kind: 'text', multiline: q.multiline, maxLength: q.max_length };
    case 'enum': {
      const options = q.options
        .filter((o) => !o.archived || o.value === keepValue)
        .map((o) => ({ value: o.value, label: o.archived ? `${o.label} (retired)` : o.label }));
      return activeOptions(q).length <= CHIP_LIMIT
        ? { kind: 'chips', options }
        : { kind: 'select', options };
    }
  }
}
