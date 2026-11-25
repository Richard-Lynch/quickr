/**
 * TS/Python parity for the run fold: every case in shared/fixtures/run-fold-vectors.json
 * (generated from backend/app/services/run_fold.py by `make vectors`; fold v4,
 * timers2.md §3) must give the same state, effects and timing here, and every stored
 * timing in its `timings` section must decode to the served one. Instants are parsed to
 * integer milliseconds.
 */
import { afterAll, describe, expect, it } from 'vitest';

import raw from '../../../../shared/fixtures/run-fold-vectors.json?raw';
import {
  MAX_RUN_MS,
  eventFromWire,
  fold,
  projectTiming,
  stateToWire,
  timingFromWire,
  timingToWire,
} from './fold';
import type {
  FoldTimer,
  Frozen,
  RunEventWire,
  RunStateWire,
  StoredTimingWire,
  TimingWire,
} from './types';

interface Case {
  name: string;
  timer: string;
  events: RunEventWire[];
  frozen: Frozen | null;
  expected: { state: RunStateWire; timing: TimingWire | null };
}
interface StoredTiming {
  name: string;
  stored: StoredTimingWire;
  expected: TimingWire;
}
interface Vectors {
  meta: { run_id: string; max_run_ms: number; generator_version: number };
  timer_sets: Record<string, FoldTimer>;
  cases: Case[];
  timings: StoredTiming[];
}

const vectors = JSON.parse(raw) as Vectors;
const ran = new Set<string>();

// A case that is skipped, filtered out or lost from the table fails the file.
afterAll(() => {
  const names = [...vectors.cases, ...vectors.timings].map((c) => c.name);
  const missing = names.filter((n) => !ran.has(n));
  if (missing.length) throw new Error(`run-fold vector cases not run: ${missing.join(', ')}`);
});

function timer(c: Case): FoldTimer {
  const t = vectors.timer_sets[c.timer];
  if (!t) throw new Error(`unknown timer set ${c.timer}`);
  return t;
}

describe('run fold vectors (shared with the backend and iOS)', () => {
  it('is fold v4, with cases with unique names, and the same limit', () => {
    expect(vectors.meta.generator_version).toBe(4);
    expect(vectors.cases.length).toBeGreaterThanOrEqual(90);
    const names = [...vectors.cases, ...vectors.timings].map((c) => c.name);
    expect(new Set(names).size).toBe(names.length);
    expect(vectors.meta.max_run_ms).toBe(MAX_RUN_MS);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (name, c) => {
    const state = fold(vectors.meta.run_id, timer(c), c.events.map(eventFromWire), c.frozen);
    expect(stateToWire(state)).toEqual(c.expected.state);
    if (c.expected.timing === null) {
      expect(state.status).not.toBe('stopped');
    } else {
      const timing = projectTiming(state, timer(c));
      expect(timingToWire(timing)).toEqual(c.expected.timing);
      // Exact integer sums (T5).
      expect(timing.segments.reduce((a, s) => a + s.active_ms, 0)).toBe(timing.active_ms);
      expect(timing.segments.reduce((a, s) => a + s.paused_ms, 0)).toBe(timing.paused_ms);
    }
    ran.add(name);
  });

  // timers2.md §3.3: a stored pre-v2 timing has no ids and lap types; they read null.
  it.each(vectors.timings.map((t) => [t.name, t] as const))('timing %s', (name, t) => {
    expect(timingToWire(timingFromWire(t.stored))).toEqual(t.expected);
    ran.add(name);
  });
});
