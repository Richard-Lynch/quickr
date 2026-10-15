/**
 * Turning stored answers (`EntryOut.answers`) into display text. Shared by the entries
 * list/table, the topic tiles ("last: …") and the record screen ("Same as last time").
 */
import type { EntryOut } from '../client';
import { formatNumber } from './format';
import type { Question } from './questions';

export type StoredAnswer = EntryOut['answers'][number];

/** Option label for a value (falls back to the raw value for unknown/removed options). */
export function optionLabel(q: Question, value: string): string {
  return q.type === 'enum' ? (q.options.find((o) => o.value === value)?.label ?? value) : value;
}

/** Human text for one answer, or null when it can't be shown for this question. */
export function formatAnswer(q: Question, a: StoredAnswer): string | null {
  switch (q.type) {
    case 'int':
    case 'double':
      if (typeof a.value !== 'number') return null;
      return `${formatNumber(a.value, q.type === 'double' ? (q.decimals ?? 3) : 0)}${q.unit ? ` ${q.unit}` : ''}`;
    case 'enum':
      // A single-select question that later became multi-select keeps its old `enum`
      // answers, so accept both shapes.
      if (Array.isArray(a.value)) return a.value.map((v) => optionLabel(q, v)).join(', ') || null;
      return typeof a.value === 'string' ? optionLabel(q, a.value) : null;
    case 'str':
      return typeof a.value === 'string' ? a.value : null;
  }
}

/** Option labels of an enum answer as a list (chips in the entries list). */
export function answerLabels(q: Question, a: StoredAnswer): string[] {
  if (q.type !== 'enum') return [];
  const values = Array.isArray(a.value) ? a.value : typeof a.value === 'string' ? [a.value] : [];
  return values.map((v) => optionLabel(q, v));
}
