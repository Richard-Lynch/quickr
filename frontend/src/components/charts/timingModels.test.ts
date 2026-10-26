/** The Overview's Timing chart models (timers.md §9, §11.5). */
import { describe, expect, it } from 'vitest';

import type { TimingSeriesPoint } from '../../client';
import { toOffsetIso } from '../../lib/dates';
import { fmtDuration } from '../../lib/runs/format';
import {
  bucketStart,
  durationTicks,
  stepBars,
  stepsByBucket,
  totalsByBucket,
} from './timingModels';

/** A run ending at local `y-m-d h:00`. 2026-10-19 is a Monday. */
function run(
  d: number,
  h: number,
  active: number,
  steps: Record<string, number> = {},
): TimingSeriesPoint {
  const end = new Date(2026, 9, d, h).toISOString();
  return {
    entry_id: `e${String(d)}${String(h)}`,
    captured_at: end,
    started_at: end,
    active_ms: active,
    paused_ms: 0,
    complete: true,
    steps,
  };
}

const local = (y: number, m: number, d: number) => toOffsetIso(new Date(y, m, d));

describe('timing chart models', () => {
  it('buckets by local day, Monday-started week and month', () => {
    const sat = new Date(2026, 9, 24, 23, 30).getTime();
    expect(bucketStart(sat, 'day')).toEqual(new Date(2026, 9, 24));
    expect(bucketStart(sat, 'week')).toEqual(new Date(2026, 9, 19));
    expect(bucketStart(new Date(2026, 9, 19, 1).getTime(), 'week')).toEqual(new Date(2026, 9, 19));
    expect(bucketStart(new Date(2026, 9, 25, 12).getTime(), 'week')).toEqual(new Date(2026, 9, 19));
    expect(bucketStart(sat, 'month')).toEqual(new Date(2026, 9, 1));
  });

  it('totals: floored mean, min and max per bucket, in time order, every run counted', () => {
    const series = [run(20, 8, 100_001), run(19, 8, 200_000), run(20, 9, 100_000)];
    expect(totalsByBucket(series, 'day')).toEqual([
      {
        start: local(2026, 9, 19),
        count: 1,
        mean: 200_000,
        min: 200_000,
        max: 200_000,
        option_counts: {},
      },
      {
        start: local(2026, 9, 20),
        count: 2,
        mean: 100_000,
        min: 100_000,
        max: 100_001,
        option_counts: {},
      },
    ]);
    expect(totalsByBucket(series, 'week')).toEqual([
      {
        start: local(2026, 9, 19),
        count: 3,
        mean: 133_333,
        min: 100_000,
        max: 200_000,
        option_counts: {},
      },
    ]);
    expect(totalsByBucket([], 'day')).toEqual([]);
  });

  it('steps: mean time per run in each bucket, a run without the step counting 0', () => {
    const series = [run(19, 8, 0, { pour: 100, drink: 300 }), run(19, 9, 0, { pour: 201 })];
    expect(stepsByBucket(series, 'day')).toEqual([
      {
        start: local(2026, 9, 19),
        count: 2,
        mean: null,
        min: null,
        max: null,
        option_counts: { pour: 150, drink: 150 },
      },
    ]);
  });

  it('duration ticks fall on whole seconds, minutes or hours', () => {
    expect(durationTicks(100_000, 300_000)).toEqual([60_000, 120_000, 180_000, 240_000, 300_000]);
    expect(durationTicks(100_000, 300_000).map(fmtDuration)).toEqual([
      '1:00',
      '2:00',
      '3:00',
      '4:00',
      '5:00',
    ]);
    expect(durationTicks(5_000, 5_000)).toEqual([0, 30_000, 60_000, 90_000]);
    expect(durationTicks(0, 3 * 3_600_000)).toEqual([0, 3_600_000, 7_200_000, 10_800_000]);
  });

  it('step bars scale each median against the longest', () => {
    const bars = stepBars([
      {
        key: 'a',
        label: 'A',
        current: true,
        done: 2,
        skipped: 0,
        best_ms: 50,
        median_ms: 100,
        mean_ms: 100,
      },
      {
        key: 'b',
        label: 'B',
        current: false,
        done: 0,
        skipped: 2,
        best_ms: null,
        median_ms: null,
        mean_ms: null,
      },
      {
        key: 'c',
        label: 'C',
        current: true,
        done: 1,
        skipped: 1,
        best_ms: 400,
        median_ms: 400,
        mean_ms: 400,
      },
    ]);
    expect(bars.map((b) => [b.key, b.share])).toEqual([
      ['a', 0.25],
      ['b', 0],
      ['c', 1],
    ]);
  });
});
