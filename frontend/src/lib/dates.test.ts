import { describe, expect, it } from 'vitest';

import { localInputToIso, rangeStart, toLocalInputValue, toOffsetIso } from './dates';

describe('dates', () => {
  it('formats local datetime-input values and converts back to aware ISO', () => {
    const d = new Date(2026, 9, 15, 8, 5, 0);
    const local = toLocalInputValue(d);
    expect(local).toBe('2026-10-15T08:05');
    const iso = localInputToIso(local);
    expect(iso).toMatch(/^2026-10-15T08:05:00[+-]\d{2}:\d{2}$/);
    expect(new Date(iso ?? '').getTime()).toBe(d.getTime());
    expect(localInputToIso('nope')).toBeNull();
  });

  it('offset ISO strings parse back to the same instant', () => {
    const d = new Date();
    d.setMilliseconds(0);
    expect(new Date(toOffsetIso(d)).getTime()).toBe(d.getTime());
  });

  it('rangeStart anchors to local midnight', () => {
    const now = new Date(2026, 9, 15, 13, 0, 0);
    const start = new Date(rangeStart('7d', now) ?? '');
    expect(start.getDate()).toBe(9);
    expect(start.getHours()).toBe(0);
    expect(rangeStart('all', now)).toBeUndefined();
  });
});
