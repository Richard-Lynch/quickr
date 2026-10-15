import { useLayoutEffect, useRef, useState, type RefObject } from 'react';

export const SERIES = [1, 2, 3, 4, 5, 6].map((i) => `var(--color-series-${i})`);
export const OTHER_COLOR = 'var(--color-line-strong)';

/** Width of an element, tracked with ResizeObserver. */
export function useWidth<T extends HTMLElement>(fallback = 320): [RefObject<T | null>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(fallback);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    setWidth(el.clientWidth || fallback);
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(([entry]) => {
      if (entry) setWidth(Math.max(120, Math.floor(entry.contentRect.width)));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [fallback]);
  return [ref, width];
}

/** "Nice" axis ticks (1/2/5 × 10^n). */
export function niceTicks(min: number, max: number, count = 4): number[] {
  if (!Number.isFinite(min) || !Number.isFinite(max)) return [0];
  if (min === max) {
    const pad = Math.abs(min) * 0.1 || 1;
    min -= pad;
    max += pad;
  }
  const span = max - min;
  const raw = span / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= count) ?? 10 * mag;
  const start = Math.floor(min / step) * step;
  const end = Math.ceil(max / step) * step;
  const ticks: number[] = [];
  for (let v = start; v <= end + step * 1e-9; v += step) ticks.push(Number(v.toFixed(10)));
  return ticks;
}

export function scaleLinear(d0: number, d1: number, r0: number, r1: number): (v: number) => number {
  const span = d1 - d0 || 1;
  return (v) => r0 + ((v - d0) / span) * (r1 - r0);
}

const tickFmt = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2, notation: 'compact' });
export function formatTick(v: number): string {
  return tickFmt.format(v);
}

export type Bucket = 'day' | 'week' | 'month';

export function formatBucket(
  iso: string,
  bucket: Bucket,
  style: 'short' | 'long' = 'short',
): string {
  const d = new Date(iso);
  if (bucket === 'month') {
    return d.toLocaleDateString(undefined, {
      month: style === 'short' ? 'short' : 'long',
      year: style === 'long' ? 'numeric' : '2-digit',
    });
  }
  const s = d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return bucket === 'week' && style === 'long' ? `Week of ${s}` : s;
}

/**
 * Indices of x positions to label so labels never collide: always the last,
 * then walk left keeping any at least `minGap` px from the previous kept one.
 */
export function pickLabels(xs: readonly number[], minGap: number): Set<number> {
  const keep = new Set<number>();
  let lastX = Infinity;
  for (let i = xs.length - 1; i >= 0; i--) {
    const x = xs[i] ?? 0;
    if (lastX - x >= minGap) {
      keep.add(i);
      lastX = x;
    }
  }
  return keep;
}
