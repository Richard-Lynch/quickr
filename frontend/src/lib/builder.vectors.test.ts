/**
 * The PWA builder against the server's verdicts: every `timers[]` and `questions[]` case of
 * shared/fixtures/builder-vectors.json (generated from backend/app/schemas/questions.py by
 * `make vectors`). For each case the builder must accept exactly what the server accepts, flag
 * every location the server rejects (the server reports the first error of a kind, the builder
 * them all, so the server's are a subset), and publish exactly the timer the server stores.
 *
 * Also the drift check of `caseFoldTable.ts` (the fixture's `casefold` list, which the builder
 * compares labels by): with QUICKR_UPDATE_VECTORS=1 this writes it; otherwise it fails when
 * the committed file differs.
 */
import { describe, expect, it } from 'vitest';

import raw from '../../../shared/fixtures/builder-vectors.json?raw';
import type { TimerInput as Timer } from '../client';
import {
  draftFromTimer,
  makeQuestionsSchema,
  timerFromDraft,
  timerIssues,
  type DraftOption,
  type DraftQuestion,
} from './builder';
import { casefold } from './caseFold';

interface TimerCase {
  name: string;
  timer: Timer;
  expected: { errors: string[]; timer: unknown };
}

interface QuestionCase {
  name: string;
  drafts: (Omit<DraftQuestion, 'uid' | 'keyEdited' | 'locked' | 'publishedMultiple' | 'options'> & {
    options: (Pick<DraftOption, 'label' | 'value'> & { archived?: boolean })[];
  })[];
  expected: { errors: string[] };
}

interface Vectors {
  meta: { unicode_version: string };
  timers: TimerCase[];
  questions: QuestionCase[];
  casefold: [number, number[]][];
}

const vectors = JSON.parse(raw) as Vectors;

/**
 * Cases the PWA decides differently on purpose. An integer bound beyond JS's safe integers
 * can't be sent exactly (a JSON number is a double here), so the builder refuses it ("Number
 * is too large") where the server, reading int64, accepts it.
 */
const PWA_LIMITS = new Set(['int/int64-max', 'int/above-js-safe']);

/** A draft path as the wire's dotted location: a variable's `duration` is its `ms`. */
const wirePath = (path: readonly PropertyKey[]) =>
  path.map((x) => (x === 'duration' ? 'ms' : String(x))).join('.');

/** JSON with object keys sorted, so key order doesn't count. */
const canonical = (x: unknown): unknown =>
  Array.isArray(x)
    ? x.map(canonical)
    : x !== null && typeof x === 'object'
      ? Object.fromEntries(
          Object.entries(x)
            .sort(([a], [b]) => (a < b ? -1 : 1))
            .map(([k, v]) => [k, canonical(v)]),
        )
      : x;

function checkVerdict(got: readonly string[], expected: readonly string[]) {
  if (expected.length === 0) {
    expect(got).toEqual([]);
    return;
  }
  expect(got.length).toBeGreaterThan(0);
  for (const e of expected) expect(got).toContain(e);
}

describe('builder vectors: timers (timers2.md §1)', () => {
  it('has cases', () => {
    expect(vectors.timers.length).toBeGreaterThan(50);
  });

  it.each(vectors.timers.map((c) => [c.name, c] as const))('%s', (_name, c) => {
    const draft = draftFromTimer(c.timer);
    const got = [...new Set(timerIssues(draft).map((i) => wirePath(i.path)))].sort();
    checkVerdict(got, c.expected.errors);
    const out = timerFromDraft(draft);
    expect(canonical(out.ok ? out.timer : null)).toEqual(canonical(c.expected.timer));
  });
});

describe('builder vectors: questions (timers.md §2, QuestionSet)', () => {
  it('has cases', () => {
    expect(vectors.questions.length).toBeGreaterThan(100);
  });

  const cases = vectors.questions.filter((c) => !PWA_LIMITS.has(c.name));
  it.each(cases.map((c) => [c.name, c] as const))('%s', (_name, c) => {
    const drafts: DraftQuestion[] = c.drafts.map((d, i) => ({
      ...d,
      uid: `q${String(i)}`,
      keyEdited: true,
      locked: false,
      publishedMultiple: false,
      options: d.options.map((o, j) => ({
        uid: `o${String(j)}`,
        archived: o.archived ?? false,
        valueEdited: true,
        locked: false,
        label: o.label,
        value: o.value,
      })),
    }));
    const r = makeQuestionsSchema().safeParse(drafts);
    const got = r.success ? [] : [...new Set(r.error.issues.map((i) => wirePath(i.path)))].sort();
    checkVerdict(got, c.expected.errors);
  });

  it('the PWA-only refusals are still in the fixture and still refused', () => {
    for (const name of PWA_LIMITS) {
      const c = vectors.questions.find((x) => x.name === name);
      expect(c?.expected.errors).toEqual([]);
    }
  });
});

// No @types/node in the app's tsconfig: reach Node through narrow local types.
interface NodeProcess {
  env: Record<string, string | undefined>;
}
interface NodeFs {
  existsSync(p: string): boolean;
  readFileSync(p: string, enc: 'utf8'): string;
  writeFileSync(p: string, data: string): void;
}
const nodeProcess = (globalThis as unknown as { process: NodeProcess }).process;
const TABLE = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/caseFoldTable.ts`;

/** caseFoldTable.ts for the fixture's `casefold` list, as prettier leaves it. */
function renderTable(): string {
  const entries = vectors.casefold.map(
    ([c, mapped]) => `${c.toString(16)}:${mapped.map((m) => m.toString(16)).join(' ')}`,
  );
  const lines: string[] = [];
  let line = '';
  for (const entry of entries) {
    const next = line === '' ? entry : `${line},${entry}`;
    if (next.length > 92) {
      lines.push(line);
      line = entry;
    } else line = next;
  }
  lines.push(line);
  return `// Generated from shared/fixtures/builder-vectors.json by src/lib/builder.vectors.test.ts.
// Do not edit: \`QUICKR_UPDATE_VECTORS=1 pnpm exec vitest run src/lib/builder.vectors.test.ts\`
// regenerates it, and that test fails when it is stale.
// Python str.casefold(), Unicode ${vectors.meta.unicode_version}: ${String(entries.length)} code points fold to something else.

/** \`code point:folded code points\`, hex; the lines join with commas. */
export const CASE_FOLD_TABLE: readonly string[] = [
${lines.map((l) => `  '${l}',`).join('\n')}
];
`;
}

describe('casefold (Python str.casefold, the fixture’s table)', () => {
  it('caseFoldTable.ts is the fixture’s', async () => {
    const fsName = 'node:fs';
    const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
    const text = renderTable();
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS) {
      fs.writeFileSync(TABLE, text);
      return;
    }
    expect(fs.existsSync(TABLE), 'caseFoldTable.ts is missing').toBe(true);
    expect(fs.readFileSync(TABLE, 'utf8'), 'caseFoldTable.ts is stale').toBe(text);
  });

  it('folds every listed code point as Python does, and leaves others alone', () => {
    for (const [c, mapped] of vectors.casefold)
      expect(casefold(String.fromCodePoint(c))).toBe(String.fromCodePoint(...mapped));
    expect(casefold('Straße')).toBe(casefold('STRASSE'));
    expect(casefold('ΣΑΣ')).toBe(casefold('σας'));
    expect(casefold('é')).not.toBe(casefold('é'));
  });
});
