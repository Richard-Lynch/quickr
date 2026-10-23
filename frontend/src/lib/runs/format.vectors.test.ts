/**
 * TS/Python parity for the duration format: every case in
 * shared/fixtures/duration-format-vectors.json (from `run_fold.fmt_duration`).
 */
import { afterAll, describe, expect, it } from 'vitest';

import raw from '../../../../shared/fixtures/duration-format-vectors.json?raw';
import { fmtDuration } from './format';

const vectors = JSON.parse(raw) as { cases: { name: string; ms: number; expected: string }[] };
const ran = new Set<string>();

// A case that is skipped, filtered out or lost from the table fails the file.
afterAll(() => {
  const missing = vectors.cases.map((c) => c.name).filter((n) => !ran.has(n));
  if (missing.length)
    throw new Error(`duration-format vector cases not run: ${missing.join(', ')}`);
});

describe('duration format vectors (shared with the backend and iOS)', () => {
  it('has cases with unique names', () => {
    expect(vectors.cases.length).toBeGreaterThanOrEqual(9);
    expect(new Set(vectors.cases.map((c) => c.name)).size).toBe(vectors.cases.length);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (name, c) => {
    expect(fmtDuration(c.ms)).toBe(c.expected);
    ran.add(name);
  });
});
