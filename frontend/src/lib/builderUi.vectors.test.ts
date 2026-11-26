/**
 * Generator + drift check for shared/fixtures/builder-ui-vectors.json: the builder screens'
 * client-side rules (a new question's draft, the draft a published question opens as, the live
 * preview's best-effort question, the versions list's constraint line; and for timed topics a
 * new step's key, the steps a published timer opens as, renaming, the timer a draft publishes
 * (or its issues) and the review sheet's timing lines), for the iOS port (BUILDER-UI, I-MANAGE). What the server decides is builder-vectors.json (backend).
 *
 * Timer v2 (timers2.md §1.6, §12.1; I1-BUILDER): a new lap type's key and renaming one
 * (`new_lap_type`, `lap_type_label`), a variable as entered (`variable`), an alert's live
 * evaluation (`alert_expr`), and v2 versions of the timer a draft publishes and of the review
 * sheet's lines (`timer_output_v2`, `timer_changes_v2`: normalised `Timer`, issue paths
 * relative to the draft such as `["laps", 0, "key"]`). `timer_output` and `timer_changes` keep
 * their v1 spelling (steps only, paths relative to the steps list) for the v1 Swift port.
 *
 * Text is en-US (the test checks the locale). With QUICKR_UPDATE_VECTORS=1 (`make vectors`)
 * this writes the file; otherwise it fails when the committed file differs.
 */
import { describe, expect, it } from 'vitest';

import {
  alertPreview,
  convertDraftVariable,
  draftFromQuestion,
  draftFromTimer,
  newDraftLapType,
  newDraftQuestion,
  newDraftStep,
  previewQuestion,
  timerChanges,
  timerFromDraft,
  withLapTypeLabel,
  withStepLabel,
  withVariableName,
  type DraftAlert,
  type DraftLapType,
  type DraftOption,
  type DraftQuestion,
  type DraftStep,
  type DraftVariable,
  type TimerHistory,
} from './builder';
import type { TimerInput as Timer } from '../client';
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

type PlainStep = Pick<DraftStep, 'key' | 'label' | 'locked'>;
const plainStep = ({ key, label, locked }: DraftStep): PlainStep => ({ key, label, locked });
const step = (
  key: string,
  label: string,
  locked = false,
  alerts: DraftAlert[] = [],
): DraftStep => ({
  uid: 's',
  key,
  label,
  locked,
  alerts,
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

// ---------------------------------------------------------------------------
// Timer v2 (timers2.md §1)
// ---------------------------------------------------------------------------

type PlainAlert = Omit<DraftAlert, 'uid'>;
type PlainLapType = Omit<DraftLapType, 'uid' | 'alerts'> & { alerts: PlainAlert[] };
type PlainStepV2 = PlainStep & { alerts: PlainAlert[] };
type PlainVariable = Omit<DraftVariable, 'uid'>;
const plainAlert = ({ key, label, at, locked }: DraftAlert): PlainAlert => ({
  key,
  label,
  at,
  locked,
});
const plainLapType = ({ key, label, locked, alerts }: DraftLapType): PlainLapType => ({
  key,
  label,
  locked,
  alerts: alerts.map(plainAlert),
});
const plainStepV2 = (st: DraftStep): PlainStepV2 => ({
  ...plainStep(st),
  alerts: st.alerts.map(plainAlert),
});
const plainVariable = ({ name, duration }: DraftVariable): PlainVariable => ({ name, duration });

const alertOf = (key: string, label: string, at: string, locked = false): DraftAlert => ({
  uid: 'a',
  key,
  label,
  at,
  locked,
});
const lapOf = (
  key: string,
  label: string,
  locked = false,
  alerts: DraftAlert[] = [],
): DraftLapType => ({
  uid: 'l',
  key,
  label,
  locked,
  alerts,
});
const varOf = (name: string, duration: string): DraftVariable => ({ uid: 'v', name, duration });

const TIMER_HISTORY: TimerHistory = {
  steps: [
    { key: 'prep', label: 'Prep' },
    { key: 'run', label: 'Run' },
  ],
  laps: [
    { key: 'jog', label: 'Jog' },
    { key: 'cig', label: 'Cig' },
  ],
};
const NO_HISTORY: TimerHistory = { steps: [], laps: [] };

const NEW_LAP_TYPE: { label: string; taken: string[]; history?: TimerHistory }[] = [
  { label: '', taken: [] },
  { label: '   ', taken: [] },
  { label: 'Run', taken: [] },
  { label: '  Rest  ', taken: [] },
  { label: 'Run', taken: ['run'] },
  { label: 'Run', taken: ['run', 'run_2'] },
  { label: '123', taken: [] },
  { label: '123', taken: ['lap'] },
  { label: 'Café!', taken: [] },
  { label: 'x'.repeat(80), taken: [] },
  { label: 'Jog', taken: [], history: TIMER_HISTORY },
  { label: ' CIG ', taken: [], history: TIMER_HISTORY },
  { label: 'Jog', taken: ['jog'], history: TIMER_HISTORY },
  { label: 'Prep', taken: [], history: TIMER_HISTORY },
  { label: 'Run', taken: [], history: TIMER_HISTORY },
  { label: 'Walk', taken: [], history: TIMER_HISTORY },
];

const LAP_TYPE_LABEL: {
  name: string;
  lap: DraftLapType;
  label: string;
  taken: string[];
  history?: TimerHistory;
}[] = [
  { name: 'published: key kept', lap: lapOf('run', 'Run', true), label: 'Jog', taken: [] },
  { name: 'published: blank keeps key', lap: lapOf('run', 'Run', true), label: '', taken: [] },
  { name: 'new: key follows', lap: lapOf('run', 'Run'), label: 'Sprint', taken: [] },
  { name: 'new: blank clears key', lap: lapOf('run', 'Run'), label: ' ', taken: [] },
  { name: 'new: a step’s key is taken', lap: lapOf('', ''), label: 'Warm', taken: ['warm'] },
  {
    name: 'new: a retired lap type again',
    lap: lapOf('', ''),
    label: 'jog',
    taken: [],
    history: TIMER_HISTORY,
  },
  {
    name: 'new: never a retired step’s key',
    lap: lapOf('', ''),
    label: 'Run',
    taken: [],
    history: TIMER_HISTORY,
  },
  {
    name: 'published: history ignored',
    lap: lapOf('walk', 'Walk', true),
    label: 'Jog',
    taken: [],
    history: TIMER_HISTORY,
  },
];

const VARIABLE: { name: string; duration: string }[] = [
  { name: 't', duration: '1:00' },
  { name: 'T', duration: '1:00' },
  { name: 'Rest', duration: '0:30' },
  { name: 'work_2', duration: '25:00' },
  { name: 'long', duration: '1:30:00' },
  { name: 'fine', duration: '0:01.5' },
  { name: 'zero', duration: '0:00' },
  { name: 'week', duration: '168:00:00' },
  { name: 'week', duration: '168:00:01' },
  { name: '', duration: '1:00' },
  { name: 'x', duration: '' },
  { name: 'm', duration: '1:00' },
  { name: 'MS', duration: '1:00' },
  { name: '2t', duration: '1:00' },
  { name: 'a'.repeat(17), duration: '1:00' },
  { name: 'x', duration: '90' },
  { name: 'x', duration: '1:60' },
  { name: 'x', duration: '-1:00' },
];

const T1 = [varOf('t', '1:00')];
const ALERT_EXPR: { name: string; at: string; variables: DraftVariable[] }[] = [
  { name: 'user half', at: 't*0.5', variables: T1 },
  { name: 'user half spaced', at: 't * 0.5', variables: T1 },
  { name: 'user divide', at: 't/2', variables: T1 },
  { name: 'user plus', at: 't+30s', variables: T1 },
  { name: 'user parens', at: '(t/2)+30s', variables: T1 },
  { name: 'uppercase variable', at: 'T/2', variables: T1 },
  {
    name: 'two variables',
    at: 'work+rest',
    variables: [varOf('work', '25:00'), varOf('rest', '5:00')],
  },
  { name: 'plain seconds', at: '30s', variables: [] },
  { name: 'over an hour', at: '1.5h', variables: [] },
  { name: 'sub-second shows whole seconds', at: '1500ms', variables: [] },
  { name: 'zero', at: 't-t', variables: T1 },
  { name: 'empty', at: '', variables: T1 },
  { name: 'blank', at: '   ', variables: T1 },
  { name: 'trailing operator', at: 't+', variables: T1 },
  { name: 'unknown variable', at: 'x/2', variables: T1 },
  { name: 'variable with a bad duration is unknown', at: 'rest', variables: [varOf('rest', '5')] },
  { name: 'variable with a reserved name is unknown', at: 'm', variables: [varOf('m', '1:00')] },
  { name: 'bare number', at: '30', variables: [] },
  { name: 'duration plus number', at: 't+30', variables: T1 },
  { name: 'division by zero', at: 't/0', variables: T1 },
  { name: 'negative', at: '-t', variables: T1 },
  { name: 'too long value', at: 't*2000', variables: [varOf('t', '1:00:00')] },
  { name: 'too long text', at: `${'t+'.repeat(32)}t`, variables: T1 },
  { name: 'unknown unit', at: '30d', variables: [] },
  { name: 'space before unit', at: '30 s', variables: [] },
  { name: 'unknown character', at: 't\u00a0+30s', variables: T1 },
  { name: 'astral character', at: '😀', variables: T1 },
];

const TIMER_OUTPUT_V2: {
  name: string;
  timed: boolean;
  steps: DraftStep[];
  laps: DraftLapType[];
  variables: DraftVariable[];
}[] = [
  {
    name: 'not timed ignores everything',
    timed: false,
    steps: [],
    laps: [lapOf('', '')],
    variables: [],
  },
  { name: 'stopwatch, normalised', timed: true, steps: [], laps: [], variables: [] },
  {
    name: 'one lap type renames laps',
    timed: true,
    steps: [],
    laps: [lapOf('cig', ' Cig ')],
    variables: [],
  },
  {
    name: 'two lap types with alerts and a variable',
    timed: true,
    steps: [step('warm', 'Warm up', false, [alertOf('go', ' Go ', '1m')])],
    laps: [
      lapOf('run', 'Run', true, [alertOf('half', 'Half', 'T/2'), alertOf('end', 'End', 't')]),
      lapOf('rest', 'Rest', false, [alertOf('up', 'Up', 'rest-10s')]),
    ],
    variables: [varOf('T', '1:00'), varOf('rest', '0:30')],
  },
  {
    name: 'lap key collides with a step',
    timed: true,
    steps: [step('run', 'Run')],
    laps: [lapOf('run', 'Run')],
    variables: [],
  },
  {
    name: 'duplicate lap key',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run'), lapOf('run', 'run')],
    variables: [],
  },
  {
    name: 'lap label 65',
    timed: true,
    steps: [],
    laps: [lapOf('l', 'x'.repeat(65))],
    variables: [],
  },
  { name: 'blank lap label', timed: true, steps: [], laps: [lapOf('', ' ')], variables: [] },
  { name: 'bad lap key', timed: true, steps: [], laps: [lapOf('Run', 'Run')], variables: [] },
  {
    name: 'laps max',
    timed: true,
    steps: [],
    laps: Array.from({ length: 8 }, (_, i) => lapOf(`l${String(i)}`, `L${String(i)}`)),
    variables: [],
  },
  {
    name: 'laps too many',
    timed: true,
    steps: [],
    laps: Array.from({ length: 9 }, (_, i) => lapOf(`l${String(i)}`, `L${String(i)}`)),
    variables: [],
  },
  {
    name: 'variables max',
    timed: true,
    steps: [],
    laps: [],
    variables: Array.from({ length: 16 }, (_, i) => varOf(`v${String(i)}`, '0:01')),
  },
  {
    name: 'variables too many',
    timed: true,
    steps: [],
    laps: [],
    variables: Array.from({ length: 17 }, (_, i) => varOf(`v${String(i)}`, '0:01')),
  },
  {
    name: 'variable name duplicate case',
    timed: true,
    steps: [],
    laps: [],
    variables: [varOf('t', '1:00'), varOf('T', '2:00')],
  },
  {
    name: 'variable name reserved unit',
    timed: true,
    steps: [],
    laps: [],
    variables: [varOf('m', '1:00')],
  },
  {
    name: 'variable over 7 days',
    timed: true,
    steps: [],
    laps: [],
    variables: [varOf('t', '168:00:01')],
  },
  {
    name: 'alerts max',
    timed: true,
    steps: [],
    laps: [
      lapOf(
        'run',
        'Run',
        false,
        Array.from({ length: 8 }, (_, i) => alertOf(`a${String(i)}`, `A${String(i)}`, '1s')),
      ),
    ],
    variables: [],
  },
  {
    name: 'alerts too many',
    timed: true,
    steps: [
      step(
        'warm',
        'Warm',
        false,
        Array.from({ length: 9 }, (_, i) => alertOf(`a${String(i)}`, `A${String(i)}`, '1s')),
      ),
    ],
    laps: [],
    variables: [],
  },
  {
    name: 'alert key duplicate',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'A', '1s'), alertOf('a', 'B', '2s')])],
    variables: [],
  },
  {
    name: 'alert blank label',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('', ' ', '1s')])],
    variables: [],
  },
  {
    name: 'alert label 65',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'x'.repeat(65), '1s')])],
    variables: [],
  },
  {
    name: 'alert expression syntax',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'A', 't+')])],
    variables: [varOf('t', '1:00')],
  },
  {
    name: 'alert expression unknown variable',
    timed: true,
    steps: [step('warm', 'Warm', false, [alertOf('a', 'A', 'x/2')])],
    laps: [],
    variables: [varOf('t', '1:00')],
  },
  {
    name: 'alert expression type',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'A', 't+30')])],
    variables: [varOf('t', '1:00')],
  },
  {
    name: 'alert expression 65 chars',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'A', `${'t+'.repeat(32)}t`)])],
    variables: [varOf('t', '1:00')],
  },
  {
    name: 'alert expression not trimmed',
    timed: true,
    steps: [],
    laps: [lapOf('run', 'Run', false, [alertOf('a', 'A', ' t / 2 ')])],
    variables: [varOf('t', '1:00')],
  },
];

const run = { key: 'run', label: 'Run', alerts: [] };
const rest = { key: 'rest', label: 'Rest', alerts: [] };
const half = { key: 'half', label: 'Half', at: 't/2', at_ms: 30_000 };
const tVar = { name: 't', ms: 60_000 };
const v2 = (over: Partial<Timer> = {}): Timer => ({
  steps: [{ key: 'warm', label: 'Warm up', alerts: [] }],
  laps: [{ ...run, alerts: [half] }, rest],
  variables: [tVar],
  ...over,
});
const TIMER_CHANGES_V2: { name: string; base: Timer | null; next: Timer | null }[] = [
  { name: 'unchanged', base: v2(), next: v2() },
  {
    name: 'v1 shape equals its normalised form',
    base: { steps: [shower] },
    next: { steps: [{ ...shower, alerts: [] }], laps: [], variables: [] },
  },
  { name: 'turned on with lap types', base: null, next: v2({ steps: [] }) },
  { name: 'turned on with steps and lap types', base: null, next: v2() },
  { name: 'turned off', base: v2(), next: null },
  {
    name: 'lap type renamed',
    base: v2(),
    next: v2({ laps: [{ ...run, label: 'Jog', alerts: [half] }, rest] }),
  },
  {
    name: 'lap type added',
    base: v2(),
    next: v2({
      laps: [{ ...run, alerts: [half] }, rest, { key: 'walk', label: 'Walk', alerts: [] }],
    }),
  },
  { name: 'lap type removed', base: v2(), next: v2({ laps: [{ ...run, alerts: [half] }] }) },
  {
    name: 'lap types reordered',
    base: v2(),
    next: v2({ laps: [rest, { ...run, alerts: [half] }] }),
  },
  {
    name: 'variable added',
    base: v2(),
    next: v2({ variables: [tVar, { name: 'rest', ms: 30_000 }] }),
  },
  { name: 'variable changed', base: v2(), next: v2({ variables: [{ name: 't', ms: 90_500 }] }) },
  { name: 'variable removed', base: v2(), next: v2({ variables: [] }) },
  {
    name: 'alert added',
    base: v2(),
    next: v2({
      laps: [
        { ...run, alerts: [half] },
        { ...rest, alerts: [{ key: 'up', label: 'Up', at: '20s' }] },
      ],
    }),
  },
  { name: 'alert removed', base: v2(), next: v2({ laps: [run, rest] }) },
  {
    name: 'alert renamed',
    base: v2(),
    next: v2({ laps: [{ ...run, alerts: [{ ...half, label: 'Halfway' }] }, rest] }),
  },
  {
    name: 'alert changed',
    base: v2(),
    next: v2({ laps: [{ ...run, alerts: [{ ...half, at: 't/3', at_ms: 20_000 }] }, rest] }),
  },
  {
    name: 'alert at_ms alone is no change',
    base: v2(),
    next: v2({ laps: [{ ...run, alerts: [{ ...half, at_ms: 1 }] }, rest] }),
  },
  {
    name: 'alert on a step',
    base: v2(),
    next: v2({
      steps: [{ key: 'warm', label: 'Warm up', alerts: [{ key: 'go', label: 'Go', at: '1m' }] }],
    }),
  },
  { name: 'alerts of a removed lap type are not listed', base: v2(), next: v2({ laps: [rest] }) },
  {
    name: 'everything at once',
    base: v2(),
    next: {
      steps: [{ key: 'cool', label: 'Cool down', alerts: [] }],
      laps: [{ ...rest, label: 'Breathe', alerts: [{ key: 'up', label: 'Up', at: 't' }] }],
      variables: [
        { name: 't', ms: 120_000 },
        { name: 'r', ms: 1_000 },
      ],
    },
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
    // v1 spelling: the timer's steps only, paths relative to the steps list.
    timer_output: TIMER_OUTPUT.map(({ name, timed, steps }) => {
      const r = timerFromDraft({ timed, steps, laps: [], variables: [] });
      return {
        name,
        timed,
        steps: steps.map(plainStep),
        expected: r.ok
          ? {
              timer: r.timer && { steps: r.timer.steps.map(({ key, label }) => ({ key, label })) },
              issues: [],
            }
          : {
              timer: null,
              issues: r.issues.map((i) => ({ path: stepsRelative(i.path), message: i.message })),
            },
      };
    }),
    timer_changes: TIMER_CHANGES.map(({ name, base, next }) => ({
      name,
      base,
      next,
      expected: timerChanges(base, next),
    })),
    new_lap_type: NEW_LAP_TYPE.map(({ label, taken, history = NO_HISTORY }) => ({
      label,
      taken,
      history,
      expected: plainLapType(newDraftLapType(label, taken, history)),
    })),
    lap_type_label: LAP_TYPE_LABEL.map(({ name, lap, label, taken, history = NO_HISTORY }) => ({
      name,
      lap_type: plainLapType(lap),
      label,
      taken,
      history,
      expected: plainLapType(withLapTypeLabel(lap, label, taken, history)),
    })),
    variable: VARIABLE.map(({ name, duration }) => {
      const entered = withVariableName({ uid: 'v', name: '', duration }, name);
      const r = convertDraftVariable(entered);
      return {
        name,
        duration,
        expected: {
          name: entered.name,
          variable: r.ok ? r.variable : null,
          issues: r.ok ? [] : r.issues.map((i) => ({ path: i.path, message: i.message })),
        },
      };
    }),
    alert_expr: ALERT_EXPR.map(({ name, at, variables }) => {
      const r = alertPreview(at, variables);
      return {
        name,
        at,
        variables: variables.map(plainVariable),
        expected: r.ok ? { ms: r.ms, text: r.text } : { error: r.message, pos: r.pos },
      };
    }),
    timer_output_v2: TIMER_OUTPUT_V2.map(({ name, timed, steps, laps, variables }) => {
      const r = timerFromDraft({ timed, steps, laps, variables });
      return {
        name,
        draft: {
          timed,
          steps: steps.map(plainStepV2),
          laps: laps.map(plainLapType),
          variables: variables.map(plainVariable),
        },
        expected: r.ok
          ? { timer: r.timer, issues: [] }
          : { timer: null, issues: r.issues.map((i) => ({ path: i.path, message: i.message })) },
      };
    }),
    timer_changes_v2: TIMER_CHANGES_V2.map(({ name, base, next }) => ({
      name,
      base,
      next,
      expected: timerChanges(base, next),
    })),
  };
}

/** A v1 issue path: relative to the steps list (every v1 case's issues are the steps'). */
function stepsRelative(path: (string | number)[]): (string | number)[] {
  if (path[0] !== 'steps') throw new Error(`not a steps issue: ${path.join('.')}`);
  return path.slice(1);
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
      'new_lap_type',
      'lap_type_label',
      'variable',
      'alert_expr',
      'timer_output_v2',
      'timer_changes_v2',
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

  it('has the timer v2 cases (timers2.md §1.3, §1.6, §12.1)', () => {
    const data = generate();
    expect(data.new_lap_type.length).toBeGreaterThanOrEqual(14);
    expect(data.lap_type_label.length).toBeGreaterThanOrEqual(8);
    expect(data.variable.some((c) => c.expected.issues.length > 0)).toBe(true);
    expect(data.variable.some((c) => c.expected.name !== c.name)).toBe(true);
    expect(data.alert_expr.some((c) => 'ms' in c.expected)).toBe(true);
    expect(
      new Set(
        data.alert_expr.map((c) => ('error' in c.expected ? c.expected.error.split(' ')[0] : 'ok')),
      ),
    ).toEqual(
      new Set(['ok', 'Syntax', 'Unknown_variable', 'Type', 'Div_zero', 'Negative', 'Too_long']),
    );
    // Every §1.3 builder rule the client checks has a case, by name.
    const names = new Set(data.timer_output_v2.map((c) => c.name));
    for (const n of [
      'one lap type renames laps',
      'two lap types with alerts and a variable',
      'lap key collides with a step',
      'lap label 65',
      'laps max',
      'laps too many',
      'variables max',
      'variables too many',
      'variable name duplicate case',
      'variable name reserved unit',
      'variable over 7 days',
      'alerts max',
      'alerts too many',
      'alert key duplicate',
      'alert expression syntax',
      'alert expression unknown variable',
      'alert expression type',
      'alert expression 65 chars',
    ])
      expect(names, n).toContain(n);
    expect(data.timer_output_v2.some((c) => c.expected.issues.length > 0)).toBe(true);
    expect(data.timer_changes_v2.length).toBeGreaterThanOrEqual(19);
    expect(new Set(data.timer_changes_v2.map((c) => c.name)).size).toBe(
      data.timer_changes_v2.length,
    );
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
