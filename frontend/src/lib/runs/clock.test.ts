/** Server-time offset and the per-run clamp (timers.md §5.1; R12's cases for the PWA). */
import { describe, expect, it } from 'vitest';

import {
  INITIAL_OFFSET_MS,
  MAX_SAMPLE_RTT_MS,
  clampToRun,
  latestAt,
  nextOffset,
  offsetSample,
  parseServerTime,
  serverNow,
  stampRunEvent,
} from './clock';

describe('parseServerTime', () => {
  it('reads integer epoch milliseconds', () => {
    expect(parseServerTime('1792742400123')).toBe(1_792_742_400_123);
    expect(parseServerTime(' 1792742400123 ')).toBe(1_792_742_400_123);
  });

  it.each([null, undefined, '', 'abc', '1792742400.5', '-5', '1e12', '99999999999999999999'])(
    'ignores %j',
    (v) => {
      expect(parseServerTime(v)).toBeNull();
    },
  );
});

describe('offset', () => {
  it('is 0 before the first sample', () => {
    expect(INITIAL_OFFSET_MS).toBe(0);
  });

  it('is server time minus the midpoint of the round trip', () => {
    // Sent at 1000, received at 1200: the server's 5100 is taken as device 1100.
    expect(offsetSample(5100, 1000, 1200)).toBe(4000);
    // A device clock ahead of the server gives a negative offset.
    expect(offsetSample(1000, 5000, 5400)).toBe(-4200);
    // A half-millisecond midpoint is floored to a whole millisecond.
    expect(offsetSample(5100, 1000, 1201)).toBe(3999); // 5100 − 1100.5
  });

  it('takes a round trip of exactly 5 s, and ignores a longer or a negative one', () => {
    expect(offsetSample(10_000, 0, MAX_SAMPLE_RTT_MS)).toBe(7500);
    expect(offsetSample(10_000, 0, MAX_SAMPLE_RTT_MS + 1)).toBeNull();
    expect(offsetSample(10_000, 100, 99)).toBeNull();
  });

  it('comes from the latest qualifying response, not an average', () => {
    let offset = INITIAL_OFFSET_MS;
    offset = nextOffset(offset, 5100, 1000, 1200);
    expect(offset).toBe(4000);
    offset = nextOffset(offset, 9000, 2000, 2000);
    expect(offset).toBe(7000);
    // A slow response, or one without the header, keeps the last offset.
    offset = nextOffset(offset, 0, 3000, 3000 + MAX_SAMPLE_RTT_MS + 1);
    expect(offset).toBe(7000);
    offset = nextOffset(offset, null, 4000, 4010);
    expect(offset).toBe(7000);
  });
});

describe('stamping a run event', () => {
  it('is device now plus the offset, truncated to a whole millisecond', () => {
    expect(serverNow(1000, 250)).toBe(1250);
    expect(serverNow(1000, -250)).toBe(750);
    expect(serverNow(1000.9, 0)).toBe(1000); // performance-style fractional clocks
  });

  it('uses the last known offset while offline', () => {
    const offset = nextOffset(INITIAL_OFFSET_MS, 5100, 1000, 1200); // last sample, then offline
    expect(stampRunEvent(60_000, offset, [])).toBe(64_000);
    expect(stampRunEvent(120_000, offset, [64_000])).toBe(124_000);
  });

  it("is clamped up to the run's latest local at, so a device's own events never go backwards", () => {
    // The offset dropped (or the device clock jumped back) after the last event.
    expect(stampRunEvent(10_000, 0, [12_000, 11_000])).toBe(12_000);
    // Equal to the latest is fine; later is left alone.
    expect(stampRunEvent(12_000, 0, [12_000])).toBe(12_000);
    expect(stampRunEvent(13_000, 0, [12_000])).toBe(13_000);
  });

  it('clamps against the run’s events only', () => {
    expect(latestAt([])).toBeNull();
    expect(latestAt([3, 9, 4])).toBe(9);
    expect(latestAt(new Set([5]).values())).toBe(5);
    expect(clampToRun(7, null)).toBe(7);
    expect(clampToRun(7, 9)).toBe(9);
  });
});
