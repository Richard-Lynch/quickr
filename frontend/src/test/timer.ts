import type { TimerInput, TimerOutput } from '../client';

/** `timer` as the server returns it: every list present (timers2.md §1.4). Alerts keep the
 * `at_ms` they carry, so a test that needs one sets it. */
export function normalTimer(timer: TimerInput): TimerOutput {
  return {
    steps: timer.steps.map((s) => ({
      ...s,
      alerts: (s.alerts ?? []).map((a) => ({ ...a, at_ms: a.at_ms ?? 0 })),
    })),
    laps: (timer.laps ?? []).map((l) => ({
      ...l,
      alerts: (l.alerts ?? []).map((a) => ({ ...a, at_ms: a.at_ms ?? 0 })),
    })),
    variables: timer.variables ?? [],
  };
}
