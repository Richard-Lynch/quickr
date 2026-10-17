import { describe, expect, it } from 'vitest';

import { dueCount } from '../api/dueBadge';
import type { TopicSummary } from '../client';
import { splitByDue } from '../pages/TopicsPage';
import type { IntQuestionOutput, Question } from './questions';
import { initialNumber, parseQuickNumber, quickLogFor } from './quickLog';
import { describeSchedule, dueAfterLogging, dueView, formatWhen, isDueNow } from './schedule';

const enumQ = (n: number, patch: Partial<Question> = {}): Question =>
  ({
    key: 'mood',
    label: 'Mood',
    help_text: null,
    required: true,
    type: 'enum',
    options: Array.from({ length: n }, (_, i) => ({
      value: `o${String(i)}`,
      label: `O${String(i)}`,
      archived: false,
    })),
    multiple: false,
    min_selected: null,
    max_selected: null,
    ...patch,
  }) as Question;

const intQ: IntQuestionOutput = {
  key: 'glasses',
  label: 'Glasses',
  help_text: null,
  required: true,
  type: 'int',
  min: 0,
  max: 30,
  unit: null,
};
const noteQ: Question = {
  key: 'note',
  label: 'Note',
  help_text: null,
  required: false,
  type: 'str',
  min_length: 0,
  max_length: 500,
  multiline: false,
};

describe('quick-log eligibility', () => {
  it('chips for one required single-select enum with ≤ 6 active options', () => {
    expect(quickLogFor([enumQ(4)])?.kind).toBe('chips');
    expect(quickLogFor([enumQ(6)])?.kind).toBe('chips');
    expect(quickLogFor([enumQ(7)])).toBeNull();
    // archived options don't count, and aren't offered
    const q = enumQ(7);
    if (q.type === 'enum')
      q.options = q.options.map((o, i) => (i === 0 ? { ...o, archived: true } : o));
    const r = quickLogFor([q]);
    expect(r?.kind === 'chips' && r.options.map((o) => o.value)).not.toContain('o0');
  });

  it('a stepper for one required int/double', () => {
    expect(quickLogFor([intQ])?.kind).toBe('number');
    expect(quickLogFor([{ ...intQ, type: 'double', decimals: 1 }])?.kind).toBe('number');
  });

  it('ignores optional extra questions', () => {
    expect(quickLogFor([enumQ(3), noteQ])?.kind).toBe('chips');
  });

  it('falls back to the record screen otherwise', () => {
    expect(quickLogFor([enumQ(3), intQ])).toBeNull(); // two required
    expect(quickLogFor([{ ...intQ, required: false }])).toBeNull(); // only optional
    expect(quickLogFor([enumQ(3, { multiple: true })])).toBeNull(); // multi-select
    expect(quickLogFor([{ ...noteQ, required: true }])).toBeNull(); // text
    expect(quickLogFor([])).toBeNull();
  });

  it('prefills numbers with the last valid value, else min ≥ 0', () => {
    expect(initialNumber(intQ, 7)).toBe('7');
    expect(initialNumber(intQ, 99)).toBe('0'); // out of range now
    expect(initialNumber(intQ, undefined)).toBe('0');
    expect(initialNumber({ ...intQ, min: -5 }, undefined)).toBe('');
    expect(parseQuickNumber(intQ, '31')).toEqual({ ok: false, message: 'Must be at most 30' });
    expect(parseQuickNumber(intQ, '3')).toEqual({ ok: true, value: 3 });
  });
});

describe('due formatting', () => {
  const now = new Date(2026, 9, 15, 9, 0); // local 09:00
  const at = (h: number, m = 0, dayOffset = 0) =>
    new Date(2026, 9, 15 + dayOffset, h, m).toISOString();
  const due = (patch: Partial<NonNullable<TopicSummary['due']>>) => ({
    is_due: false,
    due_since: null,
    next_due_at: null,
    last_entry_at: null,
    ...patch,
  });
  const t = (h: number, m: number) =>
    new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(
      new Date(2026, 9, 15, h, m),
    );

  it('fresh slots are "Due now", older ones "Overdue"', () => {
    expect(dueView(due({ is_due: true, due_since: at(8, 45) }), now)).toEqual({
      tone: 'due',
      label: `Due now · since ${t(8, 45)}`,
    });
    expect(dueView(due({ is_due: true, due_since: at(8) }), now)).toEqual({
      tone: 'overdue',
      label: `Overdue · since ${t(8, 0)}`,
    });
    expect(dueView(due({ is_due: true, due_since: at(21, 0, -1) }), now).label).toBe(
      `Overdue · since yesterday ${t(21, 0)}`,
    );
  });

  it('upcoming slots: "Due in 25 min" soon, else when', () => {
    expect(dueView(due({ next_due_at: at(9, 25) }), now)).toEqual({
      tone: 'soon',
      label: 'Due in 25 min',
    });
    expect(dueView(due({ next_due_at: at(21) }), now)).toEqual({
      tone: 'later',
      label: `Next ${t(21, 0)}`,
    });
    expect(dueView(due({ next_due_at: at(8, 0, 1) }), now).label).toBe(`Tomorrow ${t(8, 0)}`);
    expect(dueView(null, now)).toEqual({ tone: 'none', label: '' });
  });

  it('a slot that passed since the last fetch counts as due', () => {
    const d = due({ next_due_at: at(8, 50) });
    expect(isDueNow(d, now)).toBe(true);
    expect(dueView(d, now).tone).toBe('due');
    expect(formatWhen(at(8, 0, 3), now)).toMatch(/\w{2,} /);
  });

  it('logging clears the open slot optimistically', () => {
    const d = due({ is_due: true, due_since: at(8), next_due_at: at(8) });
    expect(dueAfterLogging(d, at(9))).toEqual({
      is_due: false,
      due_since: null,
      next_due_at: null,
      last_entry_at: at(9),
    });
  });

  it('describes schedules', () => {
    expect(
      describeSchedule({
        kind: 'daily',
        times: ['08:00', '21:00'],
        days: [1, 2, 3, 4, 5],
        timezone: 'UTC',
        notify: true,
      }),
    ).toBe('Daily 08:00, 21:00 · weekdays');
    expect(
      describeSchedule({ kind: 'interval', every_minutes: 180, timezone: 'UTC', notify: true }),
    ).toBe('Every 3 hours');
    expect(
      describeSchedule({ kind: 'interval', every_minutes: 1440, timezone: 'UTC', notify: true }),
    ).toBe('Every 1 day');
  });
});

describe('due list + badge', () => {
  const now = new Date('2026-10-15T09:00:00Z');
  const topic = (id: string, patch: Partial<TopicSummary> = {}): TopicSummary => ({
    id,
    slug: id,
    name: id,
    description: '',
    status: 'active',
    current_version: 1,
    revision: 1,
    question_count: 1,
    entry_count: 0,
    last_captured_at: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    archived_at: null,
    schedule: null,
    schedule_updated_at: null,
    due: null,
    ...patch,
  });
  const daily = {
    kind: 'daily' as const,
    times: ['08:00'],
    days: [1, 2, 3, 4, 5, 6, 7],
    timezone: 'UTC',
    notify: true,
  };
  const items = [
    topic('a', {
      schedule: daily,
      due: {
        is_due: true,
        due_since: '2026-10-15T08:00:00Z',
        next_due_at: null,
        last_entry_at: null,
      },
    }),
    topic('b', {
      schedule: daily,
      due: {
        is_due: false,
        due_since: null,
        next_due_at: '2026-10-16T08:00:00Z',
        last_entry_at: null,
      },
    }),
    topic('c', {
      schedule: daily,
      due: {
        is_due: false,
        due_since: null,
        next_due_at: '2026-10-15T10:00:00Z',
        last_entry_at: null,
      },
    }),
    topic('d'),
    topic('e', {
      status: 'archived',
      schedule: daily,
      due: {
        is_due: true,
        due_since: '2026-10-15T08:00:00Z',
        next_due_at: null,
        last_entry_at: null,
      },
    }),
  ];

  it('splits into due now / coming up (soonest first) / the rest', () => {
    const s = splitByDue(items, now);
    expect(s.due.map((x) => x.id)).toEqual(['a']);
    expect(s.upcoming.map((x) => x.id)).toEqual(['c', 'b']);
    expect(s.other.map((x) => x.id)).toEqual(['d', 'e']);
  });

  it('counts due active topics for the badge', () => {
    expect(dueCount(items, now)).toBe(1);
    expect(dueCount(items, new Date('2026-10-15T10:30:00Z'))).toBe(2);
  });
});
