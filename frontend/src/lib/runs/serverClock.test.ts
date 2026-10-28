import { afterEach, describe, expect, it, vi } from 'vitest';

import { FROM_CACHE_HEADER } from '../../api/constants';
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

  it('ignores a sample more than 24 h off, either way (L5)', () => {
    const day = 24 * 60 * 60 * 1000;
    recordServerTime('10500', 10_000, 10_200);
    expect(recordServerTime(String(10_100 + day + 1), 10_000, 10_200)).toBe(400);
    expect(recordServerTime('1000', 2 * day, 2 * day + 200)).toBe(400);
    expect(localStorage.getItem(SERVER_OFFSET_KEY)).toBe('400');
    expect(recordServerTime(String(10_100 + day), 10_000, 10_200)).toBe(day);
  });

  it('ignores a stored offset more than 24 h off (L-4)', () => {
    localStorage.setItem(SERVER_OFFSET_KEY, String(24 * 60 * 60 * 1000 + 1));
    expect(serverOffset()).toBe(0);
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

  it('measures the round trip around the fetch (receive time after it)', async () => {
    vi.useFakeTimers({ now: 50_000 });
    const base = vi.fn(() => {
      vi.setSystemTime(54_000); // the request took 4 s
      return Promise.resolve(new Response('{}', { headers: { [SERVER_TIME_HEADER]: '53000' } }));
    });
    await timedFetch(base)('/api/v1/runs');
    // Midpoint 52 000: the server is 1 s ahead.
    expect(serverOffset()).toBe(1000);
  });

  it("ignores responses from a cache: the service worker's mark, or an HTTP Age", async () => {
    vi.useFakeTimers({ now: 50_000 });
    const respond = (headers: Record<string, string>) =>
      timedFetch(() =>
        Promise.resolve(
          new Response('{}', { headers: { [SERVER_TIME_HEADER]: '10000', ...headers } }),
        ),
      )('/api/v1/runs');
    await respond({ [FROM_CACHE_HEADER]: '1' });
    await respond({ Age: '30' });
    expect(serverOffset()).toBe(0);
    await respond({});
    expect(serverOffset()).toBe(-40_000);
  });
});
