/**
 * Generator + drift check for shared/fixtures/builder-ui-vectors.json: the builder screens'
 * client-side rules (a new question's draft, the draft a published question opens as, the live
 * preview's best-effort question, the versions list's constraint line), for the iOS port
 * (BUILDER-UI). What the server decides is builder-vectors.json (backend).
 *
 * Text is en-US (the test checks the locale). With QUICKR_UPDATE_VECTORS=1 (`make vectors`)
 * this writes the file; otherwise it fails when the committed file differs.
 */
import { describe, expect, it } from 'vitest';

import {
  draftFromQuestion,
  newDraftQuestion,
  previewQuestion,
  type DraftOption,
  type DraftQuestion,
} from './builder';
import { QUESTION_TYPES, type Question } from './questions';
import { constraintText } from './questionSummary';

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

const FILE = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/../../../shared/fixtures/builder-ui-vectors.json`;
const FILE_LABEL = 'shared/fixtures/builder-ui-vectors.json';

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

type PlainOption = Omit<DraftOption, 'uid'>;
type PlainDraft = Omit<DraftQuestion, 'uid' | 'options'> & { options: PlainOption[] };

/** A draft without its generated ids. */
function plain(d: DraftQuestion): PlainDraft {
  const { options, ...rest } = d;
  const strip = <T extends { uid: string }>(x: T): Omit<T, 'uid'> => {
    const out: Partial<T> = { ...x };
    delete out.uid;
    return out as Omit<T, 'uid'>;
  };
  return { ...strip(rest as DraftQuestion), options: options.map(strip) };
}

function option(label: string, value: string, over: Partial<PlainOption> = {}): DraftOption {
  return { uid: 'o', label, value, archived: false, valueEdited: false, locked: false, ...over };
}

/** A new question of `type` with `over` applied. */
function draft(type: DraftQuestion['type'], over: Partial<DraftQuestion> = {}): DraftQuestion {
  return { ...newDraftQuestion(type), ...over };
}

const yesNo = [option('Yes', 'yes'), option('No', 'no')];

const PREVIEW: { name: string; index: number; draft: DraftQuestion }[] = [
  { name: 'new int: placeholders', index: 0, draft: draft('int') },
  { name: 'new int: third question', index: 2, draft: draft('int') },
  { name: 'new double: one decimal', index: 0, draft: draft('double') },
  { name: 'new text', index: 1, draft: draft('str') },
  { name: 'new choice: yes/no', index: 0, draft: draft('enum') },
  {
    name: 'int: full',
    index: 0,
    draft: draft('int', {
      key: 'glasses',
      label: 'Glasses of water',
      help_text: 'Count them',
      min: '0',
      max: '20',
      unit: 'glasses',
      required: false,
    }),
  },
  { name: 'int: label trimmed', index: 0, draft: draft('int', { key: 'k', label: '  Steps  ' }) },
  { name: 'int: key trimmed', index: 0, draft: draft('int', { key: ' steps ', label: 'Steps' }) },
  { name: 'int: bad key', index: 3, draft: draft('int', { key: 'Steps!', label: 'Steps' }) },
  { name: 'int: blank label', index: 1, draft: draft('int', { key: 'steps', label: '   ' }) },
  {
    name: 'int: min > max dropped',
    index: 0,
    draft: draft('int', { key: 'k', label: 'K', min: '9', max: '1' }),
  },
  {
    name: 'int: bad min dropped',
    index: 0,
    draft: draft('int', { key: 'k', label: 'K', min: 'x', max: '5' }),
  },
  {
    name: 'int: decimal min dropped',
    index: 0,
    draft: draft('int', { key: 'k', label: 'K', min: '1.5' }),
  },
  { name: 'int: only max', index: 0, draft: draft('int', { key: 'k', label: 'K', max: '10' }) },
  {
    name: 'double: decimals kept',
    index: 0,
    draft: draft('double', {
      key: 'kg',
      label: 'Weight',
      min: '0.5',
      max: '300',
      decimals: '2',
      unit: 'kg',
    }),
  },
  {
    name: 'double: bad decimals dropped',
    index: 0,
    draft: draft('double', { key: 'kg', label: 'W', decimals: '9' }),
  },
  {
    name: 'double: no decimals',
    index: 0,
    draft: draft('double', { key: 'kg', label: 'W', decimals: '' }),
  },
  {
    name: 'text: multiline with lengths',
    index: 0,
    draft: draft('str', {
      key: 'notes',
      label: 'Notes',
      min_length: '5',
      max_length: '200',
      multiline: true,
    }),
  },
  {
    name: 'text: min > max reset',
    index: 0,
    draft: draft('str', { key: 'notes', label: 'Notes', min_length: '50', max_length: '10' }),
  },
  {
    name: 'text: bad max reset',
    index: 0,
    draft: draft('str', { key: 'n', label: 'N', max_length: 'lots' }),
  },
  {
    name: 'choice: multiple with bounds',
    index: 0,
    draft: draft('enum', {
      key: 'tags',
      label: 'Tags',
      options: [option('Red', 'red'), option('Green', 'green'), option('Blue', 'blue')],
      multiple: true,
      min_selected: '1',
      max_selected: '2',
    }),
  },
  {
    name: 'choice: bad bounds dropped',
    index: 0,
    draft: draft('enum', {
      key: 'tags',
      label: 'Tags',
      options: yesNo,
      multiple: true,
      min_selected: '3',
      max_selected: '1',
    }),
  },
  {
    name: 'choice: blank option dropped',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [option('Yes', 'yes'), option('  ', 'blank')],
    }),
  },
  {
    name: 'choice: bad option value renumbered',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [option('Yes', 'Yes!'), option('No', 'no')],
    }),
  },
  {
    name: 'choice: duplicate value dropped',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [option('Yes', 'yes'), option('Yeah', 'yes')],
    }),
  },
  {
    name: 'choice: duplicate label dropped',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [option('Yes', 'yes'), option('YES', 'yes_2')],
    }),
  },
  {
    name: 'choice: archived option kept',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [
        option('Yes', 'yes'),
        option('Maybe', 'maybe', { archived: true, locked: true }),
        option('No', 'no'),
      ],
    }),
  },
  {
    name: 'choice: all archived shows none',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: [option('Yes', 'yes', { archived: true }), option('No', 'no', { archived: true })],
    }),
  },
  {
    name: 'choice: no options',
    index: 4,
    draft: draft('enum', { key: 'c', label: 'C', options: [] }),
  },
  {
    name: 'choice: published multiple stays multiple',
    index: 0,
    draft: draft('enum', {
      key: 'c',
      label: 'C',
      options: yesNo,
      multiple: false,
      publishedMultiple: true,
    }),
  },
  {
    name: 'choice: bad help text dropped',
    index: 0,
    draft: draft('enum', { key: 'c', label: 'C', options: yesNo, help_text: 'x'.repeat(1001) }),
  },
];

const QUESTIONS: Question[] = [
  {
    key: 'a',
    label: 'A',
    help_text: null,
    required: true,
    type: 'int',
    min: null,
    max: null,
    unit: null,
  },
  {
    key: 'b',
    label: 'B',
    help_text: 'Help',
    required: false,
    type: 'int',
    min: 0,
    max: 10,
    unit: null,
  },
  {
    key: 'c',
    label: 'C',
    help_text: null,
    required: true,
    type: 'int',
    min: 1,
    max: null,
    unit: 'steps',
  },
  {
    key: 'd',
    label: 'D',
    help_text: null,
    required: true,
    type: 'int',
    min: null,
    max: 12000,
    unit: 'm',
  },
  {
    key: 'e',
    label: 'E',
    help_text: null,
    required: true,
    type: 'int',
    min: -5,
    max: 5,
    unit: null,
  },
  {
    key: 'f',
    label: 'F',
    help_text: null,
    required: true,
    type: 'double',
    min: 0.5,
    max: 300,
    unit: 'kg',
    decimals: 1,
  },
  {
    key: 'g',
    label: 'G',
    help_text: null,
    required: true,
    type: 'double',
    min: null,
    max: null,
    unit: null,
    decimals: null,
  },
  {
    key: 'h',
    label: 'H',
    help_text: null,
    required: true,
    type: 'double',
    min: 1.255,
    max: 1234567.891,
    unit: null,
    decimals: 0,
  },
  {
    key: 'i',
    label: 'I',
    help_text: null,
    required: true,
    type: 'double',
    min: null,
    max: 0.125,
    unit: 'l',
    decimals: 3,
  },
  {
    key: 'j',
    label: 'J',
    help_text: null,
    required: true,
    type: 'str',
    min_length: 0,
    max_length: 500,
    multiline: false,
  },
  {
    key: 'k',
    label: 'K',
    help_text: null,
    required: false,
    type: 'str',
    min_length: 5,
    max_length: 2000,
    multiline: true,
  },
  {
    key: 'l',
    label: 'L',
    help_text: null,
    required: true,
    type: 'enum',
    options: [
      { value: 'yes', label: 'Yes', archived: false },
      { value: 'no', label: 'No', archived: false },
    ],
    multiple: false,
    min_selected: null,
    max_selected: null,
  },
  {
    key: 'm',
    label: 'M',
    help_text: 'Pick some',
    required: true,
    type: 'enum',
    options: [
      { value: 'red', label: 'Red', archived: false },
      { value: 'old', label: 'Old', archived: true },
      { value: 'blue', label: 'Blue', archived: true },
    ],
    multiple: true,
    min_selected: 1,
    max_selected: 2,
  },
  {
    key: 'n',
    label: 'N',
    help_text: null,
    required: true,
    type: 'enum',
    options: [{ value: 'only', label: 'Only', archived: false }],
    multiple: false,
    min_selected: null,
    max_selected: null,
  },
  {
    key: 'o',
    label: 'O',
    help_text: null,
    required: true,
    type: 'enum',
    options: [{ value: 'gone', label: 'Gone', archived: true }],
    multiple: false,
    min_selected: null,
    max_selected: null,
  },
];

function generate() {
  return {
    meta: { generator: 'frontend/src/lib/builderUi.vectors.test.ts', version: 1, locale: 'en-US' },
    new_question: QUESTION_TYPES.map((type) => ({ type, expected: plain(newDraftQuestion(type)) })),
    from_question: QUESTIONS.flatMap((question) =>
      [true, false].map((locked) => ({
        question,
        locked,
        expected: plain(draftFromQuestion(question, locked)),
      })),
    ),
    preview: PREVIEW.map(({ name, index, draft: d }) => ({
      name,
      index,
      draft: plain(d),
      expected: previewQuestion(d, index),
    })),
    constraint_text: QUESTIONS.map((question) => ({
      question,
      expected: constraintText(question),
    })),
  };
}

// One case per line, like the other vector files.
function serialise(data: ReturnType<typeof generate>): string {
  const section = (items: unknown[]) =>
    `[\n${items.map((x) => `    ${JSON.stringify(x)}`).join(',\n')}\n  ]`;
  return `{\n  "meta": ${JSON.stringify(data.meta)},\n${(
    ['new_question', 'from_question', 'preview', 'constraint_text'] as const
  )
    .map((k) => `  "${k}": ${section(data[k])}`)
    .join(',\n')}\n}\n`;
}

describe('builder UI vectors', () => {
  it('runs in en-US', () => {
    expect(new Intl.NumberFormat().resolvedOptions().locale).toBe('en-US');
  });

  it(`${FILE_LABEL} matches builder.ts and questionSummary.ts`, async () => {
    const fsName = 'node:fs';
    const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
    const text = serialise(generate());
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS) {
      fs.writeFileSync(FILE, text);
      return;
    }
    expect(fs.existsSync(FILE), `${FILE_LABEL} is missing: run make vectors`).toBe(true);
    expect(fs.readFileSync(FILE, 'utf8'), `${FILE_LABEL} is stale: run make vectors`).toBe(text);
  });
});
