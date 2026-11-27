/**
 * Turning stored answers (`EntryOut.answers`) into display text. Shared by the entries
 * list/table, the topic tiles ("last: …") and the record screen ("Same as last time").
 */
import type { StoredAnswer } from './entrySummary';
import type { Question } from './questions';

export type { StoredAnswer };

/** Option label for a value (falls back to the raw value for unknown/removed options). */
export function optionLabel(q: Question, value: string): string {
  return q.type === 'enum' ? (q.options.find((o) => o.value === value)?.label ?? value) : value;
}

/**
 * Human text for one answer, or null when it can't be shown for this question: the summary
 * line's `answerText` (content-display.md §1.2), so every surface shows an answer the same way.
 */
export { answerText as formatAnswer } from './entrySummary';

/** Option labels of an enum answer as a list (chips in the entries list). */
export function answerLabels(q: Question, a: StoredAnswer): string[] {
  if (q.type !== 'enum') return [];
  const values = Array.isArray(a.value) ? a.value : typeof a.value === 'string' ? [a.value] : [];
  return values.map((v) => optionLabel(q, v));
}
