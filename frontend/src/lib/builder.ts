/**
 * Topic builder: editable draft state <-> API question config.
 *
 * Drafts keep every constraint as a string (straight from inputs) plus a bit of
 * UI bookkeeping (`uid`, `keyEdited`, `locked`). The schema factories below validate a
 * draft with the same rules as the backend (`backend/app/schemas/questions.py`,
 * `api.py`), using the ceilings from `GET /limits`, and transform it into the API
 * shape; each question is finally checked against the generated zod schema for its
 * type so the client can never drift from the OpenAPI contract.
 */
import { z } from 'zod';

import { FALLBACK_LIMITS, patternOf } from '../api/limits';
import type { Limits } from '../client';
import {
  zDoubleQuestionInput,
  zEnumQuestionInput,
  zIntQuestionInput,
  zStrQuestionInput,
} from '../client/zod.gen';
import { parseNumberInput } from './answerSchema';
import type { Question, QuestionInput, QuestionType } from './questions';
import {
  emptyScheduleDraft,
  scheduleFromDraft,
  type ScheduleDraft,
  type ScheduleInput,
} from './schedule';
import { charCount } from './text';

export interface DraftOption {
  uid: string;
  value: string;
  label: string;
  archived: boolean;
  /** Value was typed by hand — stop deriving it from the label. */
  valueEdited: boolean;
  /** Exists in a published version: can be archived, never removed or renamed. */
  locked: boolean;
}

export interface DraftQuestion {
  uid: string;
  type: QuestionType;
  key: string;
  label: string;
  help_text: string;
  required: boolean;
  /** Key was typed by hand — stop deriving it from the label. */
  keyEdited: boolean;
  /** Exists in the published version: key and type are immutable. */
  locked: boolean;
  // numeric
  min: string;
  max: string;
  unit: string;
  decimals: string;
  // str
  min_length: string;
  max_length: string;
  multiline: boolean;
  // enum
  options: DraftOption[];
  multiple: boolean;
  min_selected: string;
  max_selected: string;
  /** Published as multi-select: can never go back to single-select under this key. */
  publishedMultiple: boolean;
}

export interface TopicDraft {
  name: string;
  slug: string;
  slugEdited: boolean;
  description: string;
  questions: DraftQuestion[];
  /** Only used when publishing a new version. */
  change_note: string;
  /** Only used when creating a topic (an existing topic's schedule is edited in settings). */
  schedule: ScheduleDraft;
}

let uidCounter = 0;
export function uid(prefix = 'd'): string {
  uidCounter += 1;
  return `${prefix}${Date.now().toString(36)}${uidCounter.toString(36)}`;
}

const DIACRITICS = /[̀-ͯ]/g;

/** "Hours slept (approx.)" -> "hours_slept_approx". Always matches the key pattern or is ''. */
export function toSnakeKey(label: string): string {
  return label
    .normalize('NFKD')
    .replace(DIACRITICS, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/^[0-9_]+/, '')
    .slice(0, 63)
    .replace(/_+$/, '');
}

/** Mirrors backend `slugify`. */
export function slugify(name: string): string {
  return name
    .normalize('NFKD')
    .replace(DIACRITICS, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
    .replace(/-+$/, '');
}

/** First key based on `base` not present in `taken` (base, base_2, base_3, ...). */
export function uniqueKey(base: string, taken: Iterable<string>): string {
  const used = new Set(taken);
  const root = base || 'question';
  if (!used.has(root)) return root;
  for (let i = 2; ; i++) {
    const suffix = `_${i}`;
    const candidate = root.slice(0, 63 - suffix.length) + suffix;
    if (!used.has(candidate)) return candidate;
  }
}

export function newDraftOption(label = '', taken: Iterable<string> = []): DraftOption {
  const derived = toSnakeKey(label);
  return {
    uid: uid('o'),
    value: label ? uniqueKey(derived || 'option', taken) : '',
    label,
    archived: false,
    valueEdited: false,
    locked: false,
  };
}

export function newDraftQuestion(type: QuestionType): DraftQuestion {
  const options: DraftOption[] = [];
  if (type === 'enum') {
    options.push(newDraftOption('Yes'), newDraftOption('No', ['yes']));
  }
  return {
    uid: uid('q'),
    type,
    key: '',
    label: '',
    help_text: '',
    required: true,
    keyEdited: false,
    locked: false,
    min: '',
    max: '',
    unit: '',
    decimals: type === 'double' ? '1' : '',
    min_length: '0',
    max_length: '500',
    multiline: false,
    options,
    multiple: false,
    min_selected: '',
    max_selected: '',
    publishedMultiple: false,
  };
}

const s = (v: number | null | undefined): string =>
  v === null || v === undefined ? '' : String(v);

/** Draft from a published question. `locked` marks it as existing server-side. */
export function draftFromQuestion(q: Question, locked: boolean): DraftQuestion {
  const base = newDraftQuestion(q.type);
  const common = {
    ...base,
    key: q.key,
    label: q.label,
    help_text: q.help_text ?? '',
    required: q.required,
    keyEdited: true,
    locked,
  };
  switch (q.type) {
    case 'int':
      return { ...common, min: s(q.min), max: s(q.max), unit: q.unit ?? '' };
    case 'double':
      return {
        ...common,
        min: s(q.min),
        max: s(q.max),
        unit: q.unit ?? '',
        decimals: s(q.decimals),
      };
    case 'str':
      return {
        ...common,
        min_length: String(q.min_length),
        max_length: String(q.max_length),
        multiline: q.multiline,
      };
    case 'enum':
      return {
        ...common,
        options: q.options.map((o) => ({
          uid: uid('o'),
          value: o.value,
          label: o.label,
          archived: o.archived,
          valueEdited: true,
          locked,
        })),
        multiple: q.multiple,
        min_selected: s(q.min_selected),
        max_selected: s(q.max_selected),
        publishedMultiple: locked && q.multiple,
      };
  }
}

export function draftFromTopic(topic: {
  name: string;
  slug: string;
  description: string;
  questions: readonly Question[];
}): TopicDraft {
  return {
    name: topic.name,
    slug: topic.slug,
    slugEdited: true,
    change_note: '',
    description: topic.description,
    questions: topic.questions.map((q) => draftFromQuestion(q, true)),
    schedule: emptyScheduleDraft(),
  };
}

/** A new topic starts with no questions: as it is, logging it takes one tap. */
export function emptyTopicDraft(): TopicDraft {
  return {
    name: '',
    slug: '',
    slugEdited: false,
    description: '',
    questions: [],
    change_note: '',
    schedule: emptyScheduleDraft(),
  };
}

/** Apply a label change, deriving the key while it has not been hand-edited. */
export function withLabel(
  q: DraftQuestion,
  label: string,
  takenKeys: Iterable<string>,
): DraftQuestion {
  if (q.keyEdited || q.locked) return { ...q, label };
  return { ...q, label, key: label.trim() ? uniqueKey(toSnakeKey(label), takenKeys) : '' };
}

// ---------------------------------------------------------------------------
// Validation + transformation
// ---------------------------------------------------------------------------

type Path = (string | number)[];
export interface Issue {
  path: Path;
  message: string;
}

const KEY_MESSAGE = 'Use lower_snake_case: a–z, 0–9, _ (start with a letter, max 63)';

export function keyPattern(limits: Limits): RegExp {
  return patternOf(limits.key_pattern, FALLBACK_LIMITS.key_pattern);
}

export function slugPattern(limits: Limits): RegExp {
  return patternOf(limits.slug_pattern, FALLBACK_LIMITS.slug_pattern);
}

function parseConstraint(
  issues: Issue[],
  raw: string,
  field: string,
  { integer, min, max }: { integer?: boolean; min?: number; max?: number } = {},
): number | null | undefined {
  const t = raw.trim();
  if (t === '') return null;
  const n = parseNumberInput(t);
  const fail = (message: string): undefined => {
    issues.push({ path: [field], message });
    return undefined;
  };
  if (n === null) {
    fail('Enter a number');
    return;
  }
  if (integer && !Number.isInteger(n)) {
    fail('Must be a whole number');
    return;
  }
  if (integer && !Number.isSafeInteger(n)) {
    fail('Number is too large');
    return;
  }
  if (min !== undefined && n < min) {
    fail(`Must be at least ${String(min)}`);
    return;
  }
  if (max !== undefined && n > max) {
    fail(`Must be at most ${String(max)}`);
    return;
  }
  return n;
}

function maxLength(issues: Issue[], path: Path, value: string, max: number): void {
  const count = charCount(value);
  if (count > max)
    issues.push({
      path,
      message: `At most ${String(max)} characters (${String(count)} now)`,
    });
}

/** Indices of items equal (after `norm`) to an earlier one. */
function duplicates(items: readonly string[], norm: (s: string) => string = (x) => x): number[] {
  const seen = new Set<string>();
  const out: number[] = [];
  items.forEach((item, i) => {
    const k = norm(item);
    if (!k) return;
    if (seen.has(k)) out.push(i);
    seen.add(k);
  });
  return out;
}

const fold = (v: string) => v.trim().toLocaleLowerCase();

const GENERATED = {
  int: zIntQuestionInput,
  double: zDoubleQuestionInput,
  str: zStrQuestionInput,
  enum: zEnumQuestionInput,
} as const;

/**
 * Validate one draft and convert it to the API's question input shape.
 * Returns the issues (paths relative to the question) or the question.
 */
export function convertDraftQuestion(
  d: DraftQuestion,
  limits: Limits = FALLBACK_LIMITS,
): { ok: true; question: QuestionInput } | { ok: false; issues: Issue[] } {
  const issues: Issue[] = [];
  const key = d.key.trim();
  const label = d.label.trim();
  const helpText = d.help_text.trim();
  const keyRe = keyPattern(limits);
  if (!label) issues.push({ path: ['label'], message: 'Required' });
  maxLength(issues, ['label'], label, limits.max_label_length);
  if (!key) issues.push({ path: ['key'], message: 'Required' });
  else if (!keyRe.test(key)) issues.push({ path: ['key'], message: KEY_MESSAGE });
  maxLength(issues, ['help_text'], helpText, limits.max_help_text_length);

  const common = { key, label, help_text: helpText || null, required: d.required };

  let candidate: Record<string, unknown>;
  switch (d.type) {
    case 'int':
    case 'double': {
      const integer = d.type === 'int';
      const min = parseConstraint(issues, d.min, 'min', { integer });
      const max = parseConstraint(issues, d.max, 'max', { integer });
      if (typeof min === 'number' && typeof max === 'number' && min > max) {
        issues.push({ path: ['max'], message: 'Max must be ≥ min' });
      }
      const unit = d.unit.trim();
      maxLength(issues, ['unit'], unit, limits.max_unit_length);
      candidate = {
        ...common,
        type: d.type,
        min: min ?? null,
        max: max ?? null,
        unit: unit || null,
      };
      if (d.type === 'double') {
        candidate.decimals =
          parseConstraint(issues, d.decimals, 'decimals', {
            integer: true,
            min: 0,
            max: limits.max_decimals,
          }) ?? null;
      }
      break;
    }
    case 'str': {
      const lo = parseConstraint(issues, d.min_length, 'min_length', {
        integer: true,
        min: 0,
        max: limits.max_str_length,
      });
      const hi = parseConstraint(issues, d.max_length, 'max_length', {
        integer: true,
        min: 1,
        max: limits.max_str_length,
      });
      const minLength = lo ?? 0;
      const maxLen = hi ?? 500;
      if (typeof lo !== 'undefined' && typeof hi !== 'undefined' && minLength > maxLen) {
        issues.push({ path: ['max_length'], message: 'Max length must be ≥ min length' });
      }
      candidate = {
        ...common,
        type: 'str',
        min_length: minLength,
        max_length: maxLen,
        multiline: d.multiline,
      };
      break;
    }
    case 'enum': {
      d.options.forEach((o, i) => {
        const value = o.value.trim();
        const optLabel = o.label.trim();
        if (!optLabel) issues.push({ path: ['options', i, 'label'], message: 'Required' });
        maxLength(issues, ['options', i, 'label'], optLabel, limits.max_label_length);
        if (!value) issues.push({ path: ['options', i, 'value'], message: 'Required' });
        else if (!keyRe.test(value))
          issues.push({ path: ['options', i, 'value'], message: KEY_MESSAGE });
      });
      for (const i of duplicates(d.options.map((o) => o.value.trim())))
        issues.push({ path: ['options', i, 'value'], message: 'Another option has this value' });
      for (const i of duplicates(
        d.options.map((o) => o.label),
        fold,
      ))
        issues.push({ path: ['options', i, 'label'], message: 'Another option has this label' });
      const active = d.options.filter((o) => !o.archived).length;
      if (d.options.length === 0) {
        issues.push({ path: ['options'], message: 'Add at least one option' });
      } else if (active === 0) {
        issues.push({ path: ['options'], message: 'At least one option must be active' });
      } else if (d.options.length > limits.max_enum_options) {
        issues.push({
          path: ['options'],
          message: `At most ${String(limits.max_enum_options)} options`,
        });
      }

      let minSel: number | null = null;
      let maxSel: number | null = null;
      if (!d.multiple && d.publishedMultiple) {
        issues.push({
          path: ['multiple'],
          message:
            'Published as multi-select: existing answers are lists, so it can’t become single-select. Add a new question instead.',
        });
      }
      if (d.multiple) {
        const lo = parseConstraint(issues, d.min_selected, 'min_selected', {
          integer: true,
          min: 1,
        });
        const hi = parseConstraint(issues, d.max_selected, 'max_selected', {
          integer: true,
          min: 1,
        });
        minSel = lo ?? null;
        maxSel = hi ?? null;
        if (active > 0) {
          if (minSel !== null && minSel > active)
            issues.push({
              path: ['min_selected'],
              message: `Only ${String(active)} active option${active === 1 ? '' : 's'}`,
            });
          if (maxSel !== null && maxSel > active)
            issues.push({
              path: ['max_selected'],
              message: `Only ${String(active)} active option${active === 1 ? '' : 's'}`,
            });
        }
        if (minSel !== null && maxSel !== null && minSel > maxSel)
          issues.push({ path: ['max_selected'], message: 'Max must be ≥ min' });
      }
      candidate = {
        ...common,
        type: 'enum',
        options: d.options.map((o) => ({
          value: o.value.trim(),
          label: o.label.trim(),
          archived: o.archived,
        })),
        multiple: d.multiple,
        min_selected: minSel,
        max_selected: maxSel,
      };
      break;
    }
  }

  if (issues.length > 0) return { ok: false, issues };

  // Final word goes to the schema generated from the OpenAPI spec.
  const parsed = GENERATED[d.type].safeParse(candidate);
  if (!parsed.success) {
    return {
      ok: false,
      issues: parsed.error.issues.map((i) => ({
        path: i.path.filter((p): p is string | number => typeof p !== 'symbol'),
        message: i.message,
      })),
    };
  }
  // `candidate` is what we send: it passed the generated schema, and unlike
  // `parsed.data` (whose `.nullish()` fields widen to `| undefined`) it is
  // already exact-optional clean — every field is a value or null.
  return { ok: true, question: candidate as QuestionInput };
}

const draftOptionSchema = z.object({
  uid: z.string(),
  value: z.string(),
  label: z.string(),
  archived: z.boolean(),
  valueEdited: z.boolean(),
  locked: z.boolean(),
});

const draftQuestionShape = z.object({
  uid: z.string(),
  type: z.enum(['int', 'double', 'str', 'enum']),
  key: z.string(),
  label: z.string(),
  help_text: z.string(),
  required: z.boolean(),
  keyEdited: z.boolean(),
  locked: z.boolean(),
  min: z.string(),
  max: z.string(),
  unit: z.string(),
  decimals: z.string(),
  min_length: z.string(),
  max_length: z.string(),
  multiline: z.boolean(),
  options: z.array(draftOptionSchema),
  multiple: z.boolean(),
  min_selected: z.string(),
  max_selected: z.string(),
  publishedMultiple: z.boolean(),
});

const scheduleDraftShape = z.object({
  kind: z.enum(['none', 'daily', 'interval']),
  times: z.array(z.object({ value: z.string() })),
  days: z.array(z.number()),
  timezone: z.string(),
  every: z.string(),
  unit: z.enum(['minutes', 'hours', 'days']),
  notify: z.boolean(),
});

/** Draft question -> API question, with issues reported at draft field paths. */
export function makeDraftQuestionSchema(limits: Limits = FALLBACK_LIMITS) {
  return draftQuestionShape.transform((d, ctx): QuestionInput => {
    const r = convertDraftQuestion(d, limits);
    if (r.ok) return r.question;
    for (const i of r.issues) ctx.addIssue({ code: 'custom', message: i.message, path: i.path });
    return z.NEVER;
  });
}

/** Cross-question rules: unique keys, case-insensitive unique labels, at most the limit. No
 *  questions is fine: that topic logs with one tap (a "single" topic). */
export function questionListIssues(
  questions: readonly Pick<DraftQuestion, 'key' | 'label'>[],
  limits: Limits = FALLBACK_LIMITS,
): Issue[] {
  const issues: Issue[] = [];
  if (questions.length > limits.max_questions)
    issues.push({ path: [], message: `At most ${String(limits.max_questions)} questions` });
  for (const i of duplicates(questions.map((q) => q.key.trim())))
    issues.push({ path: [i, 'key'], message: 'Key already used by another question' });
  for (const i of duplicates(
    questions.map((q) => q.label),
    fold,
  ))
    issues.push({ path: [i, 'label'], message: 'Another question has this label' });
  return issues;
}

export function makeQuestionsSchema(limits: Limits = FALLBACK_LIMITS) {
  return z.array(draftQuestionShape).transform((qs, ctx): QuestionInput[] => {
    const issues = questionListIssues(qs, limits);
    const out: QuestionInput[] = [];
    qs.forEach((q, i) => {
      const r = convertDraftQuestion(q, limits);
      if (r.ok) out.push(r.question);
      else issues.push(...r.issues.map((x) => ({ ...x, path: [i, ...x.path] })));
    });
    if (issues.length === 0) return out;
    for (const i of issues) ctx.addIssue({ code: 'custom', message: i.message, path: i.path });
    return z.NEVER;
  });
}

function nameSchema(limits: Limits) {
  return z
    .string()
    .trim()
    .min(1, 'Give the topic a name')
    .refine(
      (v) => charCount(v) <= limits.max_topic_name_length,
      `At most ${String(limits.max_topic_name_length)} characters`,
    );
}

function descriptionSchema(limits: Limits) {
  return z
    .string()
    .trim()
    .refine(
      (v) => charCount(v) <= limits.max_description_length,
      `At most ${String(limits.max_description_length)} characters`,
    );
}

const SLUG_MESSAGE = 'Lowercase letters, digits and dashes (start with a letter or digit, max 64)';

export function makeScheduleSchema(limits: Limits = FALLBACK_LIMITS) {
  return scheduleDraftShape.transform((d, ctx): ScheduleInput | null => {
    const r = scheduleFromDraft(d, limits);
    if (r.ok) return r.schedule;
    for (const i of r.issues) ctx.addIssue({ code: 'custom', message: i.message, path: i.path });
    return z.NEVER;
  });
}

/** Validates a whole topic draft and outputs a `TopicCreate` body. */
export function makeTopicDraftSchema(limits: Limits = FALLBACK_LIMITS) {
  const slugRe = slugPattern(limits);
  return z
    .object({
      name: nameSchema(limits),
      slug: z
        .string()
        .trim()
        .refine((v) => v === '' || slugRe.test(v), SLUG_MESSAGE)
        .transform((v) => (v === '' ? null : v)),
      slugEdited: z.boolean(),
      description: descriptionSchema(limits),
      questions: makeQuestionsSchema(limits),
      change_note: z.string(),
      schedule: makeScheduleSchema(limits),
    })
    .transform(({ name, slug, description, questions, schedule }) => ({
      name,
      slug,
      description,
      questions,
      schedule,
    }));
}

export type TopicDraftOutput = z.output<ReturnType<typeof makeTopicDraftSchema>>;

/** Questions + change note for checking / publishing a new version. */
export function makeVersionDraftSchema(limits: Limits = FALLBACK_LIMITS) {
  return z
    .object({
      name: z.string(),
      slug: z.string(),
      slugEdited: z.boolean(),
      description: z.string(),
      questions: makeQuestionsSchema(limits),
      change_note: z
        .string()
        .trim()
        .refine(
          (v) => charCount(v) <= limits.max_change_note_length,
          `At most ${String(limits.max_change_note_length)} characters`,
        ),
      // Not part of a version (edited in topic settings); shape-checked only.
      schedule: scheduleDraftShape,
    })
    .transform(({ questions, change_note }) => ({ questions, change_note }));
}

export type VersionDraftOutput = z.output<ReturnType<typeof makeVersionDraftSchema>>;

/** Topic metadata only (PATCH). */
export function makeTopicMetaSchema(limits: Limits = FALLBACK_LIMITS) {
  const slugRe = slugPattern(limits);
  return z.object({
    name: nameSchema(limits),
    slug: z.string().trim().min(1, 'Required').regex(slugRe, SLUG_MESSAGE),
    description: descriptionSchema(limits),
  });
}

/** Fill defaults so an input-shaped question renders like an API one. */
export function toOutputShape(q: QuestionInput): Question {
  const common = {
    key: q.key,
    label: q.label,
    help_text: q.help_text ?? null,
    required: q.required ?? true,
  };
  switch (q.type) {
    case 'int':
      return {
        ...common,
        type: 'int',
        min: q.min ?? null,
        max: q.max ?? null,
        unit: q.unit ?? null,
      };
    case 'double':
      return {
        ...common,
        type: 'double',
        min: q.min ?? null,
        max: q.max ?? null,
        unit: q.unit ?? null,
        decimals: q.decimals ?? null,
      };
    case 'str':
      return {
        ...common,
        type: 'str',
        min_length: q.min_length ?? 0,
        max_length: q.max_length ?? 500,
        multiline: q.multiline ?? false,
      };
    case 'enum':
      return {
        ...common,
        type: 'enum',
        options: q.options.map((o) => ({
          value: o.value,
          label: o.label,
          archived: o.archived ?? false,
        })),
        multiple: q.multiple ?? false,
        min_selected: q.min_selected ?? null,
        max_selected: q.max_selected ?? null,
      };
    default:
      throw new Error('question type missing');
  }
}

/**
 * Best-effort conversion of one draft for the live preview: placeholder key /
 * label are filled in and invalid constraints are dropped rather than failing.
 */
export function previewQuestion(d: DraftQuestion, index: number): Question {
  const keyRe = keyPattern(FALLBACK_LIMITS);
  const filled: DraftQuestion = {
    ...d,
    key: keyRe.test(d.key.trim()) ? d.key.trim() : `question_${String(index + 1)}`,
    label: d.label.trim() || `Question ${String(index + 1)}`,
  };
  const r = convertDraftQuestion(filled);
  if (r.ok) return toOutputShape(r.question);
  const bad = new Set(r.issues.map((i) => String(i.path[0])));
  const relaxed: DraftQuestion = {
    ...filled,
    help_text: bad.has('help_text') ? '' : filled.help_text,
    unit: bad.has('unit') ? '' : filled.unit,
    min: bad.has('min') || bad.has('max') ? '' : filled.min,
    max: bad.has('min') || bad.has('max') ? '' : filled.max,
    decimals: bad.has('decimals') ? '' : filled.decimals,
    min_length: bad.has('min_length') || bad.has('max_length') ? '0' : filled.min_length,
    max_length: bad.has('min_length') || bad.has('max_length') ? '500' : filled.max_length,
    multiple: filled.multiple || filled.publishedMultiple,
    min_selected: bad.has('min_selected') || bad.has('max_selected') ? '' : filled.min_selected,
    max_selected: bad.has('min_selected') || bad.has('max_selected') ? '' : filled.max_selected,
    options: filled.options
      .filter((o) => o.label.trim())
      .map((o, i) => ({
        ...o,
        value: keyRe.test(o.value) ? o.value : `option_${String(i + 1)}`,
      }))
      .filter((o, i, all) => all.findIndex((x) => x.value === o.value) === i)
      .filter((o, i, all) => all.findIndex((x) => fold(x.label) === fold(o.label)) === i),
    publishedMultiple: false,
  };
  if (relaxed.type === 'enum' && relaxed.options.every((o) => o.archived)) {
    relaxed.options = [];
  }
  const again = convertDraftQuestion(relaxed);
  if (again.ok) return toOutputShape(again.question);
  // Enum with no usable options yet — render it with none.
  return {
    key: filled.key,
    label: filled.label,
    help_text: null,
    required: filled.required,
    type: 'enum',
    options: [],
    multiple: relaxed.multiple,
    min_selected: null,
    max_selected: null,
  };
}
