/**
 * The run panel's controls (active-surfaces.md §6.1, §1.3): the primary at the `hero` size, the
 * secondaries, the "More" sheet, each action once (§2.2 "no duplication"), busy and disabled
 * states, and the queued reopen's empty list (§1.2 row 11): no controls, and the panel's header
 * says "Resuming…" (§6.3).
 */
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';

import { fold } from '../../lib/runs/fold';
import type { LocalRun } from '../../lib/runs/localView';
import type { Timer } from '../../lib/runs/types';
import { CTX, ev, T0 } from '../../test/runs';
import type * as model from './model';
import { actions, type RunAction, type RunActionKind, type RunActionRole } from './model';
import { actionLabel, actionTitle, RunControls } from './RunControls';
import { RunPanel } from './RunPanel';
import type { RunActions } from './useRunActions';

// `actions` as the model has it, unless a test forces a list: the "Resuming…" projection's `[]`
// (§1.2 row 11) is M1's (timers2.md §5.3) and today's fold can't produce it.
const forced = vi.hoisted(() => ({ list: null as RunAction[] | null }));
vi.mock('./model', async (importOriginal) => {
  const real = await importOriginal<typeof model>();
  return {
    ...real,
    actions: (...args: Parameters<typeof real.actions>) => forced.list ?? real.actions(...args),
  };
});

const a = (kind: RunActionKind, role: RunActionRole, enabled = true): RunAction => ({
  kind,
  role,
  enabled,
  id: kind.type,
});

/** §1.2 row 5: a lap open, running, no step left (typed: the lap it opens is "Rest"). */
const LAP_ROW: RunAction[] = [
  a({ type: 'lap', nextTypeLabel: 'Rest' }, 'primary'),
  a({ type: 'stop' }, 'secondary'),
  a({ type: 'pause' }, 'secondary'),
  a({ type: 'discard' }, 'destructive'),
];

function setup(list: readonly RunAction[], busy = false) {
  const onAction = vi.fn<(action: RunAction) => void>();
  const view = render(<RunControls actions={list} busy={busy} topic="Smoke" onAction={onAction} />);
  return { onAction, ...view };
}

describe('RunControls', () => {
  it('Lap is the primary of a lap topic, at the hero size, with Stop and Pause beside it', () => {
    // A stopwatch (no steps) one lap in: today's `actions` straight from the fold.
    const timer: Timer = { steps: [] };
    const state = fold('r1', { steps: [] }, [
      ev('r1', 'start', T0),
      ev('l1', 'lap', T0 + 1000, { seg: 0 }),
    ]);
    setup(actions(state, 'running', timer, T0 + 2000));
    const primary = screen.getByTestId('run-primary');
    expect(primary).toHaveAccessibleName('Lap');
    expect(primary).toHaveTextContent('Lap');
    expect(primary.className).toContain('min-h-[4.5rem]');
    expect(screen.getByTestId('run-stop')).toHaveAccessibleName('Stop Smoke');
    expect(within(screen.getByTestId('run-stop')).getByText('Stop')).toHaveClass('text-danger');
    expect(screen.getByTestId('run-pause')).toHaveAccessibleName('Pause');
    expect(screen.queryByRole('button', { name: /^Skip/ })).toBeNull();
  });

  it('a typed lap reads "Lap → Rest" and is announced "Lap, then Rest" (§1.3)', () => {
    setup(LAP_ROW);
    const primary = screen.getByTestId('run-primary');
    expect(primary).toHaveTextContent('Lap → Rest');
    expect(primary).toHaveAccessibleName('Lap, then Rest');
  });

  it('renders each action once: primary, secondaries, then More with overflow before destructive', async () => {
    const user = userEvent.setup();
    const list = [
      a({ type: 'next', label: 'Teeth' }, 'primary'),
      a({ type: 'stop' }, 'secondary'),
      a({ type: 'resume' }, 'secondary'),
      a({ type: 'revert' }, 'destructive'),
      a({ type: 'skip', label: 'Teeth' }, 'overflow'),
    ];
    setup(list);
    const group = screen.getByRole('group', { name: 'Run controls' });
    expect(
      within(group)
        .getAllByRole('button')
        .map((b) => b.getAttribute('aria-label')),
    ).toEqual(['Next: Teeth', 'Stop Smoke', 'Resume', 'More']);
    await user.click(screen.getByRole('button', { name: 'More' }));
    const more = await screen.findByRole('list', { name: 'More run actions' });
    expect(
      within(more)
        .getAllByRole('button')
        .map((b) => b.textContent),
    ).toEqual(['Skip Teeth', 'Undo resume…']);
    // Nothing shows twice: every action's test id appears exactly once.
    for (const action of list) {
      const id = action.role === 'primary' ? 'run-primary' : `run-${action.id}`;
      expect(screen.getAllByTestId(id)).toHaveLength(1);
    }
  });

  it('a tap reports its action; a More item closes the sheet first', async () => {
    const user = userEvent.setup();
    const { onAction } = setup(LAP_ROW);
    await user.click(screen.getByTestId('run-primary'));
    await user.click(screen.getByTestId('run-stop'));
    await user.click(screen.getByRole('button', { name: 'More' }));
    await user.click(await screen.findByRole('button', { name: 'Discard run' }));
    expect(screen.queryByRole('list', { name: 'More run actions' })).toBeNull();
    expect(onAction.mock.calls.map(([x]) => x.kind.type)).toEqual(['lap', 'stop', 'discard']);
  });

  it('busy turns every button off, More included (§1.2 row 14); a disabled action stays put', () => {
    const { rerender, onAction } = setup(LAP_ROW, true);
    for (const b of screen.getAllByRole('button')) expect(b).toBeDisabled();
    rerender(
      <RunControls
        actions={LAP_ROW.map((x) => (x.kind.type === 'stop' ? { ...x, enabled: false } : x))}
        busy={false}
        topic="Smoke"
        onAction={onAction}
      />,
    );
    expect(screen.getByTestId('run-stop')).toBeDisabled();
    expect(screen.getByTestId('run-primary')).toBeEnabled();
  });

  it('a queued reopen before its ack (no actions) renders no controls (§1.2 row 11)', () => {
    const { container } = setup([]);
    expect(container).toBeEmptyDOMElement();
  });

  it('a More item shows its whole title: a long skip after a lap wraps, it is not cut', async () => {
    const user = userEvent.setup();
    const label = 'Stretch the calves and the hamstrings slowly';
    setup([...LAP_ROW.slice(0, 3), a({ type: 'skip', label }, 'overflow'), ...LAP_ROW.slice(3)]);
    await user.click(screen.getByRole('button', { name: 'More' }));
    const item = await screen.findByTestId('run-skip');
    const text = within(item).getByText(`Skip ${label}`);
    expect(text).not.toHaveClass('truncate');
    expect(item.className).not.toContain('whitespace-nowrap');
  });

  it('no overflow: no More button', () => {
    setup([a({ type: 'lap', nextTypeLabel: null }, 'primary'), a({ type: 'stop' }, 'secondary')]);
    expect(screen.queryByRole('button', { name: 'More' })).toBeNull();
  });
});

describe('titles and names (§1.3)', () => {
  it.each<[RunActionKind, string, string]>([
    [{ type: 'start' }, 'Start', 'Start Smoke'],
    [{ type: 'next', label: 'Shower' }, 'Next: Shower', 'Next: Shower'],
    [{ type: 'next', label: '' }, 'Next', 'Next'],
    [{ type: 'lap', nextTypeLabel: null }, 'Lap', 'Lap'],
    [{ type: 'lap', nextTypeLabel: 'Rest' }, 'Lap → Rest', 'Lap, then Rest'],
    [{ type: 'skip', label: 'Teeth' }, 'Skip Teeth', 'Skip Teeth'],
    [{ type: 'pause' }, 'Pause', 'Pause'],
    [{ type: 'resume' }, 'Resume', 'Resume'],
    [{ type: 'stop' }, 'Stop', 'Stop Smoke'],
    [{ type: 'addDetails' }, 'Add details', 'Add details to Smoke'],
    [{ type: 'reopen', target: 't' }, 'Resume run', 'Resume the last run of Smoke'],
    [{ type: 'revert' }, 'Undo resume…', 'Undo the resume and keep the stop'],
    [{ type: 'discard' }, 'Discard run…', 'Discard run'],
  ])('%o', (kind, title, label) => {
    expect(actionTitle(kind)).toBe(title);
    expect(actionLabel(kind, 'Smoke')).toBe(label);
  });
});

describe('the run panel', () => {
  const run: LocalRun = {
    id: 'r1',
    topic_id: CTX.topic.id,
    topic: CTX.topic,
    version: 1,
    status: 'running',
    state: fold('r1', { steps: [] }, [ev('r1', 'start', T0)]),
    events: [],
    aliases: [],
    server: null,
    queued: [],
    steps: [],
    requires_answers: false,
    laps: null,
    resuming: false,
    has_entry: false,
  };
  const noTaps: RunActions = {
    busy: false,
    start: () => Promise.resolve(null),
    tap: () => Promise.resolve(null),
    finish: () => Promise.resolve({ status: 'none' }),
  };
  const panel = () =>
    render(
      <RunPanel
        run={run}
        ctx={{ ...CTX, steps: [] }}
        topic="Smoke"
        actions={noTaps}
        onStopped={() => undefined}
        onDiscarded={() => undefined}
      />,
    );

  it('header, then controls, then the table: the controls sit above the laps', () => {
    forced.list = null;
    panel();
    const card = screen.getByLabelText('Run');
    const controls = within(card).getByRole('group', { name: 'Run controls' });
    const table = within(card).getByRole('list', { name: 'Steps' });
    expect(within(card).getByText('Running')).toBeInTheDocument();
    // DOCUMENT_POSITION_FOLLOWING: the table comes after the controls.
    expect(controls.compareDocumentPosition(table) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(within(controls).getByTestId('run-primary')).toHaveAccessibleName('Lap');
  });

  it('a queued reopen before its ack shows "Resuming…" and no controls', () => {
    forced.list = [];
    try {
      panel();
    } finally {
      forced.list = null;
    }
    expect(screen.getByText('Resuming…')).toBeInTheDocument();
    expect(screen.queryByRole('group', { name: 'Run controls' })).toBeNull();
    expect(screen.queryAllByRole('button')).toEqual([]);
  });
});
