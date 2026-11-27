import { describe, expect, it } from 'vitest';

import { FALLBACK_LIMITS } from '../api/limits';
import { builderFieldFor } from '../components/builder/serverErrors';
import {
  alertPreview,
  appearanceChanges,
  appearanceDraftOf,
  emptyTopicDraft,
  makeAppearanceSchema,
  makeTopicDraftAppearanceSchema,
  makeTopicMetaAppearanceSchema,
  convertDraftQuestion,
  durationText,
  newDraftAlert,
  newDraftLapType,
  newDraftVariable,
  parseDurationText,
  timerFromDraft,
  timerIssues,
  timerHistory,
  withAlertLabel,
  withLapTypeLabel,
  withVariableName,
  type DraftAlert,
  type DraftLapType,
  type DraftStep,
  type DraftVariable,
  draftFromQuestion,
  draftFromTimer,
  newDraftStep,
  stepHistory,
  stepIssues,
  timerChanges,
  withStepLabel,
  newDraftOption,
  newDraftQuestion,
  previewQuestion,
  slugify,
  toSnakeKey,
  makeTopicDraftSchema,
  makeVersionDraftSchema,
  uniqueKey,
  withLabel,
  type DraftQuestion,
} from './builder';
import { cleanMessage } from '../api/errors';
import type { Question } from './questions';
import { emptyScheduleDraft } from './schedule';

const topicDraftSchema = makeTopicDraftSchema();
const versionDraftSchema = makeVersionDraftSchema();
const schedule = emptyScheduleDraft('UTC');

function draft(type: DraftQuestion['type'], patch: Partial<DraftQuestion> = {}): DraftQuestion {
  return { ...newDraftQuestion(type), key: 'q', label: 'Q', ...patch };
}

function issuesOf(d: DraftQuestion): Record<string, string> {
  const r = convertDraftQuestion(d);
  return r.ok ? {} : Object.fromEntries(r.issues.map((i) => [i.path.join('.'), i.message]));
}

describe('naming helpers', () => {
  it('toSnakeKey produces valid keys', () => {
    expect(toSnakeKey('Hours slept (approx.)')).toBe('hours_slept_approx');
    expect(toSnakeKey('  Café au lait! ')).toBe('cafe_au_lait');
    expect(toSnakeKey('2nd try')).toBe('nd_try');
    expect(toSnakeKey('!!!')).toBe('');
    expect(toSnakeKey('x'.repeat(100))).toHaveLength(63);
  });

  it('slugify mirrors the backend', () => {
    expect(slugify('Sleep Log — 2026')).toBe('sleep-log-2026');
    expect(slugify('  --Hello__World-- ')).toBe('hello-world');
  });

  it('uniqueKey appends a counter', () => {
    expect(uniqueKey('mood', [])).toBe('mood');
    expect(uniqueKey('mood', ['mood', 'mood_2'])).toBe('mood_3');
    expect(uniqueKey('', [])).toBe('question');
  });

  it('withLabel derives the key until it is edited or locked', () => {
    const q = newDraftQuestion('int');
    expect(withLabel(q, 'Glasses of water', []).key).toBe('glasses_of_water');
    expect(withLabel(q, 'Mood', ['mood']).key).toBe('mood_2');
    expect(withLabel({ ...q, key: 'custom', keyEdited: true }, 'Other', []).key).toBe('custom');
    expect(withLabel({ ...q, key: 'fixed', locked: true }, 'Other', []).key).toBe('fixed');
  });

  it('newDraftOption derives a unique value', () => {
    expect(newDraftOption('Very good', ['very_good']).value).toBe('very_good_2');
  });
});

describe('convertDraftQuestion', () => {
  it('converts numeric drafts', () => {
    const r = convertDraftQuestion(
      draft('double', { min: '0', max: '24,5', unit: ' h ', decimals: '1', help_text: '' }),
    );
    expect(r).toEqual({
      ok: true,
      question: {
        key: 'q',
        label: 'Q',
        help_text: null,
        required: true,
        type: 'double',
        min: 0,
        max: 24.5,
        unit: 'h',
        decimals: 1,
      },
    });
  });

  it('requires min <= max and integer bounds for int', () => {
    expect(issuesOf(draft('int', { min: '5', max: '1' }))).toEqual({ max: 'Max must be ≥ min' });
    expect(issuesOf(draft('int', { min: '1.5' }))).toEqual({ min: 'Must be a whole number' });
    expect(issuesOf(draft('double', { decimals: '11' }))).toEqual({
      decimals: 'Must be at most 10',
    });
  });

  it('validates key format and label presence', () => {
    expect(issuesOf(draft('int', { key: 'Bad Key', label: ' ' }))).toEqual({
      key: 'Use lower_snake_case: a–z, 0–9, _ (start with a letter, max 63)',
      label: 'Required',
    });
  });

  it('validates string lengths', () => {
    expect(issuesOf(draft('str', { min_length: '10', max_length: '5' }))).toEqual({
      max_length: 'Max length must be ≥ min length',
    });
    expect(issuesOf(draft('str', { max_length: '0' }))).toEqual({
      max_length: 'Must be at least 1',
    });
  });

  it('requires at least one active, uniquely-valued enum option', () => {
    const a = newDraftOption('A');
    expect(issuesOf(draft('enum', { options: [{ ...a, archived: true }] }))).toEqual({
      options: 'At least one option must be active',
    });
    expect(issuesOf(draft('enum', { options: [] }))).toEqual({
      options: 'Add at least one option',
    });
    expect(issuesOf(draft('enum', { options: [a, { ...newDraftOption('A'), uid: 'x' }] }))).toEqual(
      {
        'options.1.value': 'Another option has this value',
        'options.1.label': 'Another option has this label',
      },
    );
  });
});

describe('topicDraftSchema', () => {
  it('outputs a TopicCreate body', () => {
    const r = topicDraftSchema.safeParse({
      name: ' Sleep ',
      slug: '',
      slugEdited: false,
      description: '',
      change_note: '',
      schedule,
      timed: false,
      steps: [],
      laps: [],
      variables: [],
      questions: [draft('int', { key: 'hours' })],
    });
    expect(r.success).toBe(true);
    expect(r.data).toMatchObject({ name: 'Sleep', slug: null, description: '' });
    expect(r.data?.questions[0]).toMatchObject({ key: 'hours', type: 'int' });
  });

  it('reports duplicate keys and bad slugs at field paths, and allows no questions', () => {
    const dup = topicDraftSchema.safeParse({
      name: 'x',
      slug: 'Bad Slug',
      slugEdited: true,
      description: '',
      change_note: '',
      schedule,
      timed: false,
      steps: [],
      laps: [],
      variables: [],
      questions: [draft('int', { key: 'a' }), draft('str', { key: 'a' })],
    });
    expect(dup.success).toBe(false);
    const paths = dup.error?.issues.map((i) => i.path.join('.'));
    expect(paths).toContain('slug');
    expect(paths).toContain('questions.1.key');

    const none = topicDraftSchema.safeParse({
      name: '',
      slug: '',
      slugEdited: false,
      description: '',
      change_note: '',
      schedule,
      timed: false,
      steps: [],
      laps: [],
      variables: [],
      questions: [],
    });
    // No questions is allowed (a single topic, logged with one tap): only the name is missing.
    expect(none.error?.issues.map((i) => i.path.join('.'))).toEqual(['name']);
  });

  it('versionDraftSchema validates questions + note', () => {
    const r = versionDraftSchema.safeParse({
      name: 'x',
      slug: 'x',
      slugEdited: true,
      description: '',
      questions: [draft('int')],
      change_note: ' hi ',
      schedule,
      timed: false,
      steps: [],
      laps: [],
      variables: [],
    });
    expect(r.data?.change_note).toBe('hi');
  });
});

describe('draftFromQuestion / previewQuestion', () => {
  const published: Question = {
    key: 'mood',
    label: 'Mood',
    help_text: 'How was it?',
    required: false,
    type: 'enum',
    options: [
      { value: 'good', label: 'Good', archived: false },
      { value: 'bad', label: 'Bad', archived: true },
    ],
    multiple: false,
    min_selected: null,
    max_selected: null,
  };

  it('round-trips a published question', () => {
    const d = draftFromQuestion(published, true);
    expect(d.locked).toBe(true);
    expect(d.options.every((o) => o.locked)).toBe(true);
    const r = convertDraftQuestion(d);
    expect(r.ok && r.question).toEqual(published);
  });

  it('previews incomplete drafts with placeholders', () => {
    const p = previewQuestion(newDraftQuestion('int'), 2);
    expect(p).toMatchObject({ key: 'question_3', label: 'Question 3', type: 'int' });
    const broken = previewQuestion(draft('int', { min: '9', max: '1' }), 0);
    expect(broken).toMatchObject({ min: null, max: null });
  });
});

describe('timer drafts (timers.md §2.1)', () => {
  const base = { name: 'Morning', slug: '', slugEdited: false, description: '', change_note: '' };

  it('a new step derives its key from its label, unique among the others', () => {
    expect(newDraftStep('Brush teeth', [])).toMatchObject({ key: 'brush_teeth', locked: false });
    expect(newDraftStep('Brush teeth', ['brush_teeth']).key).toBe('brush_teeth_2');
    expect(newDraftStep('123', []).key).toBe('step');
    expect(newDraftStep('   ', []).key).toBe('');
  });

  it('renaming keeps a published step’s key and re-derives a new one’s', () => {
    const [published] = draftFromTimer({ steps: [{ key: 'shower', label: 'Shower' }] }).steps;
    if (!published) throw new Error('no step');
    expect(withStepLabel(published, 'Bath', [])).toMatchObject({ key: 'shower', label: 'Bath' });
    expect(withStepLabel(newDraftStep('Shower'), 'Bath', []).key).toBe('bath');
  });

  it('publish sends the steps in order with their stable keys, or null when not timed', () => {
    const timer = {
      steps: [
        { key: 'shower', label: 'Shower' },
        { key: 'dress', label: 'Dress' },
      ],
    };
    const d = draftFromTimer(timer);
    const [shower, dress] = d.steps;
    if (!shower || !dress) throw new Error('no steps');
    const steps = [dress, withStepLabel(shower, ' Bath ', ['dress']), newDraftStep('Coffee', [])];
    const r = versionDraftSchema.safeParse({
      ...base,
      questions: [],
      schedule,
      timed: true,
      steps,
      laps: [],
      variables: [],
    });
    expect(r.data?.timer).toEqual({
      steps: [
        { key: 'dress', label: 'Dress', alerts: [] },
        { key: 'shower', label: 'Bath', alerts: [] },
        { key: 'coffee', label: 'Coffee', alerts: [] },
      ],
      laps: [],
      variables: [],
    });
    const off = versionDraftSchema.safeParse({
      ...base,
      questions: [],
      schedule,
      ...draftFromTimer(null),
    });
    expect(off.data?.timer).toBeNull();
    const stopwatch = topicDraftSchema.safeParse({
      ...base,
      questions: [],
      schedule,
      timed: true,
      steps: [],
      laps: [],
      variables: [],
    });
    expect(stopwatch.data?.timer).toEqual({ steps: [], laps: [], variables: [] });
  });

  it('refuses blank, duplicate and too many steps at their paths', () => {
    const issues = stepIssues([
      { key: '', label: ' ' },
      { key: 'a', label: 'A' },
      { key: 'a', label: 'a' },
    ]);
    expect(issues.map((i) => [i.path.join('.'), i.message])).toEqual([
      ['0.label', 'Required'],
      ['2.key', 'Another step has this key'],
    ]);
    // Labels may repeat (the server allows it): only keys must be unique.
    expect(
      stepIssues([
        { key: 'a', label: 'Rinse' },
        { key: 'b', label: 'rinse' },
      ]),
    ).toEqual([]);
    const many = Array.from({ length: 31 }, (_, i) => ({
      key: `s${String(i)}`,
      label: `S${String(i)}`,
    }));
    expect(stepIssues(many).map((i) => i.message)).toEqual(['At most 30 steps']);
    const r = versionDraftSchema.safeParse({
      ...base,
      questions: [],
      schedule,
      timed: true,
      steps: [newDraftStep('')],
      laps: [],
      variables: [],
    });
    expect(r.error?.issues.map((i) => i.path.join('.'))).toEqual(['steps.0.label']);
  });

  it('a retired step’s key is reused only by the same step, never by another', () => {
    const history = stepHistory([
      { version: 2, timer: { steps: [{ key: 'shower', label: 'Shower' }] } },
      {
        version: 1,
        timer: {
          steps: [
            { key: 'prep', label: 'Old prep' },
            { key: 'shower', label: 'Wash' },
          ],
        },
      },
      { version: 3, timer: null },
    ]);
    expect(history).toEqual([
      { key: 'prep', label: 'Old prep' },
      { key: 'shower', label: 'Shower' },
    ]);
    // Same (folded) label as a retired step: it is that step again.
    expect(newDraftStep('  old PREP ', [], history).key).toBe('prep');
    // A different step that would derive a retired key gets a fresh one.
    expect(newDraftStep('Prep', [], history).key).toBe('prep_2');
    // A retired key already used by another draft step isn't reused.
    expect(newDraftStep('Old prep', ['prep'], history).key).toBe('old_prep');
    expect(withStepLabel(newDraftStep(''), 'Shower', [], history).key).toBe('shower');
    expect(withStepLabel(newDraftStep(''), 'Shower', ['shower'], history).key).toBe('shower_2');
  });

  it('timerChanges names what the review sheet shows', () => {
    const a = {
      steps: [
        { key: 'x', label: 'X' },
        { key: 'y', label: 'Y' },
      ],
    };
    expect(timerChanges(null, null)).toEqual([]);
    expect(timerChanges(a, a)).toEqual([]);
    expect(timerChanges(null, a)).toEqual(['Timed, with 2 steps']);
    expect(timerChanges(null, { steps: [] })).toEqual(['Timed, as a stopwatch (no steps)']);
    expect(timerChanges(a, null)).toEqual(['No longer timed']);
    expect(
      timerChanges(a, {
        steps: [
          { key: 'z', label: 'Z' },
          { key: 'y', label: 'Why' },
          { key: 'x', label: 'X' },
        ],
      }),
    ).toEqual(['Step added: Z', 'Step renamed: Y → Why', 'Steps reordered']);
    expect(timerChanges(a, { steps: [{ key: 'y', label: 'Y' }] })).toEqual(['Step removed: X']);
  });
});

describe('timer v2 drafts (timers2.md §1)', () => {
  const base = { name: 'Run', slug: '', slugEdited: false, description: '', change_note: '' };
  const alert = (label: string, at: string, key = '', locked = false): DraftAlert => ({
    uid: 'a',
    key,
    label,
    at,
    locked,
  });
  const lapType = (
    key: string,
    label: string,
    alerts: DraftAlert[] = [],
    locked = false,
  ): DraftLapType => ({ uid: 'l', key, label, locked, alerts });
  const stepOf = (key: string, label: string, alerts: DraftAlert[] = []): DraftStep => ({
    uid: 's',
    key,
    label,
    locked: false,
    alerts,
  });
  const variable = (name: string, duration: string): DraftVariable => ({
    uid: 'v',
    name,
    duration,
  });
  const v2 = {
    steps: [{ key: 'warm', label: 'Warm up', alerts: [{ key: 'go', label: 'Go', at: '1m' }] }],
    laps: [
      { key: 'run', label: 'Run', alerts: [{ key: 'half', label: 'Half', at: 't/2' }] },
      { key: 'rest', label: 'Rest' },
    ],
    variables: [{ name: 't', ms: 60_000 }],
  };
  const pathsOf = (issues: { path: (string | number)[]; message: string }[]) =>
    issues.map((i) => [i.path.join('.'), i.message]);

  it('opens a published v2 timer locked, with its lap types, variables and alerts', () => {
    const d = draftFromTimer(v2);
    expect(d.timed).toBe(true);
    expect(d.steps.map((x) => [x.key, x.label, x.locked, x.alerts.map((a) => a.key)])).toEqual([
      ['warm', 'Warm up', true, ['go']],
    ]);
    expect(d.laps.map((x) => [x.key, x.label, x.locked])).toEqual([
      ['run', 'Run', true],
      ['rest', 'Rest', true],
    ]);
    expect(d.laps[0]?.alerts.map((a) => [a.key, a.label, a.at, a.locked])).toEqual([
      ['half', 'Half', 't/2', true],
    ]);
    expect(d.laps[1]?.alerts).toEqual([]);
    expect(d.variables.map((x) => [x.name, x.duration])).toEqual([['t', '1:00']]);
    // A v1 timer opens with none of them.
    const v1 = draftFromTimer({ steps: [{ key: 'a', label: 'A' }] });
    expect([v1.laps, v1.variables, v1.steps[0]?.alerts]).toEqual([[], [], []]);
    expect(draftFromTimer(null)).toMatchObject({
      timed: false,
      steps: [],
      laps: [],
      variables: [],
    });
  });

  it('trims labels and keys as the server does (pydantic strip: U+0085 goes, U+FEFF stays) (P3-3)', () => {
    const nel = '\u0085';
    const bom = '\ufeff';
    // A label of U+0085 alone is empty to the server (422): Required here too.
    const blank = timerIssues({
      timed: true,
      steps: [stepOf('a', nel)],
      laps: [lapType('b', nel, [alert(nel, '1s', 'c')])],
      variables: [],
    });
    expect(pathsOf(blank)).toEqual(
      expect.arrayContaining([
        ['steps.0.label', 'Required'],
        ['laps.0.label', 'Required'],
        ['laps.0.alerts.0.label', 'Required'],
      ]),
    );
    // A label of U+FEFF alone is kept by the server: accepted, and stored as sent.
    const r = timerFromDraft({
      timed: true,
      steps: [stepOf(`${nel}a${nel}`, `${nel}${bom}${nel}`)],
      laps: [lapType('b', bom, [alert(bom, '1s', `${nel}c`)])],
      variables: [],
    });
    expect(r).toEqual({
      ok: true,
      timer: {
        steps: [{ key: 'a', label: bom, alerts: [] }],
        laps: [{ key: 'b', label: bom, alerts: [{ key: 'c', label: bom, at: '1s', at_ms: 1000 }] }],
        variables: [],
      },
    });
  });

  it('publish sends a normalised v2 timer: every list present, at_ms filled', () => {
    const d = draftFromTimer(v2);
    const r = timerFromDraft(d);
    expect(r).toEqual({
      ok: true,
      timer: {
        steps: [
          {
            key: 'warm',
            label: 'Warm up',
            alerts: [{ key: 'go', label: 'Go', at: '1m', at_ms: 60_000 }],
          },
        ],
        laps: [
          {
            key: 'run',
            label: 'Run',
            alerts: [{ key: 'half', label: 'Half', at: 't/2', at_ms: 30_000 }],
          },
          { key: 'rest', label: 'Rest', alerts: [] },
        ],
        variables: [{ name: 't', ms: 60_000 }],
      },
    });
    const sent = versionDraftSchema.safeParse({ ...base, questions: [], schedule, ...d });
    expect(sent.data?.timer).toEqual(r.ok ? r.timer : null);
    expect(timerFromDraft({ ...d, timed: false })).toEqual({ ok: true, timer: null });
  });

  it('keys of steps and lap types share one namespace', () => {
    const history = timerHistory([
      {
        version: 1,
        timer: { steps: [{ key: 'prep', label: 'Prep' }], laps: [{ key: 'jog', label: 'Jog' }] },
      },
      { version: 2, timer: { steps: [{ key: 'run', label: 'Run' }] } },
    ]);
    expect(history).toEqual({
      steps: [
        { key: 'prep', label: 'Prep' },
        { key: 'run', label: 'Run' },
      ],
      laps: [{ key: 'jog', label: 'Jog' }],
    });
    // A lap type avoids the draft's step keys and every historic key, and takes a retired lap
    // type's key back only when it is that lap type.
    expect(newDraftLapType('Run', ['run'], history).key).toBe('run_2');
    expect(newDraftLapType('Prep', [], history).key).toBe('prep_2');
    expect(newDraftLapType('  JOG ', [], history).key).toBe('jog');
    expect(newDraftLapType('Rest', [], history)).toMatchObject({
      key: 'rest',
      label: 'Rest',
      locked: false,
      alerts: [],
    });
    expect(newDraftLapType('123', []).key).toBe('lap');
    expect(newDraftLapType('  ', []).key).toBe('');
  });

  it('a published lap type keeps its key on rename; a new one follows its label', () => {
    const [run] = draftFromTimer(v2).laps;
    if (!run) throw new Error('no lap type');
    expect(withLapTypeLabel(run, 'Jog', [])).toMatchObject({ key: 'run', label: 'Jog' });
    const fresh = newDraftLapType('Run', []);
    expect(withLapTypeLabel(fresh, 'Sprint', ['sprint']).key).toBe('sprint_2');
    expect(withLapTypeLabel(fresh, ' ', []).key).toBe('');
  });

  it('a new alert’s key follows its label, unique within its owner; a published one’s stays', () => {
    expect(newDraftAlert('Half way', [])).toMatchObject({ key: 'half_way', at: '', locked: false });
    expect(newDraftAlert('Half', ['half']).key).toBe('half_2');
    expect(newDraftAlert('!!', []).key).toBe('alert');
    expect(withAlertLabel(alert('Half', 't/2', 'half', true), 'Mid', []).key).toBe('half');
    expect(withAlertLabel(alert('Half', 't/2', 'half'), 'Mid', []).key).toBe('mid');
  });

  it('variable names are lowercased on entry; durations are m:ss or h:mm:ss', () => {
    expect(withVariableName(newDraftVariable(), 'Rest').name).toBe('rest');
    expect(parseDurationText('1:30')).toBe(90_000);
    expect(parseDurationText(' 0:05 ')).toBe(5_000);
    expect(parseDurationText('90:00')).toBe(5_400_000);
    expect(parseDurationText('1:00:00')).toBe(3_600_000);
    expect(parseDurationText('0:01.5')).toBe(1_500);
    for (const bad of ['', '90', '1:60', '1:5', 'a:00', '1:00:60', '-1:00'])
      expect(parseDurationText(bad), bad).toBeNull();
    expect(durationText(90_000)).toBe('1:30');
    expect(durationText(3_600_000)).toBe('1:00:00');
    expect(durationText(1_500)).toBe('0:01.500');
  });

  it('refuses lap types, variables and alerts at the server’s paths', () => {
    const r = timerFromDraft({
      timed: true,
      steps: [stepOf('run', 'Run', [alert('Half', 'x/2', 'half'), alert('Again', 't', 'half')])],
      laps: [
        lapType('run', 'Running'),
        lapType('rest', 'x'.repeat(65)),
        lapType('rest', 'Rest', [alert('', 't')]),
      ],
      variables: [
        variable('t', '1:00'),
        variable('T', '2:00'),
        variable('m', '1:00'),
        variable('ok', '1:99'),
      ],
    });
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(pathsOf(r.issues)).toEqual([
      ['laps.0.key', 'A step has this key'],
      ['laps.1.label', 'At most 64 characters (65 now)'],
      ['laps.2.key', 'Another lap type has this key'],
      ['variables.2.name', "'m' is a unit (ms, s, m, h) and can't be a variable name"],
      ['variables.3.duration', 'Enter m:ss or h:mm:ss'],
      ['variables.1.name', 'Another variable has this name'],
      ['steps.0.alerts.1.key', 'Another alert here has this key'],
      ['laps.2.alerts.0.label', 'Required'],
      ['steps.0.alerts.0.at', "Unknown_variable at 0: unknown variable 'x'"],
    ]);
  });

  it('caps lap types, variables, alerts and durations at the limits', () => {
    const laps = Array.from({ length: 9 }, (_, i) => lapType(`l${String(i)}`, `L${String(i)}`));
    const variables = Array.from({ length: 17 }, (_, i) => variable(`v${String(i)}`, '0:01'));
    const alerts = Array.from({ length: 9 }, (_, i) =>
      alert(`A${String(i)}`, '1s', `a${String(i)}`),
    );
    const r = timerFromDraft({ timed: true, steps: [stepOf('s', 'S', alerts)], laps, variables });
    expect(r.ok ? [] : pathsOf(r.issues)).toEqual([
      ['laps', 'At most 8 lap types'],
      ['variables', 'At most 16 variables'],
      ['steps.0.alerts', 'At most 8 alerts'],
    ]);
    const long = timerFromDraft({
      timed: true,
      steps: [],
      laps: [],
      variables: [variable('t', '168:00:01'), variable('toolongvariablename', '0:01')],
    });
    expect(long.ok ? [] : pathsOf(long.issues)).toEqual([
      ['variables.0.duration', 'At most 7 days'],
      ['variables.1.name', 'Use a–z, 0–9, _ (start with a letter, max 16)'],
    ]);
  });

  it('evaluates an alert live with the draft’s variables', () => {
    const vars = [variable('T', '1:00'), variable('rest', 'bad')];
    expect(alertPreview('t/2', vars)).toEqual({ ok: true, ms: 30_000, text: '0:30' });
    expect(alertPreview('(t/2)+30s', vars)).toEqual({ ok: true, ms: 60_000, text: '1:00' });
    // A variable with no valid duration isn't one yet.
    expect(alertPreview('rest', vars)).toEqual({
      ok: false,
      pos: 0,
      message: "Unknown_variable at 0: unknown variable 'rest'",
    });
    // The server's message (no "Value error, " prefix: it is a PydanticCustomError) reads the
    // same through cleanMessage, even with a '[' in it.
    expect(alertPreview('t+[x', vars)).toEqual({
      ok: false,
      pos: 2,
      message: cleanMessage("syntax at 2: unknown character '['"),
    });
    expect(cleanMessage("syntax at 2: unknown character '['")).toBe(
      "Syntax at 2: unknown character '['",
    );
    expect(alertPreview('t+', vars)).toEqual({
      ok: false,
      pos: 2,
      message: 'Syntax at 2: unexpected end',
    });
  });

  it('the versions schema reports timer issues next to the questions’', () => {
    const r = versionDraftSchema.safeParse({
      ...base,
      questions: [draft('int', { key: '', label: 'N' })],
      schedule,
      timed: true,
      steps: [],
      laps: [lapType('run', 'Run', [alert('Half', 't/3x')])],
      variables: [variable('t', '1:00')],
    });
    expect(r.error?.issues.map((i) => [i.path.join('.'), i.message])).toEqual([
      ['questions.0.key', 'Required'],
      ['laps.0.alerts.0.key', 'Required'],
      ['laps.0.alerts.0.at', "Syntax at 3: unknown unit 'x' (use ms, s, m or h)"],
    ]);
  });

  it('timerChanges lists lap-type, variable and alert changes', () => {
    const next = {
      steps: [{ key: 'warm', label: 'Warm up', alerts: [] }],
      laps: [
        { key: 'run', label: 'Jog', alerts: [{ key: 'half', label: 'Half', at: 't/3' }] },
        { key: 'walk', label: 'Walk', alerts: [{ key: 'end', label: 'End', at: 't' }] },
      ],
      variables: [
        { name: 't', ms: 90_000 },
        { name: 'rest', ms: 30_000 },
      ],
    };
    expect(timerChanges(v2, next)).toEqual([
      'Lap type renamed: Run → Jog',
      'Lap type added: Walk',
      'Lap type removed: Rest',
      'Variable changed: t, 1:00 → 1:30',
      'Variable added: rest = 0:30',
      'Alert removed: Warm up · Go',
      'Alert changed: Jog · Half, t/2 → t/3',
      'Alert added: Walk · End at t',
    ]);
    expect(
      timerChanges(v2, {
        ...v2,
        laps: [v2.laps[1] ?? { key: '', label: '' }, v2.laps[0] ?? { key: '', label: '' }],
      }),
    ).toEqual(['Lap types reordered']);
    expect(timerChanges(v2, { ...v2, variables: [] })).toEqual(['Variable removed: t']);
    expect(
      timerChanges(null, { steps: [], laps: [{ key: 'run', label: 'Run' }], variables: [] }),
    ).toEqual(['Timed, as a stopwatch (no steps)', 'Lap type added: Run']);
    expect(timerChanges(v2, v2)).toEqual([]);
    // The v1 shape and its normalised form are the same timer.
    expect(
      timerChanges(
        { steps: [{ key: 'a', label: 'A' }] },
        {
          steps: [{ key: 'a', label: 'A', alerts: [] }],
          laps: [],
          variables: [],
        },
      ),
    ).toEqual([]);
  });
});

// T2-M3 (F3-EDIT): appearance in the topic forms (appearance.md §1.3, §7).
describe('appearance schemas', () => {
  const appearance = makeAppearanceSchema();
  const issues = (r: { success: boolean; error?: { issues: { path: PropertyKey[] }[] } }) =>
    r.error?.issues.map((i) => i.path.join('.'));

  it('turns a draft into the wire Appearance, storing the normalised emoji and tags', () => {
    expect(
      appearance.parse({
        color: 'teal',
        icon: ' \u{263A} ',
        tags: [' gym ', 'a  b'],
        tagInput: '',
      }),
    ).toEqual({
      color: 'teal',
      icon: { kind: 'emoji', value: '\u{263A}\u{FE0F}' },
      tags: ['gym', 'a b'],
    });
    expect(appearance.parse(appearanceDraftOf(null))).toEqual({
      color: null,
      icon: null,
      tags: [],
    });
  });

  it('puts icon and tag errors on their paths', () => {
    expect(
      issues(appearance.safeParse({ color: null, icon: 'abc', tags: [], tagInput: '' })),
    ).toEqual(['icon']);
    expect(
      issues(appearance.safeParse({ color: null, icon: '', tags: ['a', 'A'], tagInput: '' })),
    ).toEqual(['tags.1']);
    const eleven = Array.from({ length: 11 }, (_, i) => `t${String(i)}`);
    expect(
      issues(appearance.safeParse({ color: null, icon: '', tags: eleven, tagInput: '' })),
    ).toEqual(['tags']);
    expect(
      issues(appearance.safeParse({ color: 'mauve', icon: '', tags: [], tagInput: '' })),
    ).toEqual(['color']);
  });

  it('refuses text left in the tag input (one the editor could not add)', () => {
    const r = appearance.safeParse({ color: null, icon: '', tags: [], tagInput: 'x'.repeat(30) });
    expect(issues(r)).toEqual(['tagInput']);
    expect(appearance.parse({ color: null, icon: '', tags: [], tagInput: '  ' }).tags).toEqual([]);
  });

  it('uses the server’s limits when GET /limits carries them', () => {
    const tight = makeAppearanceSchema({ ...FALLBACK_LIMITS, max_tags: 1 });
    expect(tight.safeParse({ color: null, icon: '', tags: ['a', 'b'], tagInput: '' }).success).toBe(
      false,
    );
  });

  it('sends appearance on create only when it isn’t the default', () => {
    const schema = makeTopicDraftAppearanceSchema();
    const base = { ...emptyTopicDraft(), name: 'Gym', schedule };
    const plain = schema.parse({ ...base, appearance: appearanceDraftOf(null) });
    expect(plain).not.toHaveProperty('appearance');
    expect(plain).toMatchObject({ name: 'Gym', timer: null });
    const themed = schema.parse({
      ...base,
      appearance: { color: 'red', icon: '🏃', tags: ['sport'], tagInput: '' },
    });
    expect(themed.appearance).toEqual({
      color: 'red',
      icon: { kind: 'emoji', value: '🏃' },
      tags: ['sport'],
    });
  });

  it('reports draft and appearance errors together on create', () => {
    const r = makeTopicDraftAppearanceSchema().safeParse({
      ...emptyTopicDraft(),
      schedule,
      appearance: { color: null, icon: 'x', tags: [], tagInput: '' },
    });
    expect(issues(r)).toEqual(expect.arrayContaining(['name', 'appearance.icon']));
  });

  it('adds appearance to the settings schema', () => {
    const r = makeTopicMetaAppearanceSchema().safeParse({
      name: 'Gym',
      slug: 'gym',
      description: '',
      appearance: { color: 'blue', icon: '', tags: ['x'.repeat(25)], tagInput: '' },
    });
    expect(issues(r)).toEqual(['appearance.tags.0']);
  });
});

describe('appearanceChanges', () => {
  const base = { color: 'red', icon: { kind: 'emoji', value: '🏃' }, tags: ['a'] } as const;
  const current = { ...base, tags: [...base.tags] };

  it('is null when nothing changed', () => {
    expect(appearanceChanges(current, { ...current, tags: ['a'] })).toBeNull();
    expect(appearanceChanges(null, { color: null, icon: null, tags: [] })).toBeNull();
  });

  it('has only the changed fields, with null and [] to clear', () => {
    expect(appearanceChanges(current, { ...current, color: 'blue' })).toEqual({ color: 'blue' });
    expect(appearanceChanges(current, { ...current, icon: null, tags: [] })).toEqual({
      icon: null,
      tags: [],
    });
    expect(appearanceChanges(current, { ...current, tags: ['b', 'a'] })).toEqual({
      tags: ['b', 'a'],
    });
  });
});

describe('builderFieldFor appearance paths', () => {
  const draft = {
    ...emptyTopicDraft(),
    appearance: { color: null, icon: '', tags: ['a', 'b'], tagInput: '' },
  };

  it('maps the server’s dotted paths onto the Appearance card', () => {
    expect(builderFieldFor('appearance.color', draft)).toBe('appearance.color');
    expect(builderFieldFor('appearance.icon.value', draft)).toBe('appearance.icon');
    expect(builderFieldFor('appearance.icon', draft)).toBe('appearance.icon');
    expect(builderFieldFor('appearance.tags.1', draft)).toBe('appearance.tags.1');
    expect(builderFieldFor('appearance.tags', draft)).toBe('appearance.tags');
  });

  it('falls back to the list for a tag the draft doesn’t have, and the banner otherwise', () => {
    expect(builderFieldFor('appearance.tags.7', draft)).toBe('appearance.tags');
    expect(builderFieldFor('appearance', draft)).toBeNull();
    expect(builderFieldFor('appearance.bogus', draft)).toBeNull();
    // A form without the card (the question editor) sends these to the banner.
    expect(builderFieldFor('appearance.color', emptyTopicDraft())).toBeNull();
  });
});
// end T2-M3
