import { describe, expect, it } from 'vitest';

import { formatInstant, parseInstant } from './instant';

describe('parseInstant', () => {
  it('reads UTC and offset forms to epoch milliseconds', () => {
    expect(parseInstant('1970-01-01T00:00:00Z')).toBe(0);
    expect(parseInstant('2026-10-23T08:00:00Z')).toBe(Date.UTC(2026, 9, 23, 8));
    expect(parseInstant('2026-10-23T09:00:00+01:00')).toBe(Date.UTC(2026, 9, 23, 8));
    expect(parseInstant('2026-10-23T03:00:00-05:00')).toBe(Date.UTC(2026, 9, 23, 8));
    expect(parseInstant('2024-02-29T23:59:59.999Z')).toBe(Date.UTC(2024, 1, 29, 23, 59, 59, 999));
  });

  it('truncates sub-millisecond digits, never rounds', () => {
    expect(parseInstant('2026-10-23T08:00:00.000999Z')).toBe(Date.UTC(2026, 9, 23, 8));
    expect(parseInstant('2026-10-23T08:00:00.9999999Z')).toBe(Date.UTC(2026, 9, 23, 8, 0, 0, 999));
    expect(parseInstant('2026-10-23T08:00:00.5Z')).toBe(Date.UTC(2026, 9, 23, 8, 0, 0, 500));
    // Before the epoch truncation is still toward the earlier millisecond (Python's floor).
    expect(parseInstant('1969-12-31T23:59:59.999900Z')).toBe(-1);
  });

  it.each([
    '2026-10-23T08:00:00',
    '2026-10-23 08:00:00Z',
    '2026-13-01T00:00:00Z',
    '2026-02-29T00:00:00Z',
    '2026-10-23T24:00:00Z',
    '2026-10-23T08:00:00+0100',
    '2026-10-23T08:00:00.Z',
    '',
  ])('refuses %j', (text) => {
    expect(() => parseInstant(text)).toThrow(RangeError);
  });
});

describe('formatInstant', () => {
  it("writes the API's form: Z, six fraction digits only when the milliseconds aren't zero", () => {
    expect(formatInstant(0)).toBe('1970-01-01T00:00:00Z');
    expect(formatInstant(Date.UTC(2026, 9, 23, 8, 0, 1, 1))).toBe('2026-10-23T08:00:01.001000Z');
    expect(formatInstant(-1)).toBe('1969-12-31T23:59:59.999000Z');
  });

  it('round-trips with parseInstant and agrees with Date across years', () => {
    for (let i = 0; i < 2000; i++) {
      const ms = Math.floor((i * 7_919_993_717) % 8_000_000_000_000) - 1_000_000_000_000;
      const text = formatInstant(ms);
      expect(parseInstant(text)).toBe(ms);
      expect(text.replace(/\.(\d{3})000Z$/, '.$1Z')).toBe(
        new Date(ms).toISOString().replace('.000Z', 'Z'),
      );
    }
  });

  it('refuses a fractional millisecond', () => {
    expect(() => formatInstant(1.5)).toThrow(RangeError);
  });
});
