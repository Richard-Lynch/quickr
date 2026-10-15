import type {
  DoubleQuestionOutput,
  EnumQuestionOutput,
  IntQuestionOutput,
  StrQuestionOutput,
  TopicDetail,
  VersionDraft,
} from '../client';

/** A question as returned by the API (all defaults filled in). */
export type Question = TopicDetail['questions'][number];
/** A question as accepted by the API (create / publish / check). */
export type QuestionInput = VersionDraft['questions'][number];
export type QuestionType = Question['type'];

export type NumericQuestion = IntQuestionOutput | DoubleQuestionOutput;
export type { DoubleQuestionOutput, EnumQuestionOutput, IntQuestionOutput, StrQuestionOutput };

export const QUESTION_TYPES: readonly QuestionType[] = ['int', 'double', 'str', 'enum'];

export const TYPE_META: Record<QuestionType, { label: string; short: string; hint: string }> = {
  int: { label: 'Whole number', short: 'Int', hint: 'Counts, steps, ratings 1–10' },
  double: { label: 'Decimal number', short: 'Dec', hint: 'Weights, hours, temperatures' },
  str: { label: 'Text', short: 'Text', hint: 'Notes, names, free answers' },
  enum: { label: 'Choice', short: 'Pick', hint: 'One or several options from a list' },
};

/** Mirrors the backend KEY_PATTERN — used for question keys and enum option values. */
export const KEY_RE = /^[a-z][a-z0-9_]{0,62}$/;
/** Mirrors the backend SLUG_PATTERN. */
export const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

export function activeOptions(q: EnumQuestionOutput): EnumQuestionOutput['options'] {
  return q.options.filter((o) => !o.archived);
}

export function isNumeric(q: Question): q is NumericQuestion {
  return q.type === 'int' || q.type === 'double';
}

/** Multi-select enum: answers are lists of option values. */
export function isMultiEnum(q: Question): q is EnumQuestionOutput & { multiple: true } {
  return q.type === 'enum' && q.multiple;
}

export function unitSuffix(q: Question): string {
  return (q.type === 'int' || q.type === 'double') && q.unit ? ` ${q.unit}` : '';
}
