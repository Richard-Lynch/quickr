/**
 * TS/Python parity for the timing stats (the timing chart models): every case in
 * shared/fixtures/timing-stats-vectors.json (generated from
 * backend/app/services/timing_stats.py by `make vectors`) must give the same answer here.
 */
import { afterAll, describe, expect, it } from 'vitest';

import raw from '../../../../shared/fixtures/timing-stats-vectors.json?raw';
import { timingFromWire } from './fold';
import { formatInstant, parseInstant } from './instant';
import { timingStats } from './stats';
import type { TimerStep, TimingWire, TopicTiming, TopicTimingWire } from './types';

interface Case {
  name: string;
  versions: Record<string, TimerStep[] | null>;
  current_version: number;
  entries: { entry_id: string; captured_at: string; timing: TimingWire | null }[];
  expected: TopicTimingWire;
}

const vectors = JSON.parse(raw) as { cases: Case[] };
const ran = new Set<string>();

// A case that is skipped, filtered out or lost from the table fails the file.
afterAll(() => {
  const missing = vectors.cases.map((c) => c.name).filter((n) => !ran.has(n));
  if (missing.length) throw new Error(`timing-stats vector cases not run: ${missing.join(', ')}`);
});

const toWire = (t: TopicTiming): TopicTimingWire => ({
  ...t,
  series: t.series.map((p) => ({
    ...p,
    captured_at: formatInstant(p.captured_at),
    started_at: formatInstant(p.started_at),
  })),
});

describe('timing stats vectors (shared with the backend and iOS)', () => {
  it('has cases with unique names', () => {
    expect(vectors.cases.length).toBeGreaterThanOrEqual(15);
    expect(new Set(vectors.cases.map((c) => c.name)).size).toBe(vectors.cases.length);
  });

  it.each(vectors.cases.map((c) => [c.name, c] as const))('%s', (name, c) => {
    // Highest version first, so a port that relies on the Map's order (not sorting by
    // number) gets the wrong labels in versions-sort-as-numbers.
    const versions = new Map(
      Object.entries(c.versions)
        .map(([n, s]) => [Number(n), s] as const)
        .sort(([a], [b]) => b - a),
    );
    const entries = c.entries.map((e) => ({
      entry_id: e.entry_id,
      captured_at: parseInstant(e.captured_at),
      timing: e.timing === null ? null : timingFromWire(e.timing),
    }));
    expect(toWire(timingStats(entries, versions, c.current_version))).toEqual(c.expected);
    ran.add(name);
  });
});
