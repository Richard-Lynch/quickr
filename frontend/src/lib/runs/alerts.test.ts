/**
 * The PWA alert planner (timers2.md §9.2, the maths of §9.1's `RunAlertPlan`): the open
 * segment's alerts at `seg_started_at + paused_in_segment + at_ms`, on the server's clock;
 * none while paused or once closed; a missed alert more than 30 s late is dropped.
 */
import { describe, expect, it } from 'vitest';

import { ev, T0 } from '../../test/runs';
import {
  alertKeys,
  alertSchedule,
  LATE_DROP_MS,
  nextAlert,
  planAlerts,
  type AlertTimer,
} from './alerts';
import { fold } from './fold';
import type { RunEvent, RunState } from './types';

const S = 1000;

/** The device-checklist `Intervals` timer: `t = 60s`, `Rest` alerts at `t/2` and `t`. */
const TIMER: AlertTimer = {
  steps: [],
  laps: [
    { key: 'run', label: 'Run', alerts: [] },
    {
      key: 'rest',
      label: 'Rest',
      alerts: [
        { key: 'done', label: 'Done', at: 't', at_ms: 60 * S },
        { key: 'half', label: 'Half way', at: 't/2', at_ms: 30 * S },
      ],
    },
  ],
};

const start = ev('r1', 'start', T0);
/** A lap at T0 + 5 s: `Run 1` closes, `Rest 1` (segment 1) opens. */
const lap = ev('l1', 'lap', T0 + 5 * S, { seg: 0 });
const REST_AT = T0 + 5 * S;

function run(events: RunEvent[], timer: AlertTimer = TIMER) {
  const state: RunState = fold('r1', timer, events);
  return { id: 'r1', status: state.status, state };
}

describe('planAlerts', () => {
  it('plans the open lap type’s alerts from the segment start, earliest first', () => {
    const r = run([start, lap]);
    expect(r.state.open?.label).toBe('Rest 1');
    const plan = planAlerts(r, TIMER, REST_AT + S);
    expect(plan.map((a) => [a.key, a.at, a.label, a.segment])).toEqual([
      ['half', REST_AT + 30 * S, 'Half way', 'Rest 1'],
      ['done', REST_AT + 60 * S, 'Done', 'Rest 1'],
    ]);
    expect(plan[0]?.id).toBe('r1.1.half');
  });

  it('never plans an alert at the segment start (at_ms <= 0), as iOS never schedules it (P3-8)', () => {
    const zero: AlertTimer = {
      steps: [],
      laps: [
        { key: 'run', label: 'Run', alerts: [] },
        {
          key: 'rest',
          label: 'Rest',
          alerts: [
            { key: 'now', label: 'Now', at: '0s', at_ms: 0 },
            { key: 'tt', label: 'T minus t', at: 't-t', at_ms: 0 },
            { key: 'half', label: 'Half way', at: 't/2', at_ms: 30 * S },
          ],
        },
      ],
    };
    const r = run([start, lap], zero);
    // Neither at the instant the segment opens nor within the 30 s late window after it.
    expect(planAlerts(r, zero, REST_AT - 1).map((a) => a.key)).toEqual(['half']);
    expect(planAlerts(r, zero, REST_AT + S, LATE_DROP_MS + 1).map((a) => a.key)).toEqual(['half']);
    expect(alertSchedule([{ run: r, timer: zero }], REST_AT, new Set()).due).toEqual([]);
  });

  it('plans nothing for a lap type with no alerts', () => {
    expect(planAlerts(run([start]), TIMER, T0 + S)).toEqual([]);
  });

  it('shifts by the time paused in the segment, and none while paused', () => {
    const pause = ev('p1', 'pause', REST_AT + 10 * S);
    const paused = run([start, lap, pause]);
    expect(planAlerts(paused, TIMER, REST_AT + 15 * S)).toEqual([]);
    expect(nextAlert(paused, TIMER, REST_AT + 15 * S)).toBeNull();
    const resumed = run([
      start,
      lap,
      pause,
      ev('u1', 'resume', REST_AT + 20 * S, { pause_id: 'p1' }),
    ]);
    expect(planAlerts(resumed, TIMER, REST_AT + 21 * S).map((a) => a.at)).toEqual([
      REST_AT + 40 * S,
      REST_AT + 70 * S,
    ]);
  });

  it('counts only the part of a pause inside the open segment', () => {
    // Paused across the lap: the pause before the segment opened doesn't shift it.
    const events = [
      start,
      ev('p1', 'pause', T0 + 2 * S),
      ev('u1', 'resume', T0 + 4 * S, { pause_id: 'p1' }),
      lap,
    ];
    expect(planAlerts(run(events), TIMER, REST_AT + S).map((a) => a.at)).toEqual([
      REST_AT + 30 * S,
      REST_AT + 60 * S,
    ]);
  });

  it('plans none once the run is closed', () => {
    const stopped = run([start, lap, ev('x', 'stop', REST_AT + 10 * S)]);
    expect(stopped.state.open).toBeNull();
    expect(planAlerts(stopped, TIMER, REST_AT + 11 * S)).toEqual([]);
  });

  it('skips an alert the server hasn’t evaluated (no at_ms)', () => {
    const timer: AlertTimer = {
      steps: [],
      laps: [{ key: 'rest', label: 'Rest', alerts: [{ key: 'a', label: 'A', at: 't' }] }],
    };
    expect(planAlerts(run([start], timer), timer, T0 + S)).toEqual([]);
  });

  it('plans a step’s alerts', () => {
    const timer: AlertTimer = {
      steps: [
        {
          key: 'warm',
          label: 'Warm up',
          alerts: [{ key: 'go', label: 'Go', at: '1m', at_ms: 60 * S }],
        },
      ],
      laps: [],
    };
    const plan = planAlerts(run([start], timer), timer, T0 + S);
    expect(plan.map((a) => [a.id, a.at, a.segment])).toEqual([['r1.0.go', T0 + 60 * S, 'Warm up']]);
  });

  it('keeps instants down to `now - grace`, later ones only by default', () => {
    const r = run([start, lap]);
    const now = REST_AT + 45 * S;
    expect(planAlerts(r, TIMER, now).map((a) => a.key)).toEqual(['done']);
    expect(planAlerts(r, TIMER, now, LATE_DROP_MS).map((a) => a.key)).toEqual(['half', 'done']);
    expect(nextAlert(r, TIMER, now)?.key).toBe('done');
  });
});

describe('alertSchedule', () => {
  const sources = [{ run: run([start, lap]), timer: TIMER }];

  it('waits for the next alert', () => {
    const s = alertSchedule(sources, REST_AT + S, new Set());
    expect(s.due).toEqual([]);
    expect(s.next?.key).toBe('half');
  });

  it('is due at its instant, and passes on once fired', () => {
    const at = REST_AT + 30 * S;
    const s = alertSchedule(sources, at, new Set());
    expect(s.due.map((a) => a.key)).toEqual(['half']);
    expect(s.next?.key).toBe('done');
    const after = alertSchedule(sources, at, new Set(s.due.flatMap(alertKeys)));
    expect(after.due).toEqual([]);
  });

  it('drops an alert more than 30 s late, keeps one 30 s late or less', () => {
    // Back at 65 s of Rest 1: "Half way" is 35 s late (dropped), "Done" 5 s late (due).
    const s = alertSchedule(sources, REST_AT + 65 * S, new Set());
    expect(s.due.map((a) => a.key)).toEqual(['done']);
    expect(s.next).toBeNull();
    // Exactly 30 s late still fires.
    expect(alertSchedule(sources, REST_AT + 60 * S, new Set()).due.map((a) => a.key)).toEqual([
      'half',
      'done',
    ]);
  });

  it('takes the earliest next alert over every run', () => {
    const other = {
      id: 'r2',
      ...(() => {
        const state = fold('r2', TIMER, [
          ev('r2', 'start', T0),
          ev('l2', 'lap', T0 + S, { seg: 0 }),
        ]);
        return { status: state.status, state };
      })(),
    };
    const s = alertSchedule([...sources, { run: other, timer: TIMER }], REST_AT + S, new Set());
    expect(s.next?.id).toBe('r2.1.half');
  });

  it('knows a fired alert by any of its run’s ids (a merged run’s alias)', () => {
    const at = REST_AT + 30 * S;
    const merged = { run: { ...run([start, lap]), id: 'r9', aliases: ['r1'] }, timer: TIMER };
    const fired = alertSchedule(sources, at, new Set()).due.flatMap(alertKeys);
    expect(alertSchedule([merged], at, new Set(fired)).due).toEqual([]);
  });

  it('re-arms when the segment start moves (a removed lap reopens an earlier one)', () => {
    const at = REST_AT + 30 * S;
    const fired = alertSchedule(sources, at, new Set()).due.flatMap(alertKeys);
    const moved = { run: run([start, ev('l1', 'lap', REST_AT - S, { seg: 0 })]), timer: TIMER };
    expect(alertSchedule([moved], at - S, new Set(fired)).due.map((a) => a.key)).toEqual(['half']);
  });

  it('skips a run with no timer known', () => {
    expect(alertSchedule([{ run: run([start, lap]), timer: null }], REST_AT, new Set())).toEqual({
      due: [],
      next: null,
    });
  });
});
