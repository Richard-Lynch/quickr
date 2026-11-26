/** Timing stats edge cases the shared vectors don't pin (timers2.md §7.4). */
import { describe, expect, it } from 'vitest';

import { fold, projectTiming } from './fold';
import { timingStats } from './stats';
import type { FoldTimer, RunEvent } from './types';

const T0 = Date.UTC(2026, 10, 25, 10, 0, 0);
const ev = (id: string, type: RunEvent['type'], at: number, seg: number | null = null) => ({
  id,
  type,
  at,
  seg,
  step: null,
  pause_id: null,
});

describe('timingStats lap types', () => {
  it('sums a lap type whose key is an Object.prototype name as an integer', () => {
    // `constructor` is a valid key (^[a-z][a-z0-9_]*$); a plain record would read the
    // inherited Object constructor and concatenate a string.
    const timer: FoldTimer = { steps: [], laps: [{ key: 'constructor', label: 'Build' }] };
    const state = fold('r1', timer, [
      ev('r1', 'start', T0),
      ev('l1', 'lap', T0 + 60_000, 0),
      ev('x1', 'stop', T0 + 90_000),
    ]);
    const timing = projectTiming(state, timer);
    expect(timing.segments.map((s) => [s.label, s.lap_type])).toEqual([
      ['Build 1', 'constructor'],
      ['Build 2', 'constructor'],
    ]);
    const stats = timingStats(
      [{ entry_id: 'e1', captured_at: timing.ended_at, timing }],
      new Map([[1, timer]]),
      1,
    );
    expect(stats.series[0]?.lap_types).toEqual({ constructor: 90_000 });
    expect(stats.lap_types).toEqual([
      {
        key: 'constructor',
        label: 'Build',
        laps: 2,
        best_ms: 30_000,
        median_ms: 45_000,
        mean_ms: 45_000,
      },
    ]);
  });
});
