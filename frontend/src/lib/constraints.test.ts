/**
 * Client-side mirrors of the server's constraints (backend/app/schemas/*.py): every rule
 * the server enforces should be caught here first, at the same field.
 */
import { describe, expect, it, vi } from 'vitest';

import { FALLBACK_LIMITS } from '../api/limits';
import { locToPath, mapApiError } from '../api/errors';
import { builderFieldFor } from '../components/builder/serverErrors';
import type { Limits } from '../client';
import { buildAnswerSchema, reusableValuesFromEntry, selectionHint } from './answerSchema';
import {
  convertDraftQuestion,
  draftFromQuestion,
  emptyTopicDraft,
  makeTopicDraftSchema,
  makeTopicMetaSchema,
  newDraftOption,
  newDraftQuestion,
  questionListIssues,
  type DraftQuestion,
} from './builder';
import { capturedAtIssue } from './entryMeta';
import type { Question } from './questions';
import {
  emptyScheduleDraft,
  scheduleFieldFor,
  scheduleFromDraft,
  type ScheduleDraft,
} from './schedule';

const L = FALLBACK_LIMITS;

function draft(type: DraftQuestion['type'], patch: Partial<DraftQuestion> = {}): DraftQuestion {
  return { ...newDraftQuestion(type), key: 'q', label: 'Q', ...patch };
}

function issuesOf(d: DraftQuestion, limits: Limits = L): Record<string, string> {
  const r = convertDraftQuestion(d, limits);
  return r.ok ? {} : Object.fromEntries(r.issues.map((i) => [i.path.join('.'), i.message]));
}

const opts = (...labels: string[]) => {
  const out = labels.map((l) => newDraftOption(l));
  return out.map((o, i) => ({ ...o, value: o.value || `o${String(i)}` }));
};

describe('question constraints', () => {
  it('bounds label / help text / unit lengths with the server limits', () => {
    const tight: Limits = {
      ...L,
      max_label_length: 5,
      max_help_text_length: 3,
      max_unit_length: 2,
    };
    expect(
      issuesOf(draft('int', { label: 'Too long', help_text: 'abcd', unit: 'kgs' }), tight),
    ).toEqual({
      label: 'At most 5 characters (8 now)',
      help_text: 'At most 3 characters (4 now)',
      unit: 'At most 2 characters (3 now)',
    });
  });

  it('counts label lengths in code points', () => {
    const tight: Limits = { ...L, max_label_length: 2 };
    expect(issuesOf(draft('int', { label: '😀😀' }), tight)).toEqual({});
    expect(issuesOf(draft('int', { label: '😀😀😀' }), tight)).toEqual({
      label: 'At most 2 characters (3 now)',
    });
  });

  it('uses the server key pattern', () => {
    expect(issuesOf(draft('int', { key: 'a'.repeat(64) }))).toHaveProperty('key');
    expect(issuesOf(draft('int', { key: 'a'.repeat(63) }))).toEqual({});
  });

  it('checks decimals 0..max and integer bounds', () => {
    expect(issuesOf(draft('double', { decimals: '11' }))).toEqual({
      decimals: 'Must be at most 10',
    });
    expect(issuesOf(draft('double', { decimals: '-1' }))).toEqual({
      decimals: 'Must be at least 0',
    });
    expect(issuesOf(draft('int', { min: '1.5' }))).toEqual({ min: 'Must be a whole number' });
    expect(issuesOf(draft('int', { max: '99999999999999999999' }))).toEqual({
      max: 'Number is too large',
    });
    expect(issuesOf(draft('double', { min: '2', max: '1' }))).toEqual({ max: 'Max must be ≥ min' });
  });

  it('bounds string lengths by max_str_length', () => {
    expect(issuesOf(draft('str', { max_length: '10001' }))).toEqual({
      max_length: 'Must be at most 10000',
    });
  });

  it('requires unique option values and case-insensitive unique option labels', () => {
    const a = newDraftOption('Good');
    const b = newDraftOption('good');
    expect(issuesOf(draft('enum', { options: [a, { ...b, value: 'other' }] }))).toEqual({
      'options.1.label': 'Another option has this label',
    });
    expect(
      issuesOf(draft('enum', { options: [a, { ...b, label: 'Fine', value: a.value }] })),
    ).toEqual({
      'options.1.value': 'Another option has this value',
    });
    expect(issuesOf(draft('enum', { options: [{ ...a, value: 'Bad value' }] }))).toHaveProperty(
      'options.0.value',
    );
  });

  it('caps the number of options', () => {
    expect(
      issuesOf(draft('enum', { options: opts('A', 'B', 'C') }), { ...L, max_enum_options: 2 }),
    ).toEqual({
      options: 'At most 2 options',
    });
  });
});

describe('multi-select constraints', () => {
  const three = opts('A', 'B', 'C');

  it('accepts 1 ≤ min ≤ max ≤ active options', () => {
    const r = convertDraftQuestion(
      draft('enum', { options: three, multiple: true, min_selected: '1', max_selected: '3' }),
    );
    expect(r.ok && r.question).toMatchObject({ multiple: true, min_selected: 1, max_selected: 3 });
  });

  it('rejects min > max, zero, and limits above the active options', () => {
    expect(
      issuesOf(
        draft('enum', { options: three, multiple: true, min_selected: '3', max_selected: '2' }),
      ),
    ).toEqual({ max_selected: 'Max must be ≥ min' });
    expect(issuesOf(draft('enum', { options: three, multiple: true, min_selected: '0' }))).toEqual({
      min_selected: 'Must be at least 1',
    });
    const archived = three.map((o, i) => (i === 0 ? { ...o, archived: true } : o));
    expect(
      issuesOf(draft('enum', { options: archived, multiple: true, max_selected: '3' })),
    ).toEqual({
      max_selected: 'Only 2 active options',
    });
  });

  it('drops selection limits on single-select questions', () => {
    const r = convertDraftQuestion(draft('enum', { options: three, min_selected: '2' }));
    expect(r.ok && r.question).toMatchObject({
      multiple: false,
      min_selected: null,
      max_selected: null,
    });
  });

  it('blocks multi → single for a published question but allows single → multi', () => {
    const published: Question = {
      key: 'tags',
      label: 'Tags',
      help_text: null,
      required: true,
      type: 'enum',
      options: [{ value: 'a', label: 'A', archived: false }],
      multiple: true,
      min_selected: null,
      max_selected: null,
    };
    const d = draftFromQuestion(published, true);
    expect(d.publishedMultiple).toBe(true);
    expect(issuesOf({ ...d, multiple: false })).toHaveProperty('multiple');
    const single = draftFromQuestion({ ...published, multiple: false }, true);
    expect(issuesOf({ ...single, multiple: true })).toEqual({});
  });
});

describe('question list + topic constraints', () => {
  it('flags duplicate keys and case-insensitive duplicate labels on the later question', () => {
    const issues = questionListIssues([
      { key: 'a', label: 'Mood' },
      { key: 'a', label: ' mood ' },
    ]);
    expect(issues).toEqual([
      { path: [1, 'key'], message: 'Key already used by another question' },
      { path: [1, 'label'], message: 'Another question has this label' },
    ]);
  });

  it('caps the question count', () => {
    expect(
      questionListIssues(
        [
          { key: 'a', label: 'A' },
          { key: 'b', label: 'B' },
        ],
        { ...L, max_questions: 1 },
      ),
    ).toEqual([{ path: [], message: 'At most 1 questions' }]);
  });

  it('validates name / slug / description against the limits', () => {
    const schema = makeTopicDraftSchema({
      ...L,
      max_topic_name_length: 3,
      max_description_length: 2,
    });
    const r = schema.safeParse({
      ...emptyTopicDraft(),
      name: 'Long name',
      slug: '-bad',
      description: 'abc',
      questions: [draft('int')],
    });
    const paths = r.error?.issues.map((i) => i.path.join('.'));
    expect(paths).toEqual(expect.arrayContaining(['name', 'slug', 'description']));
    const emoji = makeTopicDraftSchema({ ...L, max_topic_name_length: 3 }).safeParse({
      ...emptyTopicDraft(),
      name: '😀😀😀',
      questions: [draft('int')],
    });
    expect(emoji.error?.issues.map((i) => i.path.join('.')) ?? []).not.toContain('name');
    const meta = makeTopicMetaSchema(L).safeParse({
      name: 'x',
      slug: 'a'.repeat(65),
      description: '',
    });
    expect(meta.error?.issues.map((i) => i.path.join('.'))).toEqual(['slug']);
  });

  it('includes the schedule in the create body', () => {
    const r = makeTopicDraftSchema().safeParse({
      ...emptyTopicDraft(),
      name: 'Water',
      questions: [draft('int')],
      schedule: { ...emptyScheduleDraft('UTC'), kind: 'interval', every: '2', unit: 'hours' },
    });
    expect(r.data?.schedule).toEqual({
      kind: 'interval',
      every_minutes: 120,
      timezone: 'UTC',
      notify: true,
    });
  });
});

describe('schedule validation', () => {
  const base = (patch: Partial<ScheduleDraft>): ScheduleDraft => ({
    ...emptyScheduleDraft('Europe/London'),
    kind: 'daily',
    ...patch,
  });
  const issues = (d: ScheduleDraft, limits: Limits = L) => {
    const r = scheduleFromDraft(d, limits);
    return r.ok ? {} : Object.fromEntries(r.issues.map((i) => [i.path.join('.'), i.message]));
  };

  it('none → null', () => {
    expect(scheduleFromDraft(base({ kind: 'none' }), L)).toEqual({ ok: true, schedule: null });
  });

  it('daily: HH:MM, unique, 1..max times, at least one day, sorted days', () => {
    expect(issues(base({ times: [{ value: '8:00' }] }))).toEqual({
      'times.0.value': 'Use a 24-hour time like 08:00',
    });
    expect(issues(base({ times: [{ value: '08:00' }, { value: '08:00' }] }))).toEqual({
      'times.1.value': '08:00 is already in the list',
    });
    expect(issues(base({ times: [] }))).toEqual({ times: 'Add at least one time' });
    expect(
      issues(base({ times: [{ value: '08:00' }, { value: '09:00' }] }), {
        ...L,
        schedule_max_times: 1,
      }),
    ).toEqual({
      times: 'At most 1 times a day',
    });
    expect(issues(base({ days: [] }))).toEqual({ days: 'Pick at least one day' });
    expect(scheduleFromDraft(base({ days: [5, 1, 3] }), L)).toMatchObject({
      ok: true,
      schedule: { kind: 'daily', days: [1, 3, 5], times: ['08:00'] },
    });
  });

  it('interval: 15 min – 90 days, whole numbers', () => {
    const iv = (every: string, unit: ScheduleDraft['unit']) =>
      base({ kind: 'interval', every, unit });
    expect(issues(iv('10', 'minutes'))).toEqual({ every: 'At least every 15 minutes' });
    expect(issues(iv('91', 'days'))).toEqual({ every: 'At most every 90 days' });
    expect(issues(iv('1.5', 'hours'))).toEqual({ every: 'Enter a whole number' });
    expect(issues(iv('', 'hours'))).toEqual({ every: 'Enter how often' });
    expect(scheduleFromDraft(iv('90', 'days'), L)).toMatchObject({
      ok: true,
      schedule: { every_minutes: 129_600 },
    });
  });

  it('time zone must be a known IANA zone', () => {
    expect(issues(base({ timezone: 'Mars/Olympus' }))).toEqual({
      timezone: 'Unknown time zone (e.g. Europe/London, UTC)',
    });
    expect(issues(base({ timezone: '' }))).toEqual({ timezone: 'Pick a time zone' });
  });
});

describe('answer constraints', () => {
  const tags: Question = {
    key: 'tags',
    label: 'Tags',
    help_text: null,
    required: true,
    type: 'enum',
    options: [
      { value: 'a', label: 'A', archived: false },
      { value: 'b', label: 'B', archived: false },
      { value: 'c', label: 'C', archived: false },
      { value: 'x', label: 'X', archived: true },
    ],
    multiple: true,
    min_selected: 2,
    max_selected: 2,
  };
  const parse = (v: unknown, q: Question = tags, allowArchived = {}) =>
    buildAnswerSchema([q], { allowArchived }).safeParse({ [q.key]: v });
  const err = (r: ReturnType<typeof parse>) => r.error?.issues[0]?.message;

  it('produces string[] in option order', () => {
    expect(parse(['c', 'a']).data).toEqual({ tags: ['a', 'c'] });
  });

  it('enforces required / min / max selections and archived options', () => {
    expect(err(parse([]))).toBe('Pick at least one');
    expect(err(parse(['a']))).toBe('Pick at least 2 options');
    expect(err(parse(['a', 'b', 'c']))).toBe('Pick at most 2 options');
    expect(err(parse(['a', 'x']))).toBe('“X” has been retired');
    expect(parse(['a', 'x'], tags, { tags: ['x'] }).data).toEqual({ tags: ['a', 'x'] });
    expect(err(parse(['a', 'zzz']))).toBe('Pick from the options');
  });

  it('treats an empty optional selection as unanswered', () => {
    expect(parse([], { ...tags, required: false, min_selected: null }).data).toEqual({
      tags: null,
    });
  });

  it('hints the selection limits', () => {
    expect(selectionHint(tags)).toBe('Pick 2');
    expect(selectionHint({ ...tags, min_selected: null, max_selected: 3 })).toBe('Pick 1–3');
    expect(selectionHint({ ...tags, required: false, min_selected: null, max_selected: 3 })).toBe(
      'Pick up to 3',
    );
    expect(
      selectionHint({ ...tags, required: false, min_selected: null, max_selected: null }),
    ).toBe('Pick any');
  });

  it('“same as last time” keeps only values that are still valid', () => {
    const hours: Question = {
      key: 'hours',
      label: 'Hours',
      help_text: null,
      required: true,
      type: 'int',
      min: 0,
      max: 10,
      unit: null,
    };
    expect(
      reusableValuesFromEntry(
        [tags, hours],
        [
          { key: 'tags', type: 'enum_list', value: ['a', 'x'] },
          { key: 'hours', type: 'int', value: 12 },
        ],
      ),
    ).toEqual({ tags: ['a'], hours: '' });
    // an old single-select answer becomes a one-option selection
    expect(reusableValuesFromEntry([tags], [{ key: 'tags', type: 'enum', value: 'b' }])).toEqual({
      tags: ['b'],
    });
  });

  it('captured_at: not before 2000, not more than 24 h ahead', () => {
    const now = new Date('2026-10-15T12:00:00Z');
    expect(capturedAtIssue('1999-12-31T23:59:00Z', L, now)).toBe('Can’t be before 2000');
    expect(capturedAtIssue('2026-10-16T12:01:00Z', L, now)).toBe(
      'Can’t be more than 24 hours in the future',
    );
    expect(capturedAtIssue('2026-10-16T11:59:00Z', L, now)).toBeNull();
  });

  it('captured_at: names the limit’s UTC year, even west of UTC', () => {
    vi.stubEnv('TZ', 'America/Los_Angeles');
    try {
      // Sanity: the local year of 2000-01-01T00:00Z really is 1999 here.
      expect(new Date(L.captured_at_min).getFullYear()).toBe(1999);
      expect(capturedAtIssue('1999-06-01T00:00:00Z', L, new Date('2026-10-15T12:00:00Z'))).toBe(
        'Can’t be before 2000',
      );
    } finally {
      vi.unstubAllEnvs();
    }
  });
});

describe('server error locations', () => {
  const draftWith = {
    ...emptyTopicDraft(),
    questions: [0, 1, 2, 3, 4].map(() => ({
      ...newDraftQuestion('enum'),
      options: opts('A', 'B'),
    })),
    schedule: { ...emptyScheduleDraft('UTC'), kind: 'daily' as const, times: [{ value: '08:00' }] },
  };
  const problem = (loc: (string | number)[]) => ({
    code: 'invalid_request',
    detail: 'Invalid request',
    errors: [{ loc, message: 'nope' }],
  });
  const field = (loc: (string | number)[]) => {
    const path = mapApiError(problem(loc)).fieldErrors[0]?.path ?? '';
    return builderFieldFor(path, draftWith);
  };

  it('lands every precise loc on its builder field', () => {
    expect(field(['body', 'questions', 4, 'key'])).toBe('questions.4.key');
    expect(field(['body', 'questions', 2, 'options', 1, 'value'])).toBe(
      'questions.2.options.1.value',
    );
    expect(field(['body', 'questions', 2, 'options', 1, 'label'])).toBe(
      'questions.2.options.1.label',
    );
    expect(field(['body', 'questions', 1, 'max_selected'])).toBe('questions.1.max_selected');
    expect(field(['body', 'schedule', 'times', 0])).toBe('schedule.times.0.value');
    expect(field(['body', 'schedule', 'every_minutes'])).toBe('schedule.every');
    expect(field(['body', 'schedule', 'days', 3])).toBe('schedule.days');
    expect(field(['body', 'schedule', 'timezone'])).toBe('schedule.timezone');
    expect(field(['body', 'name'])).toBe('name');
  });

  it('drops union tags should they appear', () => {
    expect(locToPath(['body', 'questions', 0, 'enum', 'options', 1, 'value'])).toBe(
      'questions.0.options.1.value',
    );
    expect(locToPath(['body', 'schedule', 'daily', 'times', 0])).toBe('schedule.times.0');
    expect(scheduleFieldFor('schedule.interval')).toBe('schedule.kind');
  });

  it('keeps entry locs (answers.<key>.<i>, captured_at) relative to the body', () => {
    expect(locToPath(['answers', 'factors', 2])).toBe('answers.factors.2');
    expect(locToPath(['body', 'captured_at'])).toBe('captured_at');
  });
});
