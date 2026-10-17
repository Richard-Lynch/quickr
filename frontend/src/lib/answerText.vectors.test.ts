/**
 * TS/Python/Swift parity for text and choice answers: every case in
 * shared/fixtures/answer-text-vectors.json (generated from backend/app/services/answers.py by
 * `make vectors`) — server stripping, code-point lengths, NUL, and the message shown.
 */
import { describe, expect, it } from 'vitest';

import raw from '../../../shared/fixtures/answer-text-vectors.json?raw';
import { answerFieldSchema } from './answerSchema';
import type { Question } from './questions';
import { serverStrip } from './text';

type CodePoints = number[];

interface Case {
  name: string;
  question: Question;
  raw: CodePoints | CodePoints[];
  expected: { ok: true; value: CodePoints | CodePoints[] | null } | { ok: false; message: string };
}

interface Vectors {
  meta: { python_whitespace: number[] };
  cases: Case[];
}

const vectors = JSON.parse(raw) as Vectors;

const str = (cps: CodePoints) => String.fromCodePoint(...cps);
const isList = (v: CodePoints | CodePoints[]): v is CodePoints[] => Array.isArray(v[0]);

describe('answer text vectors (shared with the backend and iOS)', () => {
  it('has cases', () => {
    expect(vectors.cases.length).toBeGreaterThan(150);
  });

  it('serverStrip removes exactly Python’s whitespace', () => {
    const python = new Set(vectors.meta.python_whitespace);
    for (let c = 0; c <= 0x3000; c++) {
      const ch = String.fromCodePoint(c);
      expect(serverStrip(`${ch}x${ch}`) === 'x', `U+${c.toString(16)}`).toBe(python.has(c));
    }
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (_, c) => {
    const input = isList(c.raw) ? c.raw.map(str) : str(c.raw);
    const r = answerFieldSchema(c.question).safeParse(input);
    if (c.expected.ok) {
      const v = c.expected.value;
      expect(r.error?.issues[0]?.message).toBeUndefined();
      expect(r.data).toEqual(v === null ? null : isList(v) ? v.map(str) : str(v));
    } else {
      expect(r.success).toBe(false);
      expect(r.error?.issues[0]?.message).toBe(c.expected.message);
    }
  });
});
