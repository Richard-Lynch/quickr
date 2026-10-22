/**
 * TS/Python parity for quick-log: every case in shared/fixtures/quicklog-vectors.json
 * (generated from backend/app/services/quicklog.py by `make vectors`) must agree with
 * quickLogFor / initialNumber here.
 */
import { describe, expect, it } from 'vitest';

import raw from '../../../shared/fixtures/quicklog-vectors.json?raw';
import type { NumericQuestion, Question } from './questions';
import { initialNumber, quickLogFor } from './quickLog';

type Descriptor =
  | { kind: 'chips'; key: string; options: { value: string; label: string }[] }
  | { kind: 'number'; key: string }
  | { kind: 'single' };

interface Vectors {
  eligibility: { name: string; questions: Question[]; expected: Descriptor | null }[];
  initial: { name: string; question: NumericQuestion; last: unknown; expected: string }[];
}

const vectors = JSON.parse(raw) as Vectors;

function describeQuickLog(questions: Question[]): Descriptor | null {
  const r = quickLogFor(questions);
  if (!r) return null;
  if (r.kind === 'single') return { kind: 'single' };
  if (r.kind === 'chips')
    return {
      kind: 'chips',
      key: r.question.key,
      options: r.options.map((o) => ({ value: o.value, label: o.label })),
    };
  return { kind: 'number', key: r.question.key };
}

describe('quick-log vectors (shared with the backend and iOS)', () => {
  it('has cases', () => {
    expect(vectors.eligibility.length).toBeGreaterThan(10);
    expect(vectors.initial.length).toBeGreaterThan(100);
  });

  it.each(vectors.eligibility.map((c) => [c.name, c] as const))('eligibility: %s', (_, c) => {
    expect(describeQuickLog(c.questions)).toEqual(c.expected);
  });

  it.each(vectors.initial.map((c) => [c.name, c] as const))('initial value: %s', (_, c) => {
    expect(initialNumber(c.question, c.last)).toBe(c.expected);
  });
});
