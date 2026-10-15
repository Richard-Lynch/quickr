/**
 * Topic builder: editable draft state <-> API question config.
 *
 * Drafts keep every constraint as a string (straight from inputs) plus a bit of
 * UI bookkeeping (`uid`, `keyEdited`, `locked`). `topicDraftSchema` validates a
 * draft with the same rules as the backend and transforms it into the API
 * shape; each question is finally checked against the generated zod schema for
 * its type so the client can never drift from the OpenAPI contract.
 */
import { z } from 'zod';

import {
  zDoubleQuestionInput,
  zEnumQuestionInput,
  zIntQuestionInput,
  zStrQuestionInput,
  zTopicCreate,
} from '../client/zod.gen';
import { parseNumberInput } from './answerSchema';
import { KEY_RE, SLUG_RE, type Question, type QuestionInput, type QuestionType } from './questions';

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
}

export interface TopicDraft {
  name: string;
  slug: string;
  slugEdited: boolean;
  description: string;
  questions: DraftQuestion[];
  /** Only used when publishing a new version. */
  change_note: string;
}

let uidCounter = 0;
export function uid(prefix = 'd'): string {
  uidCounter += 1;
  return `${prefix}${Date.now().toString(36)}${uidCounter.toString(36)}`;
}

/** "Hours slept (approx.)" -> "hours_slept_approx". Always matches KEY_RE or is ''. */
export function toSnakeKey(label: string): string {
  const base = label
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/^[0-9_]+/, '')
    .slice(0, 63)
    .replace(/_+$/, '');
  return base;
}

/** Mirrors backend `slugify`. */
export function slugify(name: string): string {
  const s = name
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
    .replace(/-+$/, '');
  return s;
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
  };
}

export function emptyTopicDraft(): TopicDraft {
  const first = newDraftQuestion('int');
  return {
    name: '',
    slug: '',
    slugEdited: false,
    description: '',
    questions: [first],
    change_note: '',
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
interface Issue {
  path: Path;
  message: string;
}

const KEY_MESSAGE = 'Use lower_snake_case: a–z, 0–9, _ (start with a letter)';

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
  if (min !== undefined && n < min) {
    fail(`Must be at least ${min}`);
    return;
  }
  if (max !== undefined && n > max) {
    fail(`Must be at most ${max}`);
    return;
  }
  return n;
}

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
): { ok: true; question: QuestionInput } | { ok: false; issues: Issue[] } {
  const issues: Issue[] = [];
  const key = d.key.trim();
  const label = d.label.trim();
  if (!label) issues.push({ path: ['label'], message: 'Required' });
  if (!key) issues.push({ path: ['key'], message: 'Required' });
  else if (!KEY_RE.test(key)) issues.push({ path: ['key'], message: KEY_MESSAGE });

  const common = {
    key,
    label,
    help_text: d.help_text.trim() || null,
    required: d.required,
  };

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
      candidate = {
        ...common,
        type: d.type,
        min: min ?? null,
        max: max ?? null,
        unit: d.unit.trim() || null,
      };
      if (d.type === 'double') {
        candidate.decimals =
          parseConstraint(issues, d.decimals, 'decimals', {
            integer: true,
            min: 0,
            max: 10,
          }) ?? null;
      }
      break;
    }
    case 'str': {
      const lo = parseConstraint(issues, d.min_length, 'min_length', {
        integer: true,
        min: 0,
        max: 10_000,
      });
      const hi = parseConstraint(issues, d.max_length, 'max_length', {
        integer: true,
        min: 1,
        max: 10_000,
      });
      const minLength = lo ?? 0;
      const maxLength = hi ?? 500;
      if (minLength > maxLength) {
        issues.push({
          path: ['max_length'],
          message: 'Max length must be ≥ min length',
        });
      }
      candidate = {
        ...common,
        type: 'str',
        min_length: minLength,
        max_length: maxLength,
        multiline: d.multiline,
      };
      break;
    }
    case 'enum': {
      const seen = new Set<string>();
      d.options.forEach((o, i) => {
        const value = o.value.trim();
        if (!o.label.trim()) issues.push({ path: ['options', i, 'label'], message: 'Required' });
        if (!value) issues.push({ path: ['options', i, 'value'], message: 'Required' });
        else if (!KEY_RE.test(value))
          issues.push({ path: ['options', i, 'value'], message: KEY_MESSAGE });
        else if (seen.has(value))
          issues.push({
            path: ['options', i, 'value'],
            message: 'Duplicate value',
          });
        seen.add(value);
      });
      if (d.options.length === 0) {
        issues.push({ path: ['options'], message: 'Add at least one option' });
      } else if (d.options.every((o) => o.archived)) {
        issues.push({
          path: ['options'],
          message: 'At least one option must be active',
        });
      }
      candidate = {
        ...common,
        type: 'enum',
        options: d.options.map((o) => ({
          value: o.value.trim(),
          label: o.label.trim(),
          archived: o.archived,
        })),
        multiple: false,
        min_selected: null,
        max_selected: null,
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

/** Draft question -> API question, with issues reported at draft field paths. */
export const draftQuestionSchema = z
  .object({
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
  })
  .transform((d, ctx): QuestionInput => {
    const r = convertDraftQuestion(d);
    if (r.ok) return r.question;
    for (const i of r.issues) ctx.addIssue({ code: 'custom', message: i.message, path: i.path });
    return z.NEVER;
  });

const questionsSchema = z
  .array(draftQuestionSchema)
  .min(1, 'Add at least one question')
  .max(100, 'At most 100 questions')
  .superRefine((qs, ctx) => {
    const seen = new Set<string>();
    qs.forEach((q, i) => {
      if (seen.has(q.key)) {
        ctx.addIssue({
          code: 'custom',
          message: 'Key already used by another question',
          path: [i, 'key'],
        });
      }
      seen.add(q.key);
    });
  });

const slugSchema = z
  .string()
  .trim()
  .refine((v) => v === '' || SLUG_RE.test(v), 'Lowercase letters, digits and dashes')
  .transform((v) => (v === '' ? null : v))
  .pipe(zTopicCreate.shape.slug.unwrap());

/** Validates a whole topic draft and outputs a `TopicCreate` body. */
export const topicDraftSchema = z
  .object({
    name: z.string().trim().min(1, 'Give the topic a name').pipe(zTopicCreate.shape.name),
    slug: slugSchema,
    slugEdited: z.boolean(),
    description: z.string().trim().max(5000, 'At most 5000 characters'),
    questions: questionsSchema,
    change_note: z.string(),
  })
  .transform(({ name, slug, description, questions }) => ({
    name,
    slug,
    description,
    questions,
  }));

export type TopicDraftOutput = z.output<typeof topicDraftSchema>;

/** Questions + change note for checking / publishing a new version. */
export const versionDraftSchema = z
  .object({
    name: z.string(),
    slug: z.string(),
    slugEdited: z.boolean(),
    description: z.string(),
    questions: questionsSchema,
    change_note: z.string().trim().max(2000, 'At most 2000 characters'),
  })
  .transform(({ questions, change_note }) => ({ questions, change_note }));

export type VersionDraftOutput = z.output<typeof versionDraftSchema>;

/** Topic metadata only (PATCH). */
export const topicMetaSchema = z.object({
  name: z.string().trim().min(1, 'Give the topic a name').pipe(zTopicCreate.shape.name),
  slug: z.string().trim().regex(SLUG_RE, 'Lowercase letters, digits and dashes'),
  description: z.string().trim().max(5000, 'At most 5000 characters'),
});

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
  const filled: DraftQuestion = {
    ...d,
    key: KEY_RE.test(d.key.trim()) ? d.key.trim() : `question_${index + 1}`,
    label: d.label.trim() || `Question ${index + 1}`,
  };
  const r = convertDraftQuestion(filled);
  if (r.ok) return toOutputShape(r.question);
  const bad = new Set(r.issues.map((i) => String(i.path[0])));
  const relaxed: DraftQuestion = {
    ...filled,
    min: bad.has('min') || bad.has('max') ? '' : filled.min,
    max: bad.has('min') || bad.has('max') ? '' : filled.max,
    decimals: bad.has('decimals') ? '' : filled.decimals,
    min_length: bad.has('min_length') || bad.has('max_length') ? '0' : filled.min_length,
    max_length: bad.has('min_length') || bad.has('max_length') ? '500' : filled.max_length,
    options: filled.options
      .filter((o) => o.label.trim())
      .map((o, i) => ({
        ...o,
        value: KEY_RE.test(o.value) ? o.value : `option_${i + 1}`,
      }))
      .filter((o, i, all) => all.findIndex((x) => x.value === o.value) === i),
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
    help_text: filled.help_text.trim() || null,
    required: filled.required,
    type: 'enum',
    options: [],
    multiple: false,
    min_selected: null,
    max_selected: null,
  };
}
