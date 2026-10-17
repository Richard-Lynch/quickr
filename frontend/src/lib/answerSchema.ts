/**
 * Dynamic zod schema for answering a topic version's questions.
 *
 * Form state is what inputs produce: a string per question ('' = left blank), or a
 * `string[]` of option values for multi-select enums ([] = nothing picked). The schema
 * validates the same rules the backend enforces in `services/answers.py` and transforms
 * into the API's answer map (`number | string | string[] | null` per key).
 */
import { z } from 'zod';

import type { EntryOut } from '../client';
import { activeOptions, isMultiEnum, type EnumQuestionOutput, type Question } from './questions';
import { charCount } from './text';

export type AnswerValue = number | string | string[] | null;
/** Raw input for one question. */
export type AnswerInput = string | string[];
export type AnswerFormValues = Record<string, AnswerInput>;
export type AnswerMap = Record<string, AnswerValue>;

export interface AnswerSchemaOptions {
  /**
   * key -> archived enum values that are still accepted (editing an entry that already
   * holds them). Mirrors `allowed_archived` on the backend.
   */
  allowArchived?: Readonly<Record<string, readonly string[]>>;
}

const INT_RE = /^[+-]?\d+$/;
const NUM_RE = /^[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?$/;

export function parseNumberInput(raw: string): number | null {
  const s = raw.trim();
  if (!NUM_RE.test(s)) return null;
  const n = Number(s.replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

type Ctx = z.core.$RefinementCtx<AnswerInput | undefined>;

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
  if (min !== null && n < min) return issue(ctx, `Must be at least ${String(min)}${u}`);
  if (max !== null && n > max) return issue(ctx, `Must be at most ${String(max)}${u}`);
  return n;
}

const options = (n: number) => `${n} option${n === 1 ? '' : 's'}`;

/** Selection limits of a multi-select question as the server applies them. */
export function selectionBounds(q: EnumQuestionOutput): { min: number; max: number | null } {
  return {
    min: Math.max(q.required ? 1 : 0, q.min_selected ?? 0),
    max: q.max_selected ?? null,
  };
}

/** "Pick 1–3", "Pick at least 2", "Pick any" — shown next to multi-select chips. */
export function selectionHint(q: EnumQuestionOutput): string {
  const { min, max } = selectionBounds(q);
  if (max !== null && min === max) return `Pick ${String(min)}`;
  if (max !== null && min > 0) return `Pick ${String(min)}–${String(max)}`;
  if (max !== null) return `Pick up to ${String(max)}`;
  if (min > 1) return `Pick at least ${String(min)}`;
  return 'Pick any';
}

function parseMulti(
  q: EnumQuestionOutput,
  raw: AnswerInput | undefined,
  allowed: readonly string[],
  ctx: Ctx,
): AnswerValue {
  const picked = (Array.isArray(raw) ? raw : raw ? [raw] : []).map((v) => v.trim()).filter(Boolean);
  const unique = [...new Set(picked)];
  if (unique.length === 0) {
    if (q.required) return issue(ctx, 'Pick at least one');
    return null;
  }
  for (const v of unique) {
    const option = q.options.find((o) => o.value === v);
    if (!option) return issue(ctx, 'Pick from the options');
    if (option.archived && !allowed.includes(v))
      return issue(ctx, `“${option.label}” has been retired`);
  }
  const { min, max } = selectionBounds(q);
  if (unique.length < min) return issue(ctx, `Pick at least ${options(min)}`);
  if (max !== null && unique.length > max) return issue(ctx, `Pick at most ${options(max)}`);
  // Option order, like the server stores it.
  const order = new Map(q.options.map((o, i) => [o.value, i]));
  return unique.sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0));
}

export function answerFieldSchema(
  q: Question,
  opts: AnswerSchemaOptions = {},
): z.ZodType<AnswerValue, AnswerInput | undefined> {
  const allowed = opts.allowArchived?.[q.key] ?? [];
  return z
    .union([z.string(), z.array(z.string())])
    .optional()
    .transform((raw, ctx): AnswerValue => {
      if (q.type === 'enum' && q.multiple) return parseMulti(q, raw, allowed, ctx);
      const value = (Array.isArray(raw) ? (raw[0] ?? '') : (raw ?? '')).trim();
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
          // Code points, like the server (and iOS): an emoji is one character.
          const count = charCount(value);
          if (count < q.min_length)
            return issue(ctx, `At least ${q.min_length} characters (${count} so far)`);
          if (count > q.max_length)
            return issue(ctx, `At most ${q.max_length} characters (${count} entered)`);
          return value;
        }
        case 'enum': {
          const option = q.options.find((o) => o.value === value);
          if (!option) return issue(ctx, 'Pick one of the options');
          if (option.archived && !allowed.includes(value)) {
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
  const shape: Record<string, z.ZodType<AnswerValue, AnswerInput | undefined>> = {};
  for (const q of questions) shape[q.key] = answerFieldSchema(q, opts);
  // Fields tolerate `undefined` (unregistered inputs), but forms always supply
  // values — expose the stricter input type so it lines up with RHF values.
  return z.object(shape) as unknown as z.ZodType<AnswerMap, AnswerFormValues>;
}

/** The blank input for one question. */
export function emptyInput(q: Question): AnswerInput {
  return isMultiEnum(q) ? [] : '';
}

/** Whether an input holds anything. */
export function hasInput(v: AnswerInput | undefined): boolean {
  return Array.isArray(v) ? v.length > 0 : (v ?? '').trim() !== '';
}

/** Blank form state for a set of questions. */
export function emptyAnswerValues(questions: readonly Question[]): AnswerFormValues {
  return Object.fromEntries(questions.map((q) => [q.key, emptyInput(q)]));
}

/** Form input for one question from a stored or request-shaped value. */
export function inputFromValue(q: Question, v: unknown): AnswerInput {
  if (isMultiEnum(q)) {
    if (Array.isArray(v)) return v.filter((x): x is string => typeof x === 'string');
    // An old single-select answer, from before the question became multi-select.
    return typeof v === 'string' && v ? [v] : [];
  }
  if (Array.isArray(v)) return typeof v[0] === 'string' ? v[0] : '';
  return typeof v === 'number' || typeof v === 'string' ? String(v) : '';
}

/** Form state pre-filled from an existing entry's answers. */
export function answerValuesFromEntry(
  questions: readonly Question[],
  answers: EntryOut['answers'],
): AnswerFormValues {
  const byKey = new Map(answers.map((a) => [a.key, a.value]));
  return Object.fromEntries(questions.map((q) => [q.key, inputFromValue(q, byKey.get(q.key))]));
}

/** Form state pre-filled from a request-shaped answer map (`{ key: value }`). */
export function answerValuesFromMap(
  questions: readonly Question[],
  answers: Readonly<Record<string, unknown>>,
): AnswerFormValues {
  return Object.fromEntries(questions.map((q) => [q.key, inputFromValue(q, answers[q.key])]));
}

/**
 * Like `answerValuesFromEntry`, but only keeps values that are still valid to log *now*
 * ("Same as last time"): archived options and out-of-range numbers are dropped.
 */
export function reusableValuesFromEntry(
  questions: readonly Question[],
  answers: EntryOut['answers'],
): AnswerFormValues {
  const values = answerValuesFromEntry(questions, answers);
  for (const q of questions) {
    const v = values[q.key];
    if (v === undefined) continue;
    if (q.type === 'enum') {
      const active = new Set(activeOptions(q).map((o) => o.value));
      values[q.key] = Array.isArray(v) ? v.filter((x) => active.has(x)) : active.has(v) ? v : '';
    } else if (!answerFieldSchema(q).safeParse(v).success) {
      values[q.key] = emptyInput(q);
    }
  }
  return values;
}

/** Archived enum values an entry already holds — still valid when editing it. */
export function archivedValuesInEntry(
  questions: readonly Question[],
  answers: EntryOut['answers'],
): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const q of questions) {
    if (q.type !== 'enum') continue;
    const a = answers.find((x) => x.key === q.key);
    if (!a) continue;
    const held = Array.isArray(a.value) ? a.value : typeof a.value === 'string' ? [a.value] : [];
    const archived = held.filter((v) => q.options.some((o) => o.value === v && o.archived));
    if (archived.length > 0) out[q.key] = archived;
  }
  return out;
}

/** Drop unanswered (null) values — the API treats absent and null identically on create. */
export function compactAnswers(answers: AnswerMap): AnswerMap {
  return Object.fromEntries(Object.entries(answers).filter(([, v]) => v !== null));
}

export interface ChipOption {
  value: string;
  label: string;
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
  | { kind: 'chips'; options: ChipOption[] }
  | { kind: 'multi'; options: ChipOption[] }
  | { kind: 'select'; options: ChipOption[] };

/** Max number of options rendered as tappable chips; more use a select. */
export const CHIP_LIMIT = 6;

/** How a question should be rendered as an input. */
export function inputHints(q: Question, keep: readonly string[] = []): InputHints {
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
      const opts = q.options
        .filter((o) => !o.archived || keep.includes(o.value))
        .map((o) => ({ value: o.value, label: o.archived ? `${o.label} (retired)` : o.label }));
      // Multi-select is always chips (a <select multiple> is miserable on phones).
      if (q.multiple) return { kind: 'multi', options: opts };
      return activeOptions(q).length <= CHIP_LIMIT
        ? { kind: 'chips', options: opts }
        : { kind: 'select', options: opts };
    }
  }
}
