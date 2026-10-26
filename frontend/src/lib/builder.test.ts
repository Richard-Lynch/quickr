import { describe, expect, it } from 'vitest';

import {
  convertDraftQuestion,
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
    });
    expect(r.data?.timer).toEqual({
      steps: [
        { key: 'dress', label: 'Dress' },
        { key: 'shower', label: 'Bath' },
        { key: 'coffee', label: 'Coffee' },
      ],
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
    });
    expect(stopwatch.data?.timer).toEqual({ steps: [] });
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
