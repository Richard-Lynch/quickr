/** What the run surfaces show, from a run's folded state (timers.md §11.1, §11.2). */
import { describe, expect, it } from 'vitest';

import { T0, ev, runItem, serverRun } from '../../test/runs';
import { fold } from '../../lib/runs/fold';
import { localRuns } from '../../lib/runs/localView';
import type { RunEvent, TimerStep } from '../../lib/runs/types';
import {
  activeMs,
  checklist,
  laps,
  pendingTimedEntries,
  primaryAction,
  segmentMs,
  skipTarget,
} from './model';

const STEPS: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
  { key: 'teeth', label: 'Teeth' },
];
const s = (n: number) => T0 + n * 1000;
const run = (events: RunEvent[], steps = STEPS) => ({ state: fold('r1', steps, events) });
const start = ev('r1', 'start', T0);

describe('the timers', () => {
  it('count active time: wall time minus closed and open pauses', () => {
    const r = run([
      start,
      ev('p1', 'pause', s(10)),
      ev('u1', 'resume', s(15), { pause_id: 'p1' }),
      ev('p2', 'pause', s(30)),
    ]);
    expect(activeMs(r.state, s(20))).toBe(15_000);
    // Paused since 30 s: the clock stands still.
    expect(activeMs(r.state, s(30))).toBe(25_000);
    expect(activeMs(r.state, s(90))).toBe(25_000);
  });

  it('time the open segment from its own start, less the pauses inside it', () => {
    const r = run([
      start,
      ev('p1', 'pause', s(5)),
      ev('u1', 'resume', s(8), { pause_id: 'p1' }),
      ev('n1', 'next', s(20), { seg: 0 }),
      ev('p2', 'pause', s(25)),
      ev('u2', 'resume', s(27), { pause_id: 'p2' }),
    ]);
    expect(segmentMs(r.state, s(30))).toBe(8_000);
    expect(activeMs(r.state, s(30))).toBe(25_000);
  });

  it('stop at the run’s end once it is stopped', () => {
    const r = run([start, ev('x', 'stop', s(42))]);
    expect(activeMs(r.state, s(100))).toBe(42_000);
    expect(segmentMs(r.state, s(100))).toBe(0);
  });

  it('never go negative when now is before the start (a clock behind the server)', () => {
    const r = run([start]);
    expect(activeMs(r.state, T0 - 5000)).toBe(0);
    expect(segmentMs(r.state, T0 - 5000)).toBe(0);
  });
});

describe('the primary button (§11.1)', () => {
  it('is "Next: {next step}" while a named step remains', () => {
    expect(primaryAction(run([start]), STEPS)).toEqual({ type: 'next', label: 'Next: Breakfast' });
  });

  it('is Stop on the last step', () => {
    const r = run([start, ev('n1', 'next', s(1), { seg: 0 }), ev('n2', 'next', s(2), { seg: 1 })]);
    expect(primaryAction(r, STEPS)).toEqual({ type: 'stop', label: 'Stop' });
  });

  it('is Stop with no steps (laps of a plain stopwatch)', () => {
    expect(primaryAction(run([start], []), [])).toEqual({ type: 'stop', label: 'Stop' });
  });

  it('after a lap between steps, still names the next step', () => {
    const r = run([start, ev('l1', 'lap', s(1), { seg: 0 })]);
    expect(primaryAction(r, STEPS).label).toBe('Next: Breakfast');
  });
});

describe('Skip (§4.2)', () => {
  it('skips the open step', () => {
    expect(skipTarget(run([start]), STEPS)).toEqual({ key: 'shower', label: 'Shower' });
  });

  it('after a lap, skips the next step', () => {
    const r = run([start, ev('l1', 'lap', s(1), { seg: 0 })]);
    expect(skipTarget(r, STEPS)).toEqual({ key: 'breakfast', label: 'Breakfast' });
  });

  it('has nothing to skip with no steps left', () => {
    expect(skipTarget(run([start], []), [])).toBeNull();
    const r = run([
      start,
      ev('n1', 'next', s(1), { seg: 0 }),
      ev('n2', 'next', s(2), { seg: 1 }),
      ev('n3', 'next', s(3), { seg: 2 }),
    ]);
    expect(skipTarget(r, STEPS)).toBeNull();
  });
});

describe('the checklist', () => {
  it('marks done (with times), skipped, current and upcoming steps; laps listed apart', () => {
    const r = run([
      start,
      ev('n1', 'next', s(30), { seg: 0 }),
      ev('k1', 'skip', s(31), { seg: 1, step: 'breakfast' }),
      ev('l1', 'lap', s(40), { seg: 1 }),
    ]);
    expect(checklist(r.state, STEPS)).toEqual([
      { key: 'shower', label: 'Shower', status: 'done', ms: 30_000 },
      { key: 'breakfast', label: 'Breakfast', status: 'skipped', ms: null },
      { key: 'teeth', label: 'Teeth', status: 'done', ms: 10_000 },
    ]);
    expect(laps(r.state)).toEqual([]);
    expect(r.state.open?.kind).toBe('lap');
  });

  it('lists closed laps with their times', () => {
    const r = run(
      [start, ev('l1', 'lap', s(5), { seg: 0 }), ev('l2', 'lap', s(12), { seg: 1 })],
      [],
    );
    expect(laps(r.state)).toEqual([
      { label: 'Lap 1', ms: 5_000 },
      { label: 'Lap 2', ms: 7_000 },
    ]);
    expect(r.state.open?.label).toBe('Lap 3');
  });
});

describe('pendingTimedEntries (§8.3)', () => {
  const queued = [
    runItem('start', { id: 'r1', run: 'r1', at: T0 }),
    runItem('stop', { id: 's1', run: 'r1', at: s(60), makes_entry: true }),
  ];

  it('shows the entry a queued stop will make', () => {
    const runs = localRuns([], queued);
    expect(pendingTimedEntries(runs, 'topic-1', new Set()).map((e) => e.id)).toEqual(['r1']);
    expect(pendingTimedEntries(runs, 'other', new Set())).toEqual([]);
  });

  it('drops it once the server’s entry with the run’s id is listed', () => {
    const runs = localRuns([serverRun('r1', [ev('r1', 'start', T0)])], queued);
    expect(pendingTimedEntries(runs, 'topic-1', new Set(['r1']))).toEqual([]);
  });
});
