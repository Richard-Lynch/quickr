/**
 * TS/Python parity for alert expressions (timers2.md §2.5, T29): every case in
 * shared/fixtures/timer-expr-vectors.json (from `timer_expr.evaluate`), and the edge rules its
 * `meta.semantics` pins (error order, longest-match units, code-point positions), and each
 * error's message, the server's 422 text.
 */
import { afterAll, describe, expect, it } from 'vitest';

import raw from '../../../../shared/fixtures/timer-expr-vectors.json?raw';
import { ExprError, MAX_EXPR_LENGTH, MAX_EXPR_MS, evaluate } from './timerExpr';

interface Case {
  name: string;
  expr: string;
  variables: Record<string, number>;
  expected: { ms: number } | { error: string; pos: number; message: string };
}

const vectors = JSON.parse(raw) as {
  meta: { generator_version: number; max_ms: number; max_length: number; semantics: string[] };
  cases: Case[];
};
const ran = new Set<string>();

// A case that is skipped, filtered out or lost from the table fails the file.
afterAll(() => {
  const missing = vectors.cases.map((c) => c.name).filter((n) => !ran.has(n));
  if (missing.length) throw new Error(`timer-expr vector cases not run: ${missing.join(', ')}`);
});

/** `{ms}` or `{error, pos, message}` (the server's 422 text), as the vectors spell an outcome. */
function outcome(c: Case): Case['expected'] {
  try {
    return { ms: evaluate(c.expr, c.variables) };
  } catch (e) {
    if (e instanceof ExprError) return { error: e.code, pos: e.pos, message: e.message };
    throw e;
  }
}

describe('timer expression vectors (shared with the backend and iOS)', () => {
  it('has the §2.5 cases, with unique names, under the same bounds', () => {
    expect(vectors.meta.generator_version).toBe(2);
    expect(vectors.meta.max_ms).toBe(MAX_EXPR_MS);
    expect(vectors.meta.max_length).toBe(MAX_EXPR_LENGTH);
    expect(vectors.meta.semantics.length).toBeGreaterThan(0);
    expect(vectors.cases.length).toBeGreaterThanOrEqual(41);
    expect(new Set(vectors.cases.map((c) => c.name)).size).toBe(vectors.cases.length);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (name, c) => {
    expect(outcome(c)).toEqual(c.expected);
    ran.add(name);
  });
});
