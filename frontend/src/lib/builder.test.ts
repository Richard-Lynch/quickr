import { describe, expect, it } from 'vitest';

import {
  convertDraftQuestion,
  draftFromQuestion,
  newDraftOption,
  newDraftQuestion,
  previewQuestion,
  slugify,
  toSnakeKey,
  topicDraftSchema,
  uniqueKey,
  versionDraftSchema,
  withLabel,
  type DraftQuestion,
} from './builder';
import type { Question } from './questions';

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
      key: 'Use lower_snake_case: a–z, 0–9, _ (start with a letter)',
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
        'options.1.value': 'Duplicate value',
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
      questions: [draft('int', { key: 'hours' })],
    });
    expect(r.success).toBe(true);
    expect(r.data).toMatchObject({ name: 'Sleep', slug: null, description: '' });
    expect(r.data?.questions[0]).toMatchObject({ key: 'hours', type: 'int' });
  });

  it('reports duplicate keys, bad slugs and empty question lists at field paths', () => {
    const dup = topicDraftSchema.safeParse({
      name: 'x',
      slug: 'Bad Slug',
      slugEdited: true,
      description: '',
      change_note: '',
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
      questions: [],
    });
    expect(none.error?.issues.map((i) => i.path.join('.'))).toEqual(['name', 'questions']);
  });

  it('versionDraftSchema validates questions + note', () => {
    const r = versionDraftSchema.safeParse({
      name: 'x',
      slug: 'x',
      slugEdited: true,
      description: '',
      questions: [draft('int')],
      change_note: ' hi ',
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
