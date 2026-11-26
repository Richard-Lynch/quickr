/**
 * Where each run action goes (active-surfaces.md §1, §6.1, §6.2), table-driven over the 14 rows of
 * the §1.2 state table. Rows today's `actions` yields are folded and passed through it; the rest
 * (idle, after a reopen, a queued reopen, busy) are the table's lists by hand.
 */
import { describe, expect, it } from 'vitest';

import { T0, ev } from '../../test/runs';
import { fold } from '../../lib/runs/fold';
import type { RunEvent, RunStatus, Timer, TimerStep } from '../../lib/runs/types';
import {
  controlsLayout,
  tileControls,
  type ControlsLayout,
  type TileControls,
} from './controlsLayout';
import { actions, type RunAction, type RunActionKind, type RunActionRole } from './model';

const STEPS: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
  { key: 'teeth', label: 'Teeth' },
];
const TIMER: Timer = { steps: STEPS };
const LAPS_ONLY: Timer = { steps: [] };
const TERMINAL = '00000000-0000-4000-8000-000000000013';
const s = (n: number) => T0 + n * 1000;
const start = ev('r1', 'start', T0);
const n1 = ev('n1', 'next', s(1), { seg: 0 });
const n2 = ev('n2', 'next', s(2), { seg: 1 });
const l1 = ev('l1', 'lap', s(1), { seg: 0 });
const p = ev('p', 'pause', s(4));
const x = ev('x', 'stop', s(5));

const a = (kind: RunActionKind, role: RunActionRole, enabled = true): RunAction => ({
  kind,
  role,
  enabled,
  id: kind.type,
});
const startA = a({ type: 'start' }, 'primary');
const reopen = a({ type: 'reopen', target: TERMINAL }, 'secondary');
const stop = a({ type: 'stop' }, 'secondary');
const pause = a({ type: 'pause' }, 'secondary');
const resume = a({ type: 'resume' }, 'secondary');
const discard = a({ type: 'discard' }, 'destructive');
const revert = a({ type: 'revert' }, 'destructive');
const lap = a({ type: 'lap', nextTypeLabel: null }, 'primary');
const next = (label: string) => a({ type: 'next', label }, 'primary');
const skip = (label: string) => a({ type: 'skip', label }, 'overflow');
const off = (action: RunAction): RunAction => ({ ...action, enabled: false });

/** M1's actions for a run folded from `start` plus `events`. */
function folded(
  events: RunEvent[],
  timer: Timer | null,
  opts: { steps?: TimerStep[]; status?: RunStatus } = {},
): RunAction[] {
  const state = fold('r1', { steps: opts.steps ?? STEPS }, [start, ...events]);
  return actions(state, opts.status ?? state.status, timer, T0);
}

interface Row extends ControlsLayout {
  row: string;
  actions: RunAction[];
  tile: TileControls;
}
const noTile: TileControls = { primary: null, stop: null, pauseResume: null };
const idleTile: TileControls = { primary: startA, stop: null, pauseResume: null };
const openTile = (primary: RunAction, pauseResume: RunAction): TileControls => ({
  primary,
  stop,
  pauseResume,
});

const rows: Row[] = [
  {
    row: '1 idle, timer null',
    actions: [startA],
    primary: startA,
    secondaries: [],
    overflow: [],
    tile: idleTile,
  },
  {
    row: '2 idle, timer with steps, latest entry resumable',
    actions: [startA, reopen],
    primary: startA,
    secondaries: [reopen],
    overflow: [],
    tile: idleTile,
  },
  {
    row: '3 idle, laps only (as 2)',
    actions: [startA, reopen],
    primary: startA,
    secondaries: [reopen],
    overflow: [],
    tile: idleTile,
  },
  {
    row: '4 step open, a step remains, running',
    actions: folded([], TIMER),
    primary: next('Breakfast'),
    secondaries: [stop, pause],
    overflow: [skip('Shower'), discard],
    tile: openTile(next('Breakfast'), pause),
  },
  {
    row: '5 lap open, a step pending, running',
    actions: folded([l1], TIMER),
    primary: lap,
    secondaries: [stop, pause],
    overflow: [skip('Breakfast'), discard],
    tile: openTile(lap, pause),
  },
  {
    row: '6 last step open, running',
    actions: folded([n1, n2], TIMER),
    primary: lap,
    secondaries: [stop, pause],
    overflow: [skip('Teeth'), discard],
    tile: openTile(lap, pause),
  },
  {
    row: '7 no steps, running (the stopwatch)',
    actions: folded([], LAPS_ONLY, { steps: [] }),
    primary: lap,
    secondaries: [stop, pause],
    overflow: [discard],
    tile: openTile(lap, pause),
  },
  {
    row: '8 paused (row 4)',
    actions: folded([p], TIMER),
    primary: next('Breakfast'),
    secondaries: [stop, resume],
    overflow: [skip('Shower'), discard],
    tile: openTile(next('Breakfast'), resume),
  },
  {
    row: '9 open, timer null',
    actions: folded([], null),
    primary: next(''),
    secondaries: [stop, pause],
    overflow: [discard],
    tile: openTile(next(''), pause),
  },
  {
    row: '10 open after a reopen (row 4)',
    actions: [next('Breakfast'), stop, pause, skip('Shower'), revert],
    primary: next('Breakfast'),
    secondaries: [stop, pause],
    overflow: [skip('Shower'), revert],
    tile: openTile(next('Breakfast'), pause),
  },
  {
    row: '11 queued reopen not yet acked',
    actions: [],
    primary: null,
    secondaries: [],
    overflow: [],
    tile: noTile,
  },
  {
    row: '12 finishing',
    actions: folded([x], TIMER, { status: 'finishing' }),
    primary: a({ type: 'addDetails' }, 'primary'),
    secondaries: [],
    overflow: [discard],
    tile: { primary: a({ type: 'addDetails' }, 'primary'), stop: null, pauseResume: null },
  },
  {
    row: '13 stopped, entry resumable',
    actions: [reopen],
    primary: null,
    secondaries: [reopen],
    overflow: [],
    tile: noTile,
  },
  {
    // M1's idle rows (§1.2): a stopped run within the window is `start` plus `reopen`.
    row: '13 stopped, within the window',
    actions: folded([x], TIMER, { status: 'stopped' }),
    primary: startA,
    secondaries: [a({ type: 'reopen', target: 'x' }, 'secondary')],
    overflow: [],
    tile: idleTile,
  },
  {
    row: '14 busy (row 4)',
    actions: [next('Breakfast'), stop, pause, skip('Shower'), discard].map(off),
    primary: off(next('Breakfast')),
    secondaries: [off(stop), off(pause)],
    overflow: [off(skip('Shower')), off(discard)],
    tile: { primary: off(next('Breakfast')), stop: off(stop), pauseResume: off(pause) },
  },
];

describe('controlsLayout (fixture: active-surfaces.md §1.2)', () => {
  it.each(rows)('$row', (r) => {
    expect(controlsLayout(r.actions)).toEqual({
      primary: r.primary,
      secondaries: r.secondaries,
      overflow: r.overflow,
    });
    expect(tileControls(r.actions)).toEqual(r.tile);
  });

  it.each(rows)('$row: every action lands in exactly one slot', (r) => {
    const { primary, secondaries, overflow } = controlsLayout(r.actions);
    const placed = [...(primary ? [primary] : []), ...secondaries, ...overflow];
    expect(placed).toHaveLength(r.actions.length);
    expect(new Set(placed)).toEqual(new Set(r.actions));
  });

  it("places by role only: reopen and revert land in their role's slot, overflow included", () => {
    const overflowReopen = a({ type: 'reopen', target: TERMINAL }, 'overflow');
    const got = controlsLayout([
      revert,
      a({ type: 'lap', nextTypeLabel: 'Rest' }, 'primary'),
      overflowReopen,
      stop,
    ]);
    expect(got.primary?.kind).toEqual({ type: 'lap', nextTypeLabel: 'Rest' });
    expect(got.secondaries.map((x) => x.id)).toEqual(['stop']);
    expect(got.overflow).toEqual([overflowReopen, revert]);
  });

  it('sends a second primary and an unknown role to the overflow, ahead of destructive actions', () => {
    const unknown = { ...a({ type: 'skip', label: 'Teeth' }, 'overflow'), role: 'later' };
    const got = controlsLayout([
      discard,
      startA,
      a({ type: 'addDetails' }, 'primary'),
      unknown as unknown as RunAction,
    ]);
    expect(got.primary?.id).toBe('start');
    expect(got.overflow.map((x) => x.id)).toEqual(['addDetails', 'skip', 'discard']);
  });
});
