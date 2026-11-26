/**
 * The timer editor's v2 parts (timers2.md §1.6): lap types with keys in the steps' namespace,
 * variables lowercased on entry, and alerts per step and lap type evaluated live with the
 * draft's variables, their errors shown with the server's message at the field.
 */
import { zodResolver } from '@hookform/resolvers/zod';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { FormProvider, useForm } from 'react-hook-form';
import { describe, expect, it, vi } from 'vitest';

import type { TimerInput } from '../../client';
import {
  draftFromTimer,
  emptyTopicDraft,
  makeVersionDraftSchema,
  type TimerHistory,
  type TopicDraft,
  type VersionDraftOutput,
} from '../../lib/builder';
import { TimerEditor } from './TimerEditor';

function Harness({
  timer,
  history,
  onValid,
}: {
  timer: TimerInput | null;
  history?: TimerHistory;
  onValid: (out: VersionDraftOutput) => void;
}) {
  const form = useForm<TopicDraft, unknown, VersionDraftOutput>({
    resolver: zodResolver(makeVersionDraftSchema()),
    defaultValues: { ...emptyTopicDraft(), ...draftFromTimer(timer) },
    mode: 'onSubmit',
    reValidateMode: 'onChange',
  });
  return (
    <FormProvider {...form}>
      <form noValidate onSubmit={(e) => void form.handleSubmit(onValid)(e)}>
        <TimerEditor history={history} />
        <button type="submit">Save</button>
      </form>
    </FormProvider>
  );
}

function setup(timer: TimerInput | null, history?: TimerHistory) {
  const onValid = vi.fn();
  render(<Harness timer={timer} history={history} onValid={onValid} />);
  return { user: userEvent.setup(), onValid };
}

const keys = (testId: string) => screen.getAllByTestId(testId).map((k) => k.textContent);

const runRest: TimerInput = {
  steps: [{ key: 'warm', label: 'Warm up' }],
  laps: [
    { key: 'run', label: 'Run', alerts: [{ key: 'half', label: 'Half', at: 't/2' }] },
    { key: 'rest', label: 'Rest' },
  ],
  variables: [{ name: 't', ms: 60_000 }],
};

describe('lap types editor', () => {
  it('derives a new lap type’s key from its label, avoiding step keys', async () => {
    const { user } = setup({ steps: [{ key: 'run', label: 'Run' }] });
    await user.click(screen.getByRole('button', { name: 'Add lap type' }));
    await user.type(screen.getByLabelText('Lap type 1 name'), 'Run');
    expect(keys('lap-type-key')).toEqual(['run_2']);
    await user.clear(screen.getByLabelText('Lap type 1 name'));
    await user.type(screen.getByLabelText('Lap type 1 name'), 'Rest');
    expect(keys('lap-type-key')).toEqual(['rest']);
  });

  it('a published lap type keeps its key on rename', async () => {
    const { user, onValid } = setup(runRest);
    const name = screen.getByLabelText('Lap type 1 name');
    await user.clear(name);
    await user.type(name, 'Jog');
    expect(keys('lap-type-key')).toEqual(['run', 'rest']);
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => {
      expect(onValid).toHaveBeenCalled();
    });
    const out = onValid.mock.calls[0]?.[0] as VersionDraftOutput;
    expect(out.timer?.laps.map((l) => [l.key, l.label])).toEqual([
      ['run', 'Jog'],
      ['rest', 'Rest'],
    ]);
  });

  it('a new lap type named like a retired one takes its key back; other names never do', async () => {
    const history = { steps: [], laps: [{ key: 'jog', label: 'Jog' }] };
    const { user } = setup({ steps: [] }, history);
    await user.click(screen.getByRole('button', { name: 'Add lap type' }));
    await user.type(screen.getByLabelText('Lap type 1 name'), 'jog');
    expect(keys('lap-type-key')).toEqual(['jog']);
    await user.click(screen.getByRole('button', { name: 'Add lap type' }));
    await user.type(screen.getByLabelText('Lap type 2 name'), 'Jog!');
    expect(keys('lap-type-key')).toEqual(['jog', 'jog_2']);
  });

  it('reorders and removes lap types', async () => {
    const { user } = setup(runRest);
    await user.click(screen.getByRole('button', { name: 'Move down: Run (lap type 1)' }));
    expect(keys('lap-type-key')).toEqual(['rest', 'run']);
    await user.click(screen.getByRole('button', { name: 'Remove Rest (lap type 1)' }));
    expect(keys('lap-type-key')).toEqual(['run']);
  });
});

describe('variables editor', () => {
  it('lowercases names on entry and sends durations as ms', async () => {
    const { user, onValid } = setup({ steps: [] });
    await user.click(screen.getByRole('button', { name: 'Add variable' }));
    await user.type(screen.getByLabelText('Variable 1 name'), 'Rest');
    expect(screen.getByLabelText<HTMLInputElement>('Variable 1 name').value).toBe('rest');
    await user.type(screen.getByLabelText('Variable 1 duration'), '1:30');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => {
      expect(onValid).toHaveBeenCalled();
    });
    const out = onValid.mock.calls[0]?.[0] as VersionDraftOutput;
    expect(out.timer?.variables).toEqual([{ name: 'rest', ms: 90_000 }]);
  });

  it('refuses a unit as a name, at the name', async () => {
    const { user, onValid } = setup({ steps: [] });
    await user.click(screen.getByRole('button', { name: 'Add variable' }));
    await user.type(screen.getByLabelText('Variable 1 name'), 'M');
    await user.type(screen.getByLabelText('Variable 1 duration'), '1:00');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    const input = screen.getByLabelText('Variable 1 name');
    await waitFor(() => {
      expect(input).toHaveAttribute('aria-invalid', 'true');
    });
    expect(input).toHaveAccessibleDescription(
      "'m' is a unit (ms, s, m, h) and can't be a variable name",
    );
    expect(onValid).not.toHaveBeenCalled();
  });
});

describe('alerts editor', () => {
  it('shows a count badge on a collapsed lap type with alerts', () => {
    setup(runRest);
    const run = screen.getByRole('button', { name: 'Alerts: Run (lap type 1)' });
    expect(run).toHaveAttribute('aria-expanded', 'false');
    expect(within(run).getByTestId('alert-count').textContent).toBe('1');
    const rest = screen.getByRole('button', { name: 'Alerts: Rest (lap type 2)' });
    expect(within(rest).queryByTestId('alert-count')).toBeNull();
  });

  it('evaluates the expression live with the draft’s variables', async () => {
    const { user } = setup(runRest);
    await user.click(screen.getByRole('button', { name: 'Alerts: Run (lap type 1)' }));
    const group = screen.getByRole('group', { name: 'Alerts for Run (lap type 1)' });
    expect(within(group).getByTestId('alert-result').textContent).toBe('at 0:30');
    const at = within(group).getByLabelText('Alert 1 time');
    await user.clear(at);
    await user.type(at, '(t/2)+30s');
    expect(within(group).getByTestId('alert-result').textContent).toBe('at 1:00');
    // Changing a variable changes the result.
    const t = screen.getByLabelText('Variable 1 duration');
    await user.clear(t);
    await user.type(t, '2:00');
    expect(within(group).getByTestId('alert-result').textContent).toBe('at 1:30');
  });

  it('an invalid expression shows the server’s message at the field, before and on submit', async () => {
    const { user, onValid } = setup(runRest);
    await user.click(screen.getByRole('button', { name: 'Alerts: Run (lap type 1)' }));
    const group = screen.getByRole('group', { name: 'Alerts for Run (lap type 1)' });
    const at = within(group).getByLabelText('Alert 1 time');
    await user.clear(at);
    await user.type(at, 'x/2');
    const message = "Unknown_variable at 0: unknown variable 'x'";
    // Live, before submitting.
    expect(within(group).getByTestId('alert-result').textContent).toBe(message);
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => {
      expect(at).toHaveAttribute('aria-invalid', 'true');
    });
    expect(at).toHaveAccessibleDescription(message);
    expect(onValid).not.toHaveBeenCalled();
  });

  it('adds an alert to a step, with a key from its label, and sends at_ms', async () => {
    const { user, onValid } = setup(runRest);
    await user.click(screen.getByRole('button', { name: 'Alerts: Warm up (step 1)' }));
    const group = screen.getByRole('group', { name: 'Alerts for Warm up (step 1)' });
    await user.click(within(group).getByRole('button', { name: 'Add alert' }));
    await user.type(within(group).getByLabelText('Alert 1 name'), 'Halfway');
    await user.type(within(group).getByLabelText('Alert 1 time'), 't/2');
    expect(within(group).getByTestId('alert-key').textContent).toBe('halfway');
    const toggle = screen.getByRole('button', { name: 'Alerts: Warm up (step 1)' });
    expect(within(toggle).getByTestId('alert-count').textContent).toBe('1');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => {
      expect(onValid).toHaveBeenCalled();
    });
    const out = onValid.mock.calls[0]?.[0] as VersionDraftOutput;
    expect(out.timer?.steps[0]?.alerts).toEqual([
      { key: 'halfway', label: 'Halfway', at: 't/2', at_ms: 30_000 },
    ]);
  });
});

describe('the Timed switch', () => {
  it('parks lap types and variables while off and restores them when back on', async () => {
    const { user, onValid } = setup(runRest);
    const sw = screen.getByRole('switch', { name: 'Timed' });
    await user.click(sw);
    expect(screen.queryByLabelText('Lap type 1 name')).toBeNull();
    expect(screen.queryByLabelText('Variable 1 name')).toBeNull();
    await user.click(sw);
    expect(screen.getByLabelText<HTMLInputElement>('Lap type 2 name').value).toBe('Rest');
    expect(screen.getByLabelText<HTMLInputElement>('Variable 1 name').value).toBe('t');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await waitFor(() => {
      expect(onValid).toHaveBeenCalled();
    });
    const out = onValid.mock.calls[0]?.[0] as VersionDraftOutput;
    expect(out.timer?.laps).toHaveLength(2);
    expect(out.timer?.variables).toEqual([{ name: 't', ms: 60_000 }]);
  });
});
