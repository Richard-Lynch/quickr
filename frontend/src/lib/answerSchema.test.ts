import { describe, expect, it } from 'vitest';

import {
  answerValuesFromSession,
  archivedValuesInSession,
  buildAnswerSchema,
  compactAnswers,
  inputHints,
  parseNumberInput,
} from './answerSchema';
import type { Question } from './questions';

const hours: Question = {
  key: 'hours',
  label: 'Hours slept',
  help_text: null,
  required: true,
  type: 'double',
  min: 0,
  max: 24,
  decimals: 1,
  unit: 'h',
};
const wakeups: Question = {
  key: 'wakeups',
  label: 'Wake-ups',
  help_text: null,
  required: false,
  type: 'int',
  min: 0,
  max: 20,
  unit: null,
};
const note: Question = {
  key: 'note',
  label: 'Note',
  help_text: null,
  required: false,
  type: 'str',
  min_length: 3,
  max_length: 10,
  multiline: true,
};
const mood: Question = {
  key: 'mood',
  label: 'Mood',
  help_text: null,
  required: true,
  type: 'enum',
  options: [
    { value: 'good', label: 'Good', archived: false },
    { value: 'meh', label: 'Meh', archived: false },
    { value: 'awful', label: 'Awful', archived: true },
  ],
};
const all = [hours, wakeups, note, mood];

function errors(result: ReturnType<ReturnType<typeof buildAnswerSchema>['safeParse']>) {
  if (result.success) return {};
  return Object.fromEntries(result.error.issues.map((i) => [i.path.join('.'), i.message]));
}

describe('buildAnswerSchema', () => {
  it('parses a valid form into an API answer map', () => {
    const r = buildAnswerSchema(all).safeParse({
      hours: '7,5',
      wakeups: '2',
      note: '  fine  ',
      mood: 'good',
    });
    expect(r.success).toBe(true);
    expect(r.data).toEqual({ hours: 7.5, wakeups: 2, note: 'fine', mood: 'good' });
  });

  it('turns blank optional fields into null and flags blank required ones', () => {
    const r = buildAnswerSchema(all).safeParse({ hours: '', wakeups: '', note: ' ', mood: '' });
    expect(errors(r)).toEqual({ hours: 'Required', mood: 'Required' });
    const ok = buildAnswerSchema(all).safeParse({ hours: '8', mood: 'meh' });
    expect(ok.data).toEqual({ hours: 8, wakeups: null, note: null, mood: 'meh' });
  });

  it('enforces integer and range rules', () => {
    const r = buildAnswerSchema(all).safeParse({ hours: '25', wakeups: '1.5', mood: 'good' });
    expect(errors(r)).toEqual({ hours: 'Must be at most 24 h', wakeups: 'Enter a whole number' });
    const neg = buildAnswerSchema([wakeups]).safeParse({ wakeups: '-1' });
    expect(errors(neg)).toEqual({ wakeups: 'Must be at least 0' });
  });

  it('rejects non-numbers for doubles', () => {
    expect(errors(buildAnswerSchema([hours]).safeParse({ hours: 'abc' }))).toEqual({
      hours: 'Enter a number',
    });
  });

  it('enforces string length limits', () => {
    expect(errors(buildAnswerSchema([note]).safeParse({ note: 'ab' }))).toEqual({
      note: 'At least 3 characters (2 so far)',
    });
    expect(errors(buildAnswerSchema([note]).safeParse({ note: 'abcdefghijk' }))).toEqual({
      note: 'At most 10 characters (11 entered)',
    });
  });

  it('rejects archived and unknown enum values unless explicitly allowed', () => {
    expect(errors(buildAnswerSchema([mood]).safeParse({ mood: 'awful' }))).toEqual({
      mood: 'That option has been retired',
    });
    expect(errors(buildAnswerSchema([mood]).safeParse({ mood: 'nope' }))).toEqual({
      mood: 'Pick one of the options',
    });
    const allowed = buildAnswerSchema([mood], { allowArchived: { mood: 'awful' } });
    expect(allowed.safeParse({ mood: 'awful' }).data).toEqual({ mood: 'awful' });
  });
});

describe('helpers', () => {
  it('parseNumberInput accepts comma decimals and rejects junk', () => {
    expect(parseNumberInput('3,25')).toBe(3.25);
    expect(parseNumberInput('-.5')).toBe(-0.5);
    expect(parseNumberInput('1e3')).toBe(1000);
    expect(parseNumberInput('1.2.3')).toBeNull();
    expect(parseNumberInput('')).toBeNull();
  });

  it('round-trips session answers into form values', () => {
    const values = answerValuesFromSession(all, [
      { key: 'hours', type: 'double', value: 6.5 },
      { key: 'mood', type: 'enum', value: 'awful' },
    ]);
    expect(values).toEqual({ hours: '6.5', wakeups: '', note: '', mood: 'awful' });
    expect(archivedValuesInSession(all, [{ key: 'mood', type: 'enum', value: 'awful' }])).toEqual({
      mood: 'awful',
    });
  });

  it('compactAnswers drops nulls', () => {
    expect(compactAnswers({ a: 1, b: null, c: 'x' })).toEqual({ a: 1, c: 'x' });
  });

  it('chooses chips for few options and a select for many', () => {
    expect(inputHints(mood).kind).toBe('chips');
    const many: Question = {
      ...mood,
      options: Array.from({ length: 7 }, (_, i) => ({
        value: `o${i}`,
        label: `O${i}`,
        archived: false,
      })),
    };
    expect(inputHints(many).kind).toBe('select');
  });

  it('hides archived options except the value being kept', () => {
    const h = inputHints(mood);
    expect(h.kind === 'chips' && h.options.map((o) => o.value)).toEqual(['good', 'meh']);
    const kept = inputHints(mood, 'awful');
    expect(kept.kind === 'chips' && kept.options.map((o) => o.value)).toEqual([
      'good',
      'meh',
      'awful',
    ]);
  });

  it('derives numeric input hints', () => {
    expect(inputHints(hours)).toEqual({
      kind: 'number',
      inputMode: 'decimal',
      step: '0.1',
      min: 0,
      max: 24,
    });
    expect(inputHints({ ...wakeups, min: null })).toMatchObject({ inputMode: 'text', step: '1' });
  });
});
