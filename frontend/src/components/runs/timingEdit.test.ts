/** The Edit times model: the server's T2–T5 rules client-side, and the body a save sends. */
import { afterEach, describe, expect, it } from 'vitest';

import type { Timing } from '../../client';
import { parseInstant } from '../../lib/runs/instant';
import {
  checkTimingDraft,
  draftFromTiming,
  fromLocalInput,
  localTimeNote,
  timingFieldOf,
  toLocalSeconds,
  withNewPause,
  withNewSegment,
  withSegmentStep,
  type TimingDraft,
} from './timingEdit';

const steps = [
  { key: 'shower', label: 'Shower' },
  { key: 'dress', label: 'Dress' },
  { key: 'coffee', label: 'Coffee' },
];

/** Shower 0:00–4:00.250 (paused 1:00–1:30), a lap to 5:00, Dress to 9:00; Coffee skipped. */
const timing: Timing = {
  started_at: '2026-10-23T07:00:00.000Z',
  ended_at: '2026-10-23T07:09:00.000Z',
  active_ms: 510_000,
  paused_ms: 30_000,
  complete: false,
  edited: false,
  segments: [
    seg('step', 'shower', 'Shower', '07:00:00.000', '07:04:00.250', 30_000),
    seg('lap', null, 'Lap 1', '07:04:00.250', '07:05:00.000', 0),
    seg('step', 'dress', 'Dress', '07:05:00.000', '07:09:00.000', 0),
  ],
  skipped: ['coffee'],
  pauses: [{ start: '2026-10-23T07:01:00.000Z', end: '2026-10-23T07:01:30.000Z' }],
};

function seg(
  kind: 'step' | 'lap',
  step: string | null,
  label: string,
  from: string,
  to: string,
  paused: number,
): Timing['segments'][number] {
  const a = `2026-10-23T${from}Z`;
  const b = `2026-10-23T${to}Z`;
  return {
    kind,
    step,
    label,
    started_at: a,
    ended_at: b,
    active_ms: parseInstant(b) - parseInstant(a) - paused,
    paused_ms: paused,
  };
}

const local = (iso: string) => toLocalSeconds(parseInstant(iso));
const at = (hms: string) => local(`2026-10-23T${hms}.000Z`);
/** Well after the run, so the 24-hour bound only bites where a test means it to. */
const NOW = Date.parse('2026-12-01T00:00:00Z');
function segAt(d: TimingDraft, i: number) {
  const s = d.segments[i];
  if (!s) throw new Error(`no segment ${String(i)}`);
  return s;
}
const check = (d: TimingDraft, now = NOW) => checkTimingDraft(d, steps, now);

describe('localTimeNote (clock changes)', () => {
  const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } })
    .process.env;
  const previous = env.TZ;
  afterEach(() => {
    if (previous === undefined) delete env.TZ;
    else env.TZ = previous;
  });

  it('notes a time that happens twice, and one that is skipped', () => {
    env.TZ = 'Europe/London';
    // Clocks went back at 02:00 BST on 2026-10-25, and forward at 01:00 GMT on 2026-03-29.
    expect(localTimeNote('2026-10-25T01:30:00')).toBe(
      '01:30:00 happens twice that day (the clocks went back): the earlier one is used.',
    );
    expect(localTimeNote('2026-03-29T01:30')).toBe(
      'There is no 01:30:00 that day (the clocks went forward): it reads as 02:30:00.',
    );
    expect(localTimeNote('2026-10-24T01:30:00')).toBeNull();
    expect(localTimeNote('')).toBeNull();
  });
});

describe('timing edit model', () => {
  it('round-trips local input values to the second', () => {
    const ms = parseInstant('2026-10-23T07:04:05.000Z');
    expect(fromLocalInput(toLocalSeconds(ms))).toBe(ms);
    expect(fromLocalInput('nope')).toBeNull();
  });

  it('an untouched draft sends the run’s exact instants, milliseconds included', () => {
    const r = check(draftFromTiming(timing));
    expect(r.errors).toEqual({});
    expect(r.edit).toEqual({
      started_at: '2026-10-23T07:00:00Z',
      segments: [
        { kind: 'step', step: 'shower', ended_at: '2026-10-23T07:04:00.250000Z' },
        { kind: 'lap', step: null, ended_at: '2026-10-23T07:05:00Z' },
        { kind: 'step', step: 'dress', ended_at: '2026-10-23T07:09:00Z' },
      ],
      skipped: ['coffee'],
      pauses: [{ start: '2026-10-23T07:01:00Z', end: '2026-10-23T07:01:30Z' }],
    });
    expect(r.active_ms).toBe(timing.active_ms);
    expect(r.paused_ms).toBe(30_000);
    expect(r.segments.map((s) => [s.label, s.active_ms])).toEqual([
      ['Shower', 210_250],
      ['Lap 1', 59_750],
      ['Dress', 240_000],
    ]);
  });

  it('an edited end moves the next segment’s start and the totals (T2, T5)', () => {
    const d = draftFromTiming(timing);
    d.segments[0] = { ...segAt(d, 0), ended_at: at('07:03:00') };
    const r = check(d);
    expect(r.edit?.segments[0]?.ended_at).toBe('2026-10-23T07:03:00Z');
    expect(r.segments.map((s) => s.active_ms)).toEqual([150_000, 120_000, 240_000]);
    expect(r.active_ms).toBe(510_000);
  });

  it('refuses a segment ending before it starts (T2)', () => {
    const d = draftFromTiming(timing);
    d.segments[2] = { ...segAt(d, 2), ended_at: at('07:04:30') };
    const r = check(d);
    expect(r.errors).toEqual({ 'segments.2.ended_at': 'Before the segment’s start' });
    expect(r.edit).toBeNull();
  });

  it('refuses a step twice, or timed and skipped (T4), and a step not of the version', () => {
    const twice = withSegmentStep(draftFromTiming(timing), 1, 'shower');
    expect(check(twice).errors).toEqual({
      'segments.1.step': "Step 'Shower' appears more than once",
    });
    const d = draftFromTiming(timing);
    d.skipped = ['coffee', 'dress'];
    expect(check(d).errors).toEqual({ 'skipped.1': "Step 'Dress' appears more than once" });
    const gone = draftFromTiming(timing);
    gone.segments[0] = { ...segAt(gone, 0), step: 'bath' };
    expect(check(gone).errors).toEqual({
      'segments.0.step': "'bath' is not a step of the run's version",
    });
  });

  it('timing a skipped step takes it off the skipped list', () => {
    const d = withSegmentStep(draftFromTiming(timing), 1, 'coffee');
    expect(d.skipped).toEqual([]);
    expect(check(d).edit?.segments[1]).toMatchObject({ kind: 'step', step: 'coffee' });
  });

  it('refuses pauses out of order, reversed or outside the run (T3)', () => {
    const before = draftFromTiming(timing);
    before.pauses = [{ uid: 'p', start: at('06:59:00'), end: at('07:01:00') }];
    expect(check(before).errors).toEqual({
      'pauses.0.start': 'Before the run’s start or the previous pause’s end',
    });
    const reversed = draftFromTiming(timing);
    reversed.pauses = [{ uid: 'p', start: at('07:02:00'), end: at('07:01:00') }];
    expect(check(reversed).errors).toEqual({ 'pauses.0.end': 'Before the pause’s start' });
    const after = draftFromTiming(timing);
    after.pauses = [{ uid: 'p', start: at('07:08:00'), end: at('07:10:00') }];
    expect(check(after).errors).toEqual({ 'pauses.0.end': 'After the run’s end' });
    const overlap = draftFromTiming(timing);
    overlap.pauses = [
      { uid: 'p', start: at('07:01:00'), end: at('07:03:00') },
      { uid: 'q', start: at('07:02:00'), end: at('07:04:00') },
    ];
    expect(Object.keys(check(overlap).errors)).toEqual(['pauses.1.start']);
  });

  it('refuses a run longer than 7 days, an empty run and unparsable times', () => {
    const long = draftFromTiming(timing);
    long.segments[2] = { ...segAt(long, 2), ended_at: local('2026-10-31T07:00:00.000Z') };
    expect(check(long).errors).toEqual({
      'segments.2.ended_at': 'More than 7 days after the start',
    });
    const empty = { ...draftFromTiming(timing), segments: [], pauses: [] };
    expect(check(empty).errors).toEqual({ segments: 'Keep at least one segment' });
    const blank = { ...draftFromTiming(timing), started_at: '' };
    expect(check(blank).errors.started_at).toBe('Enter a date and time');
  });

  it('a new segment times the first unused step, else a lap; lap labels follow the order', () => {
    const d = draftFromTiming({ ...timing, skipped: [] });
    const one = withNewSegment(d, steps);
    expect(one.segments[3]).toMatchObject({
      kind: 'step',
      step: 'coffee',
      ended_at: at('07:09:00'),
    });
    const two = withNewSegment(one, steps);
    expect(two.segments[4]).toMatchObject({ kind: 'lap', step: null });
    const laps = withSegmentStep(two, 0, null);
    expect(check(laps).segments.map((s) => s.label)).toEqual([
      'Lap 1',
      'Lap 2',
      'Dress',
      'Coffee',
      'Lap 3',
    ]);
  });

  it('a new segment or pause copies the run end’s exact millisecond (zero length is fine)', () => {
    const odd: Timing = {
      ...timing,
      ended_at: '2026-10-23T07:09:00.750Z',
      segments: [
        ...timing.segments.slice(0, 2),
        seg('step', 'dress', 'Dress', '07:05:00.000', '07:09:00.750', 0),
      ],
    };
    const d = withNewPause(withNewSegment(draftFromTiming(odd), steps));
    const r = check(d);
    expect(r.errors).toEqual({});
    expect(r.edit?.segments[3]?.ended_at).toBe('2026-10-23T07:09:00.750000Z');
    expect(r.edit?.pauses[1]).toEqual({
      start: '2026-10-23T07:09:00.750000Z',
      end: '2026-10-23T07:09:00.750000Z',
    });
  });

  it('untouched fields showing the same second keep their own milliseconds', () => {
    const close: Timing = {
      ...timing,
      started_at: '2026-10-23T07:00:01.100Z',
      ended_at: '2026-10-23T07:00:01.900Z',
      skipped: [],
      segments: [seg('step', 'shower', 'Shower', '07:00:01.100', '07:00:01.900', 0)],
      pauses: [],
    };
    const d = draftFromTiming(close);
    expect(d.started_at).toBe(segAt(d, 0).ended_at);
    expect(check(d).edit).toMatchObject({
      started_at: '2026-10-23T07:00:01.100000Z',
      segments: [{ ended_at: '2026-10-23T07:00:01.900000Z' }],
    });
    // Edited and set back to the same text: the field's own original again.
    const back = { ...d, started_at: at('07:00:00') };
    expect(check({ ...back, started_at: d.started_at }).edit?.started_at).toBe(
      '2026-10-23T07:00:01.100000Z',
    );
  });

  it('accepts a zero-length segment, exactly 7 days, and a pause starting at the run’s start', () => {
    const zero = draftFromTiming(timing);
    zero.segments[0] = { ...segAt(zero, 0), ended_at: at('07:04:30') };
    zero.segments[1] = { ...segAt(zero, 1), ended_at: at('07:04:30') };
    expect(check(zero).errors).toEqual({});
    expect(check(zero).segments[1]?.active_ms).toBe(0);

    const week = draftFromTiming(timing);
    week.segments[2] = { ...segAt(week, 2), ended_at: local('2026-10-30T07:00:00.000Z') };
    expect(check(week).errors).toEqual({});
    week.segments[2] = { ...segAt(week, 2), ended_at: local('2026-10-30T07:00:01.000Z') };
    expect(check(week).errors).toEqual({
      'segments.2.ended_at': 'More than 7 days after the start',
    });

    const atStart = draftFromTiming(timing);
    atStart.pauses = [{ uid: 'p', start: atStart.started_at, end: at('07:00:30') }];
    expect(check(atStart).errors).toEqual({});
    atStart.pauses.push({ uid: 'q', start: at('07:00:30'), end: at('07:01:00') });
    expect(check(atStart).errors).toEqual({});
  });

  it('checks the captured_at bounds on every instant', () => {
    const d = draftFromTiming(timing);
    expect(check({ ...d, started_at: '1999-12-31T12:00:00' }).errors.started_at).toBe(
      'Must not be before 2000-01-01',
    );
    const now = Date.parse('2026-10-23T07:00:00Z');
    expect(check(d, now).errors).toEqual({});
    const late = { ...d, pauses: [{ uid: 'p', start: at('07:08:00'), end: at('07:08:30') }] };
    expect(check(late, now - 24 * 3_600_000 + 8 * 60_000).errors).toEqual({
      'segments.2.ended_at': 'Must not be more than 24 hours in the future',
      'pauses.0.end': 'Must not be more than 24 hours in the future',
    });
  });

  it('maps the server’s field paths onto the form’s', () => {
    expect(timingFieldOf('timing.segments.1.ended_at')).toBe('segments.1.ended_at');
    expect(timingFieldOf('timing')).toBe('');
    expect(timingFieldOf('captured_at')).toBeNull();
  });
});
