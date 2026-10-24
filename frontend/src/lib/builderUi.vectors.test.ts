/**
 * Generator + drift check for shared/fixtures/builder-ui-vectors.json: the builder screens'
 * client-side rules (a new question's draft, the draft a published question opens as, the live
 * preview's best-effort question, the versions list's constraint line; and for timed topics a
 * new step's key, the steps a published timer opens as, renaming, the timer a draft publishes
 * (or its issues) and the review sheet's timing lines), for the iOS port (BUILDER-UI, I-MANAGE). What the server decides is builder-vectors.json (backend).
 *
 * Text is en-US (the test checks the locale). With QUICKR_UPDATE_VECTORS=1 (`make vectors`)
 * this writes the file; otherwise it fails when the committed file differs.
 */
import { describe, expect, it } from 'vitest';

import {
  draftFromQuestion,
  draftFromTimer,
  newDraftQuestion,
  newDraftStep,
  previewQuestion,
  timerChanges,
  timerFromDraft,
  withStepLabel,
  type DraftOption,
  type DraftQuestion,
  type DraftStep,
} from './builder';
import type { Timer } from '../client';
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

// ---------------------------------------------------------------------------
// Timed topics (timers.md §2.1)
// ---------------------------------------------------------------------------

type PlainStep = Omit<DraftStep, 'uid'>;
const plainStep = ({ key, label, locked }: DraftStep): PlainStep => ({ key, label, locked });
const step = (key: string, label: string, locked = false): DraftStep => ({
  uid: 's',
  key,
  label,
  locked,
});

const HISTORY = [
  { key: 'prep', label: 'Old prep' },
  { key: 'shower', label: 'Shower' },
];

const NEW_STEP: { label: string; taken: string[]; history?: { key: string; label: string }[] }[] = [
  { label: '', taken: [] },
  { label: '   ', taken: [] },
  { label: 'Shower', taken: [] },
  { label: '  Brush teeth  ', taken: [] },
  { label: 'Shower', taken: ['shower'] },
  { label: 'Shower', taken: ['shower', 'shower_2'] },
  { label: '123', taken: [] },
  { label: '123', taken: ['step'] },
  { label: 'Café au lait!', taken: [] },
  { label: 'x'.repeat(80), taken: [] },
  { label: ' old PREP ', taken: [], history: HISTORY },
  { label: 'Prep', taken: [], history: HISTORY },
  { label: 'Old prep', taken: ['prep'], history: HISTORY },
  { label: 'Shower', taken: ['shower'], history: HISTORY },
];

const TIMERS: (Timer | null)[] = [
  null,
  { steps: [] },
  {
    steps: [
      { key: 'shower', label: 'Shower' },
      { key: 'dress', label: 'Get dressed' },
    ],
  },
];

const STEP_LABEL: {
  name: string;
  step: DraftStep;
  label: string;
  taken: string[];
  history?: { key: string; label: string }[];
}[] = [
  { name: 'published: key kept', step: step('shower', 'Shower', true), label: 'Bath', taken: [] },
  {
    name: 'published: blank keeps key',
    step: step('shower', 'Shower', true),
    label: '',
    taken: [],
  },
  { name: 'new: key follows', step: step('shower', 'Shower'), label: 'Bath', taken: [] },
  { name: 'new: blank clears key', step: step('shower', 'Shower'), label: ' ', taken: [] },
  { name: 'new: taken key', step: step('', ''), label: 'Dress', taken: ['dress'] },
  {
    name: 'new: a retired step again',
    step: step('', ''),
    label: 'Old Prep',
    taken: [],
    history: HISTORY,
  },
  {
    name: 'new: not a retired key',
    step: step('', ''),
    label: 'Prep',
    taken: [],
    history: HISTORY,
  },
  {
    name: 'published: history ignored',
    step: step('dress', 'Dress', true),
    label: 'Old prep',
    taken: [],
    history: HISTORY,
  },
];

const TIMER_OUTPUT: { name: string; timed: boolean; steps: DraftStep[] }[] = [
  { name: 'not timed', timed: false, steps: [] },
  { name: 'not timed ignores steps', timed: false, steps: [step('', '')] },
  { name: 'stopwatch', timed: true, steps: [] },
  {
    name: 'steps trimmed, in order',
    timed: true,
    steps: [step('dress', ' Get dressed '), step('shower', 'Shower', true)],
  },
  { name: 'blank label', timed: true, steps: [step('', '  ')] },
  { name: 'bad key', timed: true, steps: [step('Shower', 'Shower')] },
  {
    name: 'duplicate key (a repeated label is fine)',
    timed: true,
    steps: [step('a', 'A'), step('a', 'a')],
  },
  {
    name: 'repeated label',
    timed: true,
    steps: [step('rinse', 'Rinse'), step('rinse_2', 'rinse')],
  },
  { name: 'label too long', timed: true, steps: [step('long', 'x'.repeat(201))] },
  {
    name: 'too many steps',
    timed: true,
    steps: Array.from({ length: 31 }, (_, i) => step(`s${String(i)}`, `S${String(i)}`)),
  },
];

const shower = { key: 'shower', label: 'Shower' };
const dress = { key: 'dress', label: 'Get dressed' };
const TIMER_CHANGES: { name: string; base: Timer | null; next: Timer | null }[] = [
  { name: 'untimed both', base: null, next: null },
  { name: 'unchanged', base: { steps: [shower, dress] }, next: { steps: [shower, dress] } },
  { name: 'turned on, stopwatch', base: null, next: { steps: [] } },
  { name: 'turned on, one step', base: null, next: { steps: [shower] } },
  { name: 'turned on, two steps', base: null, next: { steps: [shower, dress] } },
  { name: 'turned off', base: { steps: [shower] }, next: null },
  { name: 'renamed', base: { steps: [shower] }, next: { steps: [{ ...shower, label: 'Bath' }] } },
  { name: 'added and removed', base: { steps: [shower] }, next: { steps: [dress] } },
  { name: 'reordered', base: { steps: [shower, dress] }, next: { steps: [dress, shower] } },
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
    new_step: NEW_STEP.map(({ label, taken, history = [] }) => ({
      label,
      taken,
      history,
      expected: plainStep(newDraftStep(label, taken, history)),
    })),
    from_timer: TIMERS.map((timer) => {
      const d = draftFromTimer(timer);
      return { timer, expected: { timed: d.timed, steps: d.steps.map(plainStep) } };
    }),
    step_label: STEP_LABEL.map(({ name, step: st, label, taken, history = [] }) => ({
      name,
      step: plainStep(st),
      label,
      taken,
      history,
      expected: plainStep(withStepLabel(st, label, taken, history)),
    })),
    timer_output: TIMER_OUTPUT.map(({ name, timed, steps }) => {
      const r = timerFromDraft({ timed, steps });
      return {
        name,
        timed,
        steps: steps.map(plainStep),
        expected: r.ok
          ? { timer: r.timer, issues: [] }
          : { timer: null, issues: r.issues.map((i) => ({ path: i.path, message: i.message })) },
      };
    }),
    timer_changes: TIMER_CHANGES.map(({ name, base, next }) => ({
      name,
      base,
      next,
      expected: timerChanges(base, next),
    })),
  };
}

// One case per line, like the other vector files.
function serialise(data: ReturnType<typeof generate>): string {
  const section = (items: unknown[]) =>
    `[\n${items.map((x) => `    ${JSON.stringify(x)}`).join(',\n')}\n  ]`;
  return `{\n  "meta": ${JSON.stringify(data.meta)},\n${(
    [
      'new_question',
      'from_question',
      'preview',
      'constraint_text',
      'new_step',
      'from_timer',
      'step_label',
      'timer_output',
      'timer_changes',
    ] as const
  )
    .map((k) => `  "${k}": ${section(data[k])}`)
    .join(',\n')}\n}\n`;
}

describe('builder UI vectors', () => {
  it('runs in en-US', () => {
    expect(new Intl.NumberFormat().resolvedOptions().locale).toBe('en-US');
  });

  it('has timed cases', () => {
    const data = generate();
    expect(data.new_step.length).toBeGreaterThanOrEqual(10);
    expect(data.timer_output.some((c) => c.expected.issues.length > 0)).toBe(true);
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
