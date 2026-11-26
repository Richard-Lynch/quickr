/** The Overview's Timing chart models (timers.md §9, §11.5). */
import { describe, expect, it } from 'vitest';

import type { SeriesPoint, TimingSeriesPoint } from '../../client';
import { toOffsetIso } from '../../lib/dates';
import { fmtDuration } from '../../lib/runs/format';
import {
  activityLevel,
  activityStrip,
  addDays,
  bucketStart,
  durationTicks,
  localDay,
  localMidnight,
  SPARK_LAYOUT,
  sparkline,
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
    lap_types: {},
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

/** Epoch ms of a UTC wire instant. */
const at = (iso: string) => Date.parse(iso);
const countOf = (strip: ReturnType<typeof activityStrip>, day: string) =>
  strip.cells.find((c) => c.day === day)?.count;

describe('activity strip (content-display.md §4.2)', () => {
  it('starts on the Monday 11 weeks before this week and ends today', () => {
    // 2026-11-25 is a Wednesday; its week starts Monday 2026-11-23.
    const wed = activityStrip([], '2026-11-25', 'UTC');
    expect(wed.firstDay).toBe('2026-09-07');
    expect(wed.cells).toHaveLength(77 + 3);
    expect(wed.cells[0]).toEqual({ day: '2026-09-07', count: 0 });
    expect(wed.cells.at(-1)).toEqual({ day: '2026-11-25', count: 0 });
    expect([wed.max, wed.total]).toEqual([0, 0]);
    // Today on a Monday: the last column has one cell; on a Sunday, the grid is full.
    expect(activityStrip([], '2026-11-23', 'UTC').cells).toHaveLength(78);
    expect(activityStrip([], '2026-11-23', 'UTC').firstDay).toBe('2026-09-07');
    expect(activityStrip([], '2026-11-29', 'UTC').cells).toHaveLength(84);
    expect(activityStrip([], '2026-11-29', 'UTC').firstDay).toBe('2026-09-07');
    expect(activityStrip([], '2026-11-30', 'UTC').firstDay).toBe('2026-09-14');
  });

  it('counts the edges of the grid in, and the instants just outside out', () => {
    const tz = 'Europe/London';
    const strip = activityStrip(
      [
        at('2026-09-06T22:59:59.999Z'), // 23:59:59.999 BST the day before the first cell
        at('2026-09-06T23:00:00Z'), // 00:00 BST on the first cell
        at('2026-11-25T23:59:00Z'), // 23:59 GMT today
        at('2026-11-26T00:00:00Z'), // tomorrow
      ],
      '2026-11-25',
      tz,
    );
    expect(countOf(strip, '2026-09-07')).toBe(1);
    expect(countOf(strip, '2026-11-25')).toBe(1);
    expect([strip.total, strip.max]).toEqual([2, 1]);
    expect(localMidnight(strip.firstDay, tz)).toBe(at('2026-09-06T23:00:00Z'));
  });

  it('puts an instant in its local day in the given zone', () => {
    const instant = at('2026-10-25T23:30:00Z');
    expect(localDay(instant, 'Pacific/Auckland')).toBe('2026-10-26');
    expect(localDay(instant, 'America/Los_Angeles')).toBe('2026-10-25');
    expect(countOf(activityStrip([instant], '2026-11-01', 'Pacific/Auckland'), '2026-10-26')).toBe(
      1,
    );
    expect(
      countOf(activityStrip([instant], '2026-11-01', 'America/Los_Angeles'), '2026-10-25'),
    ).toBe(1);
  });

  it('keeps DST days whole: London spring-forward and fall-back', () => {
    const tz = 'Europe/London';
    // 2026-03-29 has 23 hours (01:00 GMT -> 02:00 BST); 2026-10-25 has 25.
    expect(localMidnight('2026-03-29', tz)).toBe(at('2026-03-29T00:00:00Z'));
    expect(localMidnight('2026-03-30', tz)).toBe(at('2026-03-29T23:00:00Z'));
    expect(localMidnight('2026-10-25', tz)).toBe(at('2026-10-24T23:00:00Z'));
    expect(localMidnight('2026-10-26', tz)).toBe(at('2026-10-26T00:00:00Z'));
    const fall = activityStrip(
      [at('2026-10-24T23:00:00Z'), at('2026-10-25T00:30:00Z'), at('2026-10-25T23:59:59Z')],
      '2026-10-25',
      tz,
    );
    expect(countOf(fall, '2026-10-25')).toBe(3);
    expect(countOf(fall, '2026-10-24')).toBe(0);
  });

  it('a midnight that the clocks skip starts the day at the end of the gap', () => {
    // America/Santiago, 2026-09-06: 00:00 -04 -> 01:00 -03.
    expect(localMidnight('2026-09-06', 'America/Santiago')).toBe(at('2026-09-06T04:00:00Z'));
    expect(localMidnight('2026-09-05', 'America/Santiago')).toBe(at('2026-09-05T04:00:00Z'));
  });

  it('adds calendar days across months and years', () => {
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDays('2024-03-01', -1)).toBe('2024-02-29');
  });

  it('intensity steps 0, 1, 2–3, 4+', () => {
    expect([0, 1, 2, 3, 4, 40].map(activityLevel)).toEqual([0, 1, 2, 2, 3, 3]);
  });
});

describe('sparkline (content-display.md §4.3)', () => {
  const p = (start: string, mean: number | null): SeriesPoint => ({
    start,
    count: 1,
    mean,
    min: mean,
    max: mean,
    option_counts: {},
  });
  const { height, pad } = SPARK_LAYOUT;

  it('is null when no bucket has a mean', () => {
    expect(sparkline([], 100)).toBeNull();
    expect(sparkline([p('2026-11-02T00:00:00Z', null)], 100)).toBeNull();
  });

  it('spaces points by time, the largest mean on top, and marks the last', () => {
    const model = sparkline(
      [
        p('2026-11-02T00:00:00Z', 2),
        p('2026-11-03T00:00:00Z', null),
        p('2026-11-04T00:00:00Z', 6),
        p('2026-11-06T00:00:00Z', 4),
      ],
      108,
    );
    expect(model).toEqual({
      path: [
        [pad, height - pad],
        [pad + 50, pad],
        [108 - pad, height / 2],
      ],
      last: { x: 108 - pad, y: height / 2, value: 4 },
      min: 2,
      max: 6,
    });
  });

  it('one point, or one value, draws at mid height; the one point at the right edge', () => {
    expect(sparkline([p('2026-11-02T00:00:00Z', 7)], 100)?.path).toEqual([[100 - pad, height / 2]]);
    expect(
      sparkline([p('2026-11-02T00:00:00Z', 7), p('2026-11-03T00:00:00Z', 7)], 100)?.path,
    ).toEqual([
      [pad, height / 2],
      [100 - pad, height / 2],
    ]);
  });
});
