/** The shared ticker behind every running timer (review L6): ticks, freezes, cleans up. */
import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { resetServerOffset } from '../../lib/runs/serverClock';
import { TICK_MS, useServerNow } from './RunClock';

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(Date.UTC(2026, 9, 24, 8));
  resetServerOffset();
});

afterEach(() => {
  vi.useRealTimers();
});

describe('useServerNow', () => {
  it('ticks while ticking, one interval for every timer, gone with the last', () => {
    const a = renderHook(() => useServerNow(true));
    const b = renderHook(() => useServerNow(true));
    expect(vi.getTimerCount()).toBe(1);
    const t0 = a.result.current;
    act(() => {
      vi.advanceTimersByTime(4 * TICK_MS);
    });
    expect(a.result.current).toBe(t0 + 4 * TICK_MS);
    expect(b.result.current).toBe(a.result.current);
    a.unmount();
    expect(vi.getTimerCount()).toBe(1);
    b.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('stands still while not ticking, at the moment it stopped', () => {
    const { result, rerender } = renderHook(({ on }) => useServerNow(on), {
      initialProps: { on: true },
    });
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    act(() => {
      vi.advanceTimersByTime(100);
    });
    rerender({ on: false });
    const stopped = result.current;
    expect(stopped).toBe(Date.now());
    expect(vi.getTimerCount()).toBe(0);
    act(() => {
      vi.advanceTimersByTime(5000);
    });
    rerender({ on: false });
    expect(result.current).toBe(stopped);
  });
});
