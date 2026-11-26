/** The timing chip and the detail's rows (content-display.md §3.1, §3.2). */
import { describe, expect, it } from 'vitest';

import type { Timing, TimingSegment } from '../client';
import {
  RESUME_FROM_DETAIL_MS,
  removeControl,
  resumableFromDetail,
  spokenChip,
  spokenDuration,
  timingChip,
  timingRows,
} from './entryTiming';

const at = (s: number) => new Date(Date.UTC(2026, 9, 23, 8, 0, s)).toISOString();

function segment(kind: TimingSegment['kind'], start: number, end: number): TimingSegment {
  return {
    kind,
    step: kind === 'step' ? `s${String(start)}` : null,
    label: `${kind} ${String(start)}`,
    started_at: at(start),
    ended_at: at(end),
    active_ms: (end - start) * 1000,
    paused_ms: 0,
    lap_type: null,
    event_id: null,
    opened_by: null,
  };
}

function timing(segments: TimingSegment[], pauses: [number, number][] = []): Timing {
  return {
    started_at: at(0),
    ended_at: at(600),
    active_ms: 760_000,
    paused_ms: 0,
    complete: true,
    edited: false,
    terminal_id: null,
    segments,
    skipped: [],
    pauses: pauses.map(([start, end]) => ({ start: at(start), end: at(end), id: null })),
  };
}

const ids = (t: Timing) => timingRows(t).map((r) => `${r.kind}.${String(r.index)}`);

describe('timingRows', () => {
  const laps = [segment('lap', 0, 100), segment('lap', 100, 200), segment('lap', 200, 300)];

  it('puts each pause after the segment it starts in, keeping its own index', () => {
    // pauses[0] is in the third lap, pauses[1] in the first: time order, original indexes.
    const t = timing(laps, [
      [250, 260],
      [10, 30],
    ]);
    expect(ids(t)).toEqual(['segment.0', 'pause.1', 'segment.1', 'segment.2', 'pause.0']);
  });

  it('puts a pause that starts with a segment after that segment', () => {
    expect(ids(timing(laps, [[100, 120]]))).toEqual([
      'segment.0',
      'segment.1',
      'pause.0',
      'segment.2',
    ]);
  });

  it('puts a pause before the first segment first, and keeps start order for ties', () => {
    const t = timing(laps, [
      [50, 55],
      [-5, 0],
      [50, 52],
    ]);
    expect(ids(t)).toEqual([
      'pause.1',
      'segment.0',
      'pause.0',
      'pause.2',
      'segment.1',
      'segment.2',
    ]);
  });

  it('gives each pause its length', () => {
    const rows = timingRows(timing(laps, [[10, 30]]));
    expect(rows[1]).toMatchObject({ kind: 'pause', index: 0, ms: 20_000 });
  });

  it('lists the pauses alone when there are no segments', () => {
    expect(ids(timing([], [[10, 30]]))).toEqual(['pause.0']);
  });
});

describe('the timing chip', () => {
  it('shows the summary line’s timing part and speaks the duration and the laps', () => {
    const t = timing([segment('lap', 0, 100), segment('lap', 100, 200), segment('lap', 200, 300)]);
    expect(timingChip(t, null)).toEqual({
      text: '12:40 · 3 laps',
      label: '12 minutes 40 seconds, 3 laps',
    });
  });

  it('counts the steps too, steps first', () => {
    const t = {
      ...timing([segment('step', 0, 60), segment('step', 60, 120), segment('lap', 120, 240)]),
      active_ms: 240_000,
    };
    expect(spokenChip(t)).toBe('4 minutes, 2 steps, 1 lap');
  });

  it('is the duration alone without segments, and nothing for an untimed entry', () => {
    expect(spokenChip({ ...timing([]), active_ms: 1000 })).toBe('1 second');
    expect(timingChip(null, null)).toBeNull();
  });
});

describe('spokenDuration', () => {
  it.each([
    [0, '0 seconds'],
    [999, '0 seconds'],
    [-5, '0 seconds'],
    [61_000, '1 minute 1 second'],
    [3_720_000, '1 hour 2 minutes'],
    [7_201_000, '2 hours 1 second'],
  ])('%i ms reads "%s"', (ms, text) => {
    expect(spokenDuration(ms)).toBe(text);
  });
});

describe('removeControl (content-display.md §3.2)', () => {
  const opened = (
    seg: TimingSegment,
    opened_by: TimingSegment['opened_by'],
    event_id: string | null,
  ): TimingSegment => ({ ...seg, opened_by, event_id });
  const t = timing([
    opened(segment('lap', 0, 10), 'lap', 'e0'), // as if it had an id: still the first
    opened(segment('lap', 10, 20), 'lap', 'e1'),
    opened(segment('lap', 20, 30), 'next', 'e2'),
    opened(segment('step', 30, 40), 'next', 'e3'),
    opened(segment('lap', 40, 50), 'lap', null),
    opened(segment('lap', 50, 60), 'skip', 'e5'),
  ]);
  t.pauses = [
    { start: at(12), end: at(14), id: 'p0' },
    { start: at(42), end: at(44), id: null },
  ];
  const control = (kind: 'segment' | 'pause', index: number) => {
    const row = timingRows(t).find((r) => r.kind === kind && r.index === index);
    if (!row) throw new Error('no row');
    return removeControl(row, t);
  };

  it('targets a lap row’s event id and a pause’s id', () => {
    expect(control('segment', 1)).toEqual({ kind: 'remove', target: 'e1' });
    expect(control('pause', 0)).toEqual({ kind: 'remove', target: 'p0' });
  });

  it('is disabled on a lap a next or skip opened, and absent on the first segment, a step and null ids', () => {
    // Only a `lap` event's boundary can be removed (M1's entryIds / RunWrites.entryTargets).
    expect(control('segment', 2)).toEqual({ kind: 'disabled' });
    expect(control('segment', 5)).toEqual({ kind: 'disabled' });
    expect(control('segment', 0)).toEqual({ kind: 'none' });
    expect(control('segment', 3)).toEqual({ kind: 'none' });
    expect(control('segment', 4)).toEqual({ kind: 'none' });
    expect(control('pause', 1)).toEqual({ kind: 'none' });
  });

  it('is absent everywhere on an edited timing', () => {
    const edited = { ...t, edited: true };
    for (const row of timingRows(edited)) expect(removeControl(row, edited).kind).toBe('none');
  });
});

describe('resumableFromDetail', () => {
  const start = Date.parse(at(0));
  const t = timing([segment('lap', 0, 10)]);

  it('holds for 7 days from the run’s start, unedited only', () => {
    expect(resumableFromDetail(t, start + RESUME_FROM_DETAIL_MS)).toBe(true);
    expect(resumableFromDetail(t, start + RESUME_FROM_DETAIL_MS + 1)).toBe(false);
    expect(resumableFromDetail({ ...t, edited: true }, start + 1000)).toBe(false);
    expect(resumableFromDetail(null, start)).toBe(false);
  });
});
