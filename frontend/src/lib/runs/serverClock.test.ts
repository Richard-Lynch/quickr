import { afterEach, describe, expect, it, vi } from 'vitest';

import { SERVER_TIME_HEADER } from './clock';
import {
  SERVER_OFFSET_KEY,
  recordServerTime,
  resetServerOffset,
  serverOffset,
  timedFetch,
} from './serverClock';

afterEach(() => {
  resetServerOffset();
  vi.useRealTimers();
});

describe('server clock (timers.md §5.1)', () => {
  it('is 0 before the first sample', () => {
    expect(serverOffset()).toBe(0);
  });

  it('keeps the latest qualifying sample, in localStorage', () => {
    expect(recordServerTime('10500', 10_000, 10_200)).toBe(400);
    expect(localStorage.getItem(SERVER_OFFSET_KEY)).toBe('400');
    expect(recordServerTime('20000', 20_000, 20_000)).toBe(0);
    expect(serverOffset()).toBe(0);
  });

  it('ignores slow round trips and missing or bad headers', () => {
    recordServerTime('10500', 10_000, 10_200);
    expect(recordServerTime('99999', 10_000, 15_001)).toBe(400);
    expect(recordServerTime(null, 10_000, 10_100)).toBe(400);
    expect(recordServerTime('soon', 10_000, 10_100)).toBe(400);
  });

  it('reads the offset another tab stored', () => {
    localStorage.setItem(SERVER_OFFSET_KEY, '-250');
    expect(serverOffset()).toBe(-250);
  });

  it('records every response, errors included, through timedFetch', async () => {
    vi.useFakeTimers({ now: 50_000 });
    const base = vi.fn(() =>
      Promise.resolve(
        new Response('{}', { status: 422, headers: { [SERVER_TIME_HEADER]: '53000' } }),
      ),
    );
    const res = await timedFetch(base)('/api/v1/runs');
    expect(res.status).toBe(422);
    expect(serverOffset()).toBe(3000);
  });
});
