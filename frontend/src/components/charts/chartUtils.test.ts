import { describe, expect, it } from 'vitest';

import { niceTicks, pickLabels, scaleLinear } from './chartUtils';

describe('chart helpers', () => {
  it('niceTicks covers the domain with round steps', () => {
    expect(niceTicks(0, 24, 4)).toEqual([0, 10, 20, 30]);
    expect(niceTicks(3, 8, 4)).toEqual([2, 4, 6, 8]);
    const flat = niceTicks(5, 5);
    expect(flat[0]).toBeLessThan(5);
    expect(flat[flat.length - 1]).toBeGreaterThan(5);
  });

  it('scaleLinear maps domain to range', () => {
    const s = scaleLinear(0, 10, 100, 0);
    expect(s(0)).toBe(100);
    expect(s(5)).toBe(50);
  });

  it('pickLabels always keeps the last label and avoids collisions', () => {
    expect([...pickLabels([0, 10, 20, 100, 105], 50)].sort((a, b) => a - b)).toEqual([2, 4]);
    expect(pickLabels([0, 60, 120], 50).size).toBe(3);
  });
});
