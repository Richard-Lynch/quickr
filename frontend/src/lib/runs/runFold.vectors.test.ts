/**
 * TS/Python parity for the run fold: every case in shared/fixtures/run-fold-vectors.json
 * (generated from backend/app/services/run_fold.py by `make vectors`) must give the same
 * state, effects and timing here. Instants are parsed to integer milliseconds.
 */
import { afterAll, describe, expect, it } from 'vitest';

import raw from '../../../../shared/fixtures/run-fold-vectors.json?raw';
import { MAX_RUN_MS, eventFromWire, fold, projectTiming, stateToWire, timingToWire } from './fold';
import type { Frozen, RunEventWire, RunStateWire, TimerStep, TimingWire } from './types';

interface Case {
  name: string;
  steps: string;
  events: RunEventWire[];
  frozen: Frozen | null;
  expected: { state: RunStateWire; timing: TimingWire | null };
}
interface Vectors {
  meta: { run_id: string; max_run_ms: number };
  step_sets: Record<string, TimerStep[]>;
  cases: Case[];
}

const vectors = JSON.parse(raw) as Vectors;
const ran = new Set<string>();

// A case that is skipped, filtered out or lost from the table fails the file.
afterAll(() => {
  const missing = vectors.cases.map((c) => c.name).filter((n) => !ran.has(n));
  if (missing.length) throw new Error(`run-fold vector cases not run: ${missing.join(', ')}`);
});

function steps(c: Case): TimerStep[] {
  const s = vectors.step_sets[c.steps];
  if (!s) throw new Error(`unknown step set ${c.steps}`);
  return s;
}

describe('run fold vectors (shared with the backend and iOS)', () => {
  it('has cases with unique names, and the same limit', () => {
    expect(vectors.cases.length).toBeGreaterThanOrEqual(40);
    expect(new Set(vectors.cases.map((c) => c.name)).size).toBe(vectors.cases.length);
    expect(vectors.meta.max_run_ms).toBe(MAX_RUN_MS);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (name, c) => {
    const state = fold(vectors.meta.run_id, steps(c), c.events.map(eventFromWire), c.frozen);
    expect(stateToWire(state)).toEqual(c.expected.state);
    if (c.expected.timing === null) {
      expect(state.status).not.toBe('stopped');
    } else {
      const timing = projectTiming(state, steps(c));
      expect(timingToWire(timing)).toEqual(c.expected.timing);
      // Exact integer sums (T5).
      expect(timing.segments.reduce((a, s) => a + s.active_ms, 0)).toBe(timing.active_ms);
      expect(timing.segments.reduce((a, s) => a + s.paused_ms, 0)).toBe(timing.paused_ms);
    }
    ran.add(name);
  });
});
