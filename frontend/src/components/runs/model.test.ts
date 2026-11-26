/** What the run surfaces show, from a run's folded state (timers.md §11.1, §11.2). */
import { describe, expect, it } from 'vitest';

import { T0, ev, runItem, serverRun } from '../../test/runs';
import { fold } from '../../lib/runs/fold';
import { localRuns } from '../../lib/runs/localView';
import type { EntryOut } from '../../client';
import type { RunEvent, RunStatus, Timer, TimerStep } from '../../lib/runs/types';
import {
  actions,
  activeMs,
  alertLine,
  checklist,
  headline,
  laps,
  pendingTimedEntries,
  primaryAction,
  primaryActionV1,
  ENTRY_REOPEN_WINDOW_MS,
  REOPEN_WINDOW_MS,
  resumable,
  resumableFromDetail,
  resumableInView,
  segmentMs,
  skipTarget,
  type RunAction,
  type RunActionKind,
  type RunActionRole,
} from './model';

const STEPS: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
  { key: 'teeth', label: 'Teeth' },
];
const s = (n: number) => T0 + n * 1000;
const run = (events: RunEvent[], steps = STEPS) => ({ state: fold('r1', { steps }, events) });
const start = ev('r1', 'start', T0);

describe('the timers', () => {
  it('count active time: wall time minus closed and open pauses', () => {
    const r = run([
      start,
      ev('p1', 'pause', s(10)),
      ev('u1', 'resume', s(15), { pause_id: 'p1' }),
      ev('p2', 'pause', s(30)),
    ]);
    expect(activeMs(r.state, s(20))).toBe(15_000);
    // Paused since 30 s: the clock stands still.
    expect(activeMs(r.state, s(30))).toBe(25_000);
    expect(activeMs(r.state, s(90))).toBe(25_000);
  });

  it('time the open segment from its own start, less the pauses inside it', () => {
    const r = run([
      start,
      ev('p1', 'pause', s(5)),
      ev('u1', 'resume', s(8), { pause_id: 'p1' }),
      ev('n1', 'next', s(20), { seg: 0 }),
      ev('p2', 'pause', s(25)),
      ev('u2', 'resume', s(27), { pause_id: 'p2' }),
    ]);
    expect(segmentMs(r.state, s(30))).toBe(8_000);
    expect(activeMs(r.state, s(30))).toBe(25_000);
  });

  it('stop at the run’s end once it is stopped', () => {
    const r = run([start, ev('x', 'stop', s(42))]);
    expect(activeMs(r.state, s(100))).toBe(42_000);
    expect(segmentMs(r.state, s(100))).toBe(0);
  });

  it('never go negative when now is before the start (a clock behind the server)', () => {
    const r = run([start]);
    expect(activeMs(r.state, T0 - 5000)).toBe(0);
    expect(segmentMs(r.state, T0 - 5000)).toBe(0);
  });
});

describe('the v1 primary button (§11.1; M2 removes it)', () => {
  it('is "Next: {next step}" while a named step remains', () => {
    expect(primaryActionV1(run([start]), STEPS)).toEqual({
      type: 'next',
      label: 'Next: Breakfast',
    });
  });

  it('is Stop on the last step', () => {
    const r = run([start, ev('n1', 'next', s(1), { seg: 0 }), ev('n2', 'next', s(2), { seg: 1 })]);
    expect(primaryActionV1(r, STEPS)).toEqual({ type: 'stop', label: 'Stop' });
  });

  it('is Stop with no steps (laps of a plain stopwatch)', () => {
    expect(primaryActionV1(run([start], []), [])).toEqual({ type: 'stop', label: 'Stop' });
  });

  it('after a lap between steps, still names the next step', () => {
    const r = run([start, ev('l1', 'lap', s(1), { seg: 0 })]);
    expect(primaryActionV1(r, STEPS).label).toBe('Next: Breakfast');
  });
});

describe('Skip (§4.2)', () => {
  it('skips the open step', () => {
    expect(skipTarget(run([start]), STEPS)).toEqual({ key: 'shower', label: 'Shower' });
  });

  it('after a lap, skips the next step', () => {
    const r = run([start, ev('l1', 'lap', s(1), { seg: 0 })]);
    expect(skipTarget(r, STEPS)).toEqual({ key: 'breakfast', label: 'Breakfast' });
  });

  it('has nothing to skip with no steps left', () => {
    expect(skipTarget(run([start], []), [])).toBeNull();
    const r = run([
      start,
      ev('n1', 'next', s(1), { seg: 0 }),
      ev('n2', 'next', s(2), { seg: 1 }),
      ev('n3', 'next', s(3), { seg: 2 }),
    ]);
    expect(skipTarget(r, STEPS)).toBeNull();
  });
});

describe('the checklist', () => {
  it('marks done (with times), skipped, current and upcoming steps; laps listed apart', () => {
    const r = run([
      start,
      ev('n1', 'next', s(30), { seg: 0 }),
      ev('k1', 'skip', s(31), { seg: 1, step: 'breakfast' }),
      ev('l1', 'lap', s(40), { seg: 1 }),
    ]);
    expect(checklist(r.state, STEPS)).toEqual([
      { key: 'shower', label: 'Shower', status: 'done', ms: 30_000 },
      { key: 'breakfast', label: 'Breakfast', status: 'skipped', ms: null },
      { key: 'teeth', label: 'Teeth', status: 'done', ms: 10_000 },
    ]);
    expect(laps(r.state)).toEqual([]);
    expect(r.state.open?.kind).toBe('lap');
  });

  it('lists closed laps with their times', () => {
    const r = run(
      [start, ev('l1', 'lap', s(5), { seg: 0 }), ev('l2', 'lap', s(12), { seg: 1 })],
      [],
    );
    expect(laps(r.state)).toEqual([
      { label: 'Lap 1', ms: 5_000 },
      { label: 'Lap 2', ms: 7_000 },
    ]);
    expect(r.state.open?.label).toBe('Lap 3');
  });
});

describe('pendingTimedEntries (§8.3)', () => {
  const queued = [
    runItem('start', { id: 'r1', run: 'r1', at: T0 }),
    runItem('stop', { id: 's1', run: 'r1', at: s(60), makes_entry: true }),
  ];

  it('shows the entry a queued stop will make', () => {
    const runs = localRuns([], queued);
    expect(pendingTimedEntries(runs, 'topic-1', new Set()).map((e) => e.id)).toEqual(['r1']);
    expect(pendingTimedEntries(runs, 'other', new Set())).toEqual([]);
  });

  it('drops it once the server’s entry with the run’s id is listed', () => {
    const runs = localRuns([serverRun('r1', [ev('r1', 'start', T0)])], queued);
    expect(pendingTimedEntries(runs, 'topic-1', new Set(['r1']))).toEqual([]);
  });
});

describe('steps not known here (null)', () => {
  const r = run([start]);

  it('offers plain Next (a step may be left), no Skip, and no step list', () => {
    expect(primaryActionV1(r, null)).toEqual({ type: 'next', label: 'Next' });
    expect(skipTarget(r, null)).toBeNull();
    expect(checklist(r.state, null)).toEqual([]);
  });
});

describe('actions (timers2.md §10, R18 stub half; fixture: active-surfaces.md §1.2)', () => {
  // Rows 1–3 (idle) are the topic's last run seen closed: `start`, plus row 13's `reopen`
  // (secondary) within OQ-1's window when the run is stopped with a terminal (a topic with no
  // run doesn't call `actions`). Rows 10 (after a reopen: no `reopen_id` in RunState yet),
  // 11 (queued reopen) and 14 (busy) are not expressible yet (T2-M1: F1-CORE / F1-OUTBOX).
  const TIMER: Timer = { steps: STEPS };
  const LAPS_ONLY: Timer = { steps: [] };
  const a = (kind: RunActionKind, role: RunActionRole): RunAction => ({
    kind,
    role,
    enabled: true,
    id: kind.type,
  });
  const n1 = ev('n1', 'next', s(1), { seg: 0 });
  const n2 = ev('n2', 'next', s(2), { seg: 1 });
  const n3 = ev('n3', 'next', s(3), { seg: 2 });
  const l1 = ev('l1', 'lap', s(1), { seg: 0 });
  const p = ev('p', 'pause', s(4));
  const x = ev('x', 'stop', s(5));
  const stop = a({ type: 'stop' }, 'secondary');
  const pause = a({ type: 'pause' }, 'secondary');
  const resume = a({ type: 'resume' }, 'secondary');
  const discard = a({ type: 'discard' }, 'destructive');
  const lap = a({ type: 'lap', nextTypeLabel: null }, 'primary');
  const next = (label: string) => a({ type: 'next', label }, 'primary');
  const startA = a({ type: 'start' }, 'primary');
  const reopen = (target: string) => a({ type: 'reopen', target }, 'secondary');
  const WINDOW = 15 * 60 * 1000;
  // The fold lowercases ids; the stop's is the terminal.
  const STOP_ID = '0e000000-0000-4000-8000-000000000001';
  const stopEv = ev(STOP_ID, 'stop', s(5));
  const skip = (label: string) => a({ type: 'skip', label }, 'overflow');

  interface Row {
    row: string;
    events: RunEvent[];
    steps?: TimerStep[];
    status?: RunStatus;
    timer: Timer | null;
    /** `now`; defaults to T0. */
    now?: number;
    expected: RunAction[];
  }
  const rows: Row[] = [
    {
      row: '4 step open, a step remains, running',
      events: [],
      timer: TIMER,
      expected: [next('Breakfast'), stop, pause, skip('Shower'), discard],
    },
    {
      row: '5 lap open, a step still pending, running',
      events: [l1],
      timer: TIMER,
      expected: [lap, stop, pause, skip('Breakfast'), discard],
    },
    {
      row: '5 lap open, no step pending, running',
      events: [n1, n2, n3],
      timer: TIMER,
      expected: [lap, stop, pause, discard],
    },
    {
      row: '6 last step open, running',
      events: [n1, n2],
      timer: TIMER,
      expected: [lap, stop, pause, skip('Teeth'), discard],
    },
    {
      row: '7 no steps, running (the stopwatch)',
      events: [],
      steps: [],
      timer: LAPS_ONLY,
      expected: [lap, stop, pause, discard],
    },
    {
      row: '8 paused, step open',
      events: [p],
      timer: TIMER,
      expected: [next('Breakfast'), stop, resume, skip('Shower'), discard],
    },
    {
      row: '8 paused, lap open',
      events: [l1, p],
      timer: TIMER,
      expected: [lap, stop, resume, skip('Breakfast'), discard],
    },
    {
      row: '8 paused, last step open',
      events: [n1, n2, p],
      timer: TIMER,
      expected: [lap, stop, resume, skip('Teeth'), discard],
    },
    {
      row: '8 paused, no steps',
      events: [p],
      steps: [],
      timer: LAPS_ONLY,
      expected: [lap, stop, resume, discard],
    },
    {
      row: '9 timer null, running',
      events: [],
      timer: null,
      expected: [next(''), stop, pause, discard],
    },
    {
      row: '9 timer null, paused',
      events: [p],
      timer: null,
      expected: [next(''), stop, resume, discard],
    },
    {
      row: '12 finishing',
      events: [x],
      status: 'finishing',
      timer: TIMER,
      expected: [a({ type: 'addDetails' }, 'primary'), discard],
    },
    {
      row: '1–3, 13 stopped, within the window: start, reopen(terminal_id) secondary',
      events: [stopEv],
      timer: TIMER,
      now: s(5) + WINDOW,
      expected: [startA, reopen(STOP_ID)],
    },
    {
      row: '1, 13 stopped, timer null: start, reopen still offered',
      events: [stopEv],
      timer: null,
      now: s(5),
      expected: [startA, reopen(STOP_ID)],
    },
    {
      row: '3, 13 stopped, laps only: start, reopen',
      events: [stopEv],
      steps: [],
      timer: LAPS_ONLY,
      now: s(6),
      expected: [startA, reopen(STOP_ID)],
    },
    {
      row: '2, 13 stopped, past the window: start only',
      events: [stopEv],
      timer: TIMER,
      now: s(5) + WINDOW + 1,
      expected: [startA],
    },
    {
      row: '2 stopped without a terminal: start only',
      events: [],
      status: 'stopped',
      timer: TIMER,
      expected: [startA],
    },
    {
      row: '2 discarded: start only',
      events: [ev('d', 'discard', s(5))],
      timer: TIMER,
      expected: [startA],
    },
    {
      row: '2 discarded with a terminal still set: start only (only a stopped run reopens)',
      events: [stopEv],
      status: 'discarded',
      timer: TIMER,
      now: s(5),
      expected: [startA],
    },
  ];
  const of = (r: Row) => {
    const state = fold('r1', { steps: r.steps ?? STEPS }, [start, ...r.events]);
    return { state, status: r.status ?? state.status };
  };

  it.each(rows)('$row', (r) => {
    const { state, status } = of(r);
    const got = actions(state, status, r.timer, r.now ?? T0);
    expect(got).toEqual(r.expected);
    expect(got.every((x) => x.enabled)).toBe(true);
  });

  it('has exactly one primary in every state, never Stop, in display order', () => {
    const rank: Record<RunActionRole, number> = {
      primary: 0,
      secondary: 1,
      overflow: 2,
      destructive: 3,
    };
    for (const r of rows) {
      const { state, status } = of(r);
      const got = actions(state, status, r.timer, r.now ?? T0);
      expect(
        got.filter((x) => x.role === 'primary'),
        r.row,
      ).toHaveLength(1);
      expect(
        got.some((x) => x.kind.type === 'stop' && x.role === 'primary'),
        r.row,
      ).toBe(false);
      const ranks = got.map((x) => rank[x.role]);
      expect(ranks, r.row).toEqual([...ranks].sort((u, v) => u - v));
    }
  });

  it('primaryAction is the primary of actions while the run is open, else null', () => {
    for (const r of rows) {
      const { state, status } = of(r);
      const want =
        status === 'running' || status === 'paused'
          ? (actions(state, status, r.timer, r.now ?? T0).find((x) => x.role === 'primary') ?? null)
          : null;
      expect(primaryAction(state, status, r.timer, r.now ?? T0), r.row).toEqual(want);
    }
  });

  it('start only for a closed run (its primary); reopen secondary; never revert today', () => {
    for (const r of rows) {
      const { state, status } = of(r);
      const got = actions(state, status, r.timer, r.now ?? T0);
      const closed = status === 'stopped' || status === 'discarded';
      expect(
        got.some((x) => x.kind.type === 'start'),
        r.row,
      ).toBe(closed);
      if (closed) expect(got[0]?.kind.type, r.row).toBe('start');
      expect(
        got.filter((x) => x.kind.type === 'reopen').every((x) => x.role === 'secondary'),
        r.row,
      ).toBe(true);
      expect(
        got.map((x) => x.kind.type),
        r.row,
      ).not.toContain('revert');
    }
  });

  it('headline: the open segment’s label today; Running/Paused when nothing is open; no counter', () => {
    expect(headline(fold('r1', { steps: STEPS }, [start]), 'running', TIMER)).toEqual({
      text: 'Shower',
      counter: null,
    });
    expect(headline(fold('r1', { steps: STEPS }, [start, l1]), 'running', null)).toEqual({
      text: 'Lap 1',
      counter: null,
    });
    const stopped = fold('r1', { steps: STEPS }, [start, x]);
    expect(headline(stopped, 'finishing', TIMER)).toEqual({ text: 'Running', counter: null });
    expect(headline(stopped, 'paused', TIMER)).toEqual({ text: 'Paused', counter: null });
  });

  it('alertLine is null until I1-CORE fills it', () => {
    expect(alertLine(fold('r1', { steps: STEPS }, [start]), TIMER, T0)).toBeNull();
  });
});

describe('resumable (timers2.md glossary "Resumable", OQ-1, A15; R18)', () => {
  const at = (ms: number) => new Date(ms).toISOString();
  const STOP = T0 + 30 * 60_000;
  /** A stopped run's entry: started at `started`, stopped at `ended`. */
  const timed = (
    id: string,
    opts: { started?: number; ended?: number; edited?: boolean; terminal?: string | null } = {},
  ): EntryOut => {
    const started = opts.started ?? T0;
    const ended = opts.ended ?? STOP;
    return {
      id,
      topic_id: 'topic-1',
      version: 1,
      revision: 1,
      source: 'ui',
      channel: 'ui',
      captured_at: at(ended),
      created_at: at(ended),
      updated_at: at(ended),
      notes: '',
      meta: {},
      answers: [],
      timing: {
        started_at: at(started),
        ended_at: at(ended),
        active_ms: ended - started,
        paused_ms: 0,
        complete: true,
        edited: opts.edited ?? false,
        segments: [],
        skipped: [],
        pauses: [],
        terminal_id: opts.terminal === undefined ? `${id}-stop` : opts.terminal,
      },
    };
  };
  /** A pre-v2 stored timing: no `terminal_id` key at all (A12). */
  const preV2 = (id: string): EntryOut => {
    const e = timed(id);
    const timing: Partial<NonNullable<EntryOut['timing']>> = { ...e.timing };
    delete timing.terminal_id;
    return { ...e, timing: timing as NonNullable<EntryOut['timing']> };
  };

  it('uses the iOS windows: 15 minutes, 7 days', () => {
    expect(REOPEN_WINDOW_MS).toBe(15 * 60 * 1000);
    expect(ENTRY_REOPEN_WINDOW_MS).toBe(7 * 24 * 60 * 60 * 1000);
  });

  it('tiles and toasts: within 15 minutes of the stop, the boundary included', () => {
    const entry = timed('e1');
    expect(resumable(entry, STOP)).toBe(true);
    expect(resumable(entry, STOP + REOPEN_WINDOW_MS)).toBe(true);
    expect(resumable(entry, STOP + REOPEN_WINDOW_MS + 1)).toBe(false);
  });

  it('the entry detail: within 7 days of the start, the boundary included', () => {
    const entry = timed('e1');
    expect(resumableFromDetail(entry, T0 + ENTRY_REOPEN_WINDOW_MS)).toBe(true);
    expect(resumableFromDetail(entry, T0 + ENTRY_REOPEN_WINDOW_MS + 1)).toBe(false);
    // Measured from the start, not the stop: 7 days after the stop is already past it.
    expect(resumableFromDetail(entry, STOP + ENTRY_REOPEN_WINDOW_MS)).toBe(false);
    // Well past the tiles' window, still offered from the detail.
    expect(resumable(entry, STOP + 60 * 60_000)).toBe(false);
    expect(resumableFromDetail(entry, STOP + 60 * 60_000)).toBe(true);
  });

  it('an edited entry is never resumable; an untimed one neither', () => {
    const edited = timed('e1', { edited: true });
    expect(resumable(edited, STOP)).toBe(false);
    expect(resumableFromDetail(edited, STOP)).toBe(false);
    const untimed: EntryOut = { ...timed('e2'), timing: null };
    expect(resumable(untimed, STOP)).toBe(false);
    expect(resumableFromDetail(untimed, STOP)).toBe(false);
  });

  it('answers, notes and meta changes do not count as edits', () => {
    const entry = { ...timed('e1'), revision: 4, notes: 'later', meta: { k: 'v' } };
    expect(resumable(entry, STOP + 1)).toBe(true);
  });

  it('a pre-v2 entry (no terminal_id) is resumable: Resume sends target null (A12)', () => {
    const entry = preV2('e1');
    expect(entry.timing).not.toHaveProperty('terminal_id');
    expect(resumable(entry, STOP)).toBe(true);
    expect(resumableFromDetail(entry, STOP)).toBe(true);
    expect(resumable(timed('e2', { terminal: null }), STOP)).toBe(true);
    expect(resumableInView(entry, [entry], [], STOP)).toBe(true);
  });

  describe('resumableInView: the composing half (iOS RunOverlay.resumable)', () => {
    it('is the entry half when nothing else is in the view', () => {
      const entry = timed('e1');
      expect(resumableInView(entry, [entry], [], STOP)).toBe(true);
      expect(resumableInView(entry, [entry], [], STOP + REOPEN_WINDOW_MS + 1)).toBe(false);
      const edited = timed('e1', { edited: true });
      expect(resumableInView(edited, [edited], [], STOP)).toBe(false);
    });

    it("A15: false while the topic has a locally open run, queued or the server's", () => {
      const entry = timed('e1');
      const later = STOP + 10_000;
      const queued = localRuns([], [runItem('start', { id: 'r2', run: 'r2', at: later })]);
      expect(resumableInView(entry, [entry], queued, later)).toBe(false);
      const server = localRuns([serverRun('r2', [ev('r2', 'start', later)])], []);
      expect(resumableInView(entry, [entry], server, later)).toBe(false);
      const paused = localRuns(
        [serverRun('r2', [ev('r2', 'start', later), ev('p1', 'pause', later + 1)])],
        [],
      );
      expect(paused[0]?.status).toBe('paused');
      expect(resumableInView(entry, [entry], paused, later + 2)).toBe(false);
      // Another topic's open run doesn't count.
      const elsewhere = localRuns(
        [serverRun('r2', [ev('r2', 'start', later)], { topic_id: 'topic-2' })],
        [],
      );
      expect(resumableInView(entry, [entry], elsewhere, later)).toBe(true);
      // The same topic, its id cased differently: still the topic's open run.
      const upper = localRuns(
        [serverRun('r2', [ev('r2', 'start', later)], { topic_id: 'TOPIC-1' })],
        [],
      );
      expect(resumableInView(entry, [entry], upper, later)).toBe(false);
    });

    it('A15: false once its own run is open again here (reopened), or finishing', () => {
      const entry = timed('e1');
      const reopened = localRuns(
        [serverRun('e1', [ev('e1', 'start', T0)], { status: 'running' })],
        [],
      );
      expect(resumableInView(entry, [entry], reopened, STOP)).toBe(false);
      const finishing = localRuns(
        [serverRun('e1', [ev('e1', 'start', T0), ev('x', 'stop', STOP)], { status: 'finishing' })],
        [],
      );
      expect(finishing[0]?.status).toBe('finishing');
      expect(resumableInView(entry, [entry], finishing, STOP)).toBe(false);
    });

    it("only the topic's latest stop: a later timed entry or a later stop of a run here", () => {
      const older = timed('e1');
      const newer = timed('e2', { started: STOP + 1000, ended: STOP + 60_000 });
      const now = STOP + 61_000;
      expect(resumableInView(older, [older, newer], [], now)).toBe(false);
      expect(resumableInView(newer, [older, newer], [], now)).toBe(true);
      // Another topic's later entry doesn't count.
      const elsewhere = { ...newer, topic_id: 'topic-2' };
      expect(resumableInView(older, [older, elsewhere], [], now)).toBe(true);
      const cased = { ...newer, id: 'E2', topic_id: 'TOPIC-1' };
      expect(resumableInView(older, [older, cased], [], now)).toBe(false);
      // An untimed later entry doesn't count either.
      const untimed: EntryOut = { ...newer, id: 'e3', timing: null };
      expect(resumableInView(older, [older, untimed], [], now)).toBe(true);
      // A newer run that stopped and is finishing has no entry yet, but is the latest stop.
      const finishing = localRuns(
        [
          serverRun('r2', [ev('r2', 'start', STOP + 1000), ev('x2', 'stop', STOP + 60_000)], {
            status: 'finishing',
          }),
        ],
        [],
      );
      expect(resumableInView(older, [older], finishing, now)).toBe(false);
      // A discarded run here doesn't count.
      const discarded = localRuns(
        [],
        [
          runItem('start', { id: 'r3', run: 'r3', at: STOP + 1000 }),
          runItem('discard', { id: 'd3', run: 'r3', at: STOP + 3000 }),
        ],
      );
      expect(discarded.map((r) => r.status)).toEqual(['discarded']);
      expect(resumableInView(older, [older], discarded, now)).toBe(true);
    });

    it('breaks a tie on the stop instant by id, as iOS does', () => {
      const a = timed('e1');
      const b = timed('e2');
      expect(resumableInView(a, [a, b], [], STOP)).toBe(false);
      expect(resumableInView(b, [a, b], [], STOP)).toBe(true);
    });
  });
});
