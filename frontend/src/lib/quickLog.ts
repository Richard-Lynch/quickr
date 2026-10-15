/**
 * Inline quick-log on topic tiles: which topics can be logged without opening the
 * record screen, and what the tile offers for them.
 *
 * Rule: the current version has exactly one *required* question, and it is
 *  - a single-select enum with 1–6 active options → its options as chips (1 tap logs), or
 *  - an int/double → a stepper prefilled with the last value + a log button (≤ 2 taps).
 * Any optional questions are left unanswered by a quick-log (the record screen is one
 * tap away for those). Everything else — several required questions, a multi-select,
 * text, only optional questions — logs through the record screen.
 */
import { answerFieldSchema } from './answerSchema';
import {
  activeOptions,
  type EnumQuestionOutput,
  type NumericQuestion,
  type Question,
} from './questions';

/** Most options shown as chips on a tile (more need the record screen's select). */
export const QUICK_CHIP_LIMIT = 6;

export type QuickLog =
  | { kind: 'chips'; question: EnumQuestionOutput; options: EnumQuestionOutput['options'] }
  | { kind: 'number'; question: NumericQuestion };

export function quickLogFor(questions: readonly Question[]): QuickLog | null {
  const required = questions.filter((q) => q.required);
  const [q] = required;
  if (required.length !== 1 || !q) return null;
  if (q.type === 'enum') {
    if (q.multiple) return null;
    const options = activeOptions(q);
    if (options.length === 0 || options.length > QUICK_CHIP_LIMIT) return null;
    return { kind: 'chips', question: q, options };
  }
  if (q.type === 'int' || q.type === 'double') return { kind: 'number', question: q };
  return null;
}

/**
 * Starting value for a number tile: the last logged value when it is still valid, else
 * the question's minimum when that is ≥ 0, else blank.
 */
export function initialNumber(q: NumericQuestion, last: unknown): string {
  if (typeof last === 'number') {
    const s = String(last);
    if (answerFieldSchema(q).safeParse(s).success) return s;
  }
  if (q.min !== null && q.min >= 0) return String(q.min);
  return '';
}

/** Parse a tile's number input with the question's own rules (null + message when invalid). */
export function parseQuickNumber(
  q: NumericQuestion,
  raw: string,
): { ok: true; value: number } | { ok: false; message: string } {
  const r = answerFieldSchema({ ...q, required: true }).safeParse(raw);
  if (r.success && typeof r.data === 'number') return { ok: true, value: r.data };
  return { ok: false, message: r.error?.issues[0]?.message ?? 'Enter a number' };
}
