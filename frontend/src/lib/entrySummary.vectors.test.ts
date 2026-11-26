/**
 * content-display.md §1 (F4-SUMMARYLINE): `entrySummary` against every case in
 * shared/fixtures/entry-summary-vectors.json (generated from backend/app/services/summary.py
 * by `make vectors`; iOS asserts the same cases in `EntrySummaryVectorTests`).
 */
import { describe, expect, it } from 'vitest';

import raw from '../../../shared/fixtures/entry-summary-vectors.json?raw';
import type { TimerOutput as Timer, Timing } from '../client';
import { formatAnswer } from './answerDisplay';
import {
  answerText,
  collapseWhitespace,
  entrySummary,
  formatDecimal,
  graphemes,
  MAX_SUMMARY_LENGTH,
  SEPARATOR,
  timingLine,
  type StoredAnswer,
} from './entrySummary';
import type { Question } from './questions';

interface Case {
  name: string;
  questions: string;
  timer: string;
  answers: StoredAnswer[];
  timing: Timing | null;
  expected: string;
}

interface Vectors {
  meta: { generator_version: number; max_length: number; separator: string; whitespace: number[] };
  question_sets: Record<string, Question[]>;
  timer_sets: Record<string, Timer | null>;
  cases: Case[];
}

const vectors = JSON.parse(raw) as Vectors;

const codePoints = (s: string) => Array.from(s, (c) => c.codePointAt(0));

describe('entry summary vectors (shared with the backend and iOS)', () => {
  it('meta matches the port', () => {
    expect(vectors.meta.generator_version).toBe(1);
    expect(vectors.meta.max_length).toBe(MAX_SUMMARY_LENGTH);
    expect(vectors.meta.separator).toBe(SEPARATOR);
  });

  it('has the spec’s cases', () => {
    const names = vectors.cases.map((c) => c.name);
    expect(names.length).toBeGreaterThanOrEqual(20);
    expect(new Set(names).size).toBe(names.length);
    // content-display.md §1.3, without the typed-lap cases M4-STATS adds with M1's lap types.
    for (const name of [
      'timing_only_no_laps',
      'timing_one_lap',
      'timing_three_laps',
      'timing_hour_plus',
      'timing_paused_ignored',
      'answers_int_unit',
      'answers_double_decimals',
      'answers_double_trailing_zeros',
      'answers_enum_single',
      'answers_enum_multi',
      'answers_enum_unknown_option',
      'answers_str_collapsed_whitespace',
      'answers_str_empty_skipped',
      'answers_missing_optional_skipped',
      'both_timing_then_answers',
      'order_follows_questions_not_answers',
      'question_without_answer_skipped',
      'long_truncated',
      'long_truncation_flag_pair',
      'long_truncation_keycap',
      'long_truncation_zwj_family',
      'long_truncation_combining_marks',
      'empty',
      'untimed_entry_of_timed_topic',
    ]) {
      expect(names, name).toContain(name);
    }
  });

  it('collapses exactly Unicode White_Space (meta.whitespace)', () => {
    const expected = new Set(vectors.meta.whitespace);
    const found: number[] = [];
    for (let c = 0; c <= 0x10ffff; c++) {
      if (c >= 0xd800 && c <= 0xdfff) continue;
      if (collapseWhitespace(`a${String.fromCodePoint(c)}b`) === 'a b') found.push(c);
    }
    expect(new Set(found)).toEqual(expected);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (_, c) => {
    const questions = vectors.question_sets[c.questions];
    expect(questions, `question set ${c.questions}`).toBeDefined();
    expect(c.timer in vectors.timer_sets, `timer set ${c.timer}`).toBe(true);
    const line = entrySummary(
      c.answers,
      c.timing,
      questions ?? [],
      vectors.timer_sets[c.timer] ?? null,
    );
    // Code points, not just `toBe`: the vectors are not normalised and neither is the port.
    expect(codePoints(line)).toEqual(codePoints(c.expected));
    expect(graphemes(line).length).toBeLessThanOrEqual(MAX_SUMMARY_LENGTH);
  });
});

describe('typed laps', () => {
  // The typed-lap branch, until M4-STATS adds its vectors with M1's lap types: the
  // reference's rule on the lap types directly (timing_tiktok, timing_renamed,
  // timing_mixed_typed_untyped and timing_lap_type_not_in_timer of §1.3).
  const tiktok = [
    ['run', 'Run'],
    ['rest', 'Rest'],
  ] as const;
  const line = (
    types: (string | null)[],
    declared: readonly (readonly [string, string])[] = tiktok,
  ) => timingLine(760_000, types, declared);

  it('counts each type in declared order, then first seen, the untyped remainder last', () => {
    expect(line(['rest', 'run', 'rest', 'run', 'rest', 'run'])).toBe('12:40 · Run 3 · Rest 3');
    expect(line(['cig', 'cig'], [['cig', 'Cig']])).toBe('12:40 · Cig 2');
    expect(line([null, 'run', null])).toBe('12:40 · Run 1 · 2 laps');
    expect(line(['run', '', null])).toBe('12:40 · Run 1 · 2 laps');
    expect(line(['walk', 'run', 'walk', null])).toBe('12:40 · Run 1 · walk 2 · 1 lap');
    expect(line(['b', 'a', 'b'], [])).toBe('12:40 · b 2 · a 1');
    expect(line([null, null])).toBe('12:40 · 2 laps');
    expect(line([])).toBe('12:40');
    expect(
      line(
        ['run'],
        [
          ['run', 'Jog'],
          ['run', 'Run'],
        ],
      ),
    ).toBe('12:40 · Run 1');
  });
});

describe('formatDecimal', () => {
  // `_number`'s rounding beyond the vectors (outputs from `summary._number`, as iOS pins):
  // half away from zero on the shortest decimal, exponent forms, carries and the "-0".
  it.each([
    [1.005, 2, '1.01'],
    [-1.5, 0, '-2'],
    [1e16, 3, '10000000000000000'],
    [1e-5, 3, '0'],
    [0.0005, 3, '0.001'],
    [9.9996, 3, '10'],
    [-0.0001, 3, '-0'],
    [-0, 3, '-0'],
    [0.5, 0, '1'],
    [2.5, 0, '3'],
    [123456789.12345679, 5, '123456789.12346'],
    [5e-324, 3, '0'],
    [0.15, 1, '0.2'],
    [99.95, 1, '100'],
    [36.65, 1, '36.7'],
    [1234.5, 3, '1234.5'],
    [Number.MAX_VALUE, 0, `17976931348623157${'0'.repeat(292)}`],
  ] as const)('%d at %d decimals is %s', (value, decimals, expected) => {
    expect(formatDecimal(value, decimals)).toBe(expected);
  });
});

describe('answerText as formatAnswer', () => {
  const weight: Question = {
    key: 'weight',
    label: 'Weight',
    help_text: null,
    required: true,
    type: 'int',
    unit: 'kg',
    min: null,
    max: null,
  };
  const temp: Question = {
    key: 'temp',
    label: 'Temp',
    help_text: null,
    required: false,
    type: 'double',
    unit: '°C',
    decimals: 1,
    min: null,
    max: null,
  };
  const mood: Question = {
    key: 'mood',
    label: 'Mood',
    help_text: null,
    required: false,
    type: 'enum',
    multiple: false,
    min_selected: null,
    max_selected: null,
    options: [
      { value: 'happy', label: 'Happy', archived: false },
      { value: 'meh', label: 'Meh', archived: false },
    ],
  };
  const note: Question = {
    key: 'note',
    label: 'Note',
    help_text: null,
    required: false,
    type: 'str',
    min_length: 0,
    max_length: 500,
    multiline: true,
  };

  it('is the display text every surface uses', () => {
    expect(formatAnswer).toBe(answerText);
  });

  // The old `formatAnswer`'s inputs and outputs (en locale, no thousands): unchanged.
  it.each([
    [weight, { key: 'weight', type: 'int', value: 72 }, '72 kg'],
    [weight, { key: 'weight', type: 'double', value: 72.4 }, '72 kg'],
    [temp, { key: 'temp', type: 'double', value: 36.6 }, '36.6 °C'],
    [temp, { key: 'temp', type: 'int', value: 37 }, '37 °C'],
    [mood, { key: 'mood', type: 'enum', value: 'happy' }, 'Happy'],
    [mood, { key: 'mood', type: 'enum', value: 'gone' }, 'gone'],
    [mood, { key: 'mood', type: 'enum_list', value: ['happy', 'meh'] }, 'Happy, Meh'],
    [mood, { key: 'mood', type: 'enum_list', value: [] }, null],
    [note, { key: 'note', type: 'str', value: 'walked' }, 'walked'],
    [note, { key: 'note', type: 'int', value: 3 }, null],
    [weight, { key: 'weight', type: 'str', value: '72' }, null],
  ] as [Question, StoredAnswer, string | null][])('%#', (q, a, expected) => {
    expect(answerText(q, a)).toBe(expected);
  });

  // Where §1.2 deliberately differs from the old one: no grouping, collapsed whitespace.
  it('drops grouping and collapses whitespace', () => {
    expect(answerText(weight, { key: 'weight', type: 'int', value: 12345 })).toBe('12345 kg');
    expect(answerText(note, { key: 'note', type: 'str', value: ' walked\n\tthe  dog ' })).toBe(
      'walked the dog',
    );
    expect(answerText(note, { key: 'note', type: 'str', value: ' \n ' })).toBeNull();
  });
});
