/**
 * #294: the run panel's clocks. The total is the big one; the open segment's is a second big
 * clock at least 60% of it, with its label smaller beside it; both are tabular digits.
 */
import { screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';

import { renderRunApp, seedRun, timedTopic, type Harness } from '../../test/runUi';
import { clockClass } from './RunClock';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

/** The rem cap and container share of a `text-[min(<rem>rem,<cqi>cqi)]` class. */
function size(cls: string): { rem: number; cqi: number } {
  const m = /text-\[min\(([\d.]+)rem,([\d.]+)cqi\)\]/.exec(cls);
  if (!m) throw new Error(`no min() size in ${cls}`);
  return { rem: Number(m[1]), cqi: Number(m[2]) };
}

describe('the run clocks', () => {
  it.each([
    ['under an hour', 61_000],
    ['an hour or more', 3_900_000],
  ])('%s: the segment clock is at least 60% of the total, cap and share', (_, ms) => {
    const total = size(clockClass('total', ms));
    const segment = size(clockClass('segment', ms));
    for (const bound of ['rem', 'cqi'] as const) {
      expect(segment[bound] / total[bound], bound).toBeGreaterThanOrEqual(0.6 - 1e-9);
      expect(segment[bound], bound).toBeLessThan(total[bound]);
    }
  });

  // The monospaced digits are 0.6 em wide: at its share of the container (the card's content
  // box), the longest time of each size fits, whatever the text size, padding or viewport.
  it.each([
    ['under an hour', 0, '59:59'],
    ['an hour or more', 3_600_000, '99:59:59'],
  ])('%s: the longest total fits its container', (_, ms, longest) => {
    expect(longest.length * 0.6 * size(clockClass('total', ms)).cqi).toBeLessThanOrEqual(100);
  });

  it('an hour-long time steps down a size, so it fits', () => {
    expect(size(clockClass('total', 3_600_000)).cqi).toBeLessThan(size(clockClass('total', 0)).cqi);
  });

  it('the panel shows both clocks big, in tabular digits, the label smaller', async () => {
    h = renderRunApp('/t/morning/record', timedTopic(), (s) => seedRun(s));
    const total = await screen.findByTestId('run-clock-total');
    const segment = screen.getByTestId('run-clock-segment');
    for (const clock of [total, segment]) expect(clock).toHaveClass('font-mono', 'tabular');
    expect(total.parentElement).toHaveClass('@container');
    expect(size(total.className).rem).toBeGreaterThanOrEqual(7);
    expect(size(segment.className).rem).toBeGreaterThanOrEqual(4.5);
    expect(screen.getByTestId('segment-label')).toHaveClass('text-lg');
  });
});
