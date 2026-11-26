/**
 * Resume on the record page (active-surfaces.md §2.4, §6.3; timers2.md §5.3): "Resume · {total}"
 * under Start while the latest stop is resumable (OQ-1's 15 minutes), the stop toast's Resume,
 * both aimed at the entry's `timing.terminal_id`; the "Resuming…" header without controls
 * until the reopen's ack; and Undo resume…, the reopened run's discard.
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import { outbox } from '../../lib/outbox/client';
import { lapTopic, reopens, seedStopped, STOP_ID } from '../../test/resume';
import { renderRunApp, RUN_ID, type Harness } from '../../test/runUi';
import { REOPEN_WINDOW_MS } from './model';

let h: Harness | null = null;
/** The harness's fake server (the test has rendered the app). */
const server = () => {
  if (!h) throw new Error('no harness');
  return h.server;
};

afterEach(async () => {
  await h?.teardown();
  h = null;
});

describe('Resume under Start', () => {
  it('within the window: "Resume · 1:44", which reopens the entry’s terminal stop', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), (s) => seedStopped(s, 114_000, 10_000));
    const user = userEvent.setup();
    const resume = await screen.findByTestId('run-reopen');
    expect(resume).toHaveTextContent('Resume · 1:44');
    expect(resume).toHaveAccessibleName('Resume the last run of Morning');
    const terminal = server().entries[0]?.timing?.terminal_id;
    expect(terminal).toBe(STOP_ID);

    await user.click(resume);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]).toMatchObject({ target: terminal });
    // The run is open again: the panel with its controls, and no Resume.
    expect(await screen.findByTestId('run-stop')).toBeInTheDocument();
    expect(screen.queryByTestId('run-reopen')).toBeNull();
  });

  it('past the window: Start only', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), (s) =>
      seedStopped(s, REOPEN_WINDOW_MS + 120_000, REOPEN_WINDOW_MS + 1_000),
    );
    expect(await screen.findByRole('button', { name: 'Start' })).toBeInTheDocument();
    // The latest entry has loaded, and is too old to resume.
    await waitFor(() =>
      expect(server().requests.some((r) => r.path.endsWith('/entries'))).toBe(true),
    );
    expect(screen.queryByTestId('run-reopen')).toBeNull();
  });

  it('an edited entry is not offered', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), (s) => {
      seedStopped(s, 114_000, 10_000);
      const e = s.entries[0];
      if (e?.timing) s.entries = [{ ...e, timing: { ...e.timing, edited: true } }];
    });
    expect(await screen.findByRole('button', { name: 'Start' })).toBeInTheDocument();
    await waitFor(() =>
      expect(server().requests.some((r) => r.path.endsWith('/entries'))).toBe(true),
    );
    expect(screen.queryByTestId('run-reopen')).toBeNull();
  });

  it('a reopen not yet acked: "Resuming…" and no controls, then the controls on the ack', async () => {
    let hold = true;
    h = renderRunApp('/t/morning/record', lapTopic(), (s) => seedStopped(s, 114_000, 10_000));
    server().override = (body) =>
      body.type === 'reopen' && hold ? new Response('{}', { status: 503 }) : undefined;
    const user = userEvent.setup();
    await user.click(await screen.findByTestId('run-reopen'));

    // The panel's header, from the entry's timing (timers2.md §5.3), with no controls.
    await screen.findByText('Resuming…');
    const card = screen.getByLabelText('Run');
    expect(within(card).queryByRole('group', { name: 'Run controls' })).toBeNull();
    expect(screen.queryByTestId('run-reopen')).toBeNull();
    const item = (await outbox.list()).find((i) => i.status === 'pending');
    expect(item).toBeDefined();

    hold = false;
    await outbox.retry(item?.id ?? '');
    expect(await screen.findByRole('group', { name: 'Run controls' })).toBeInTheDocument();
    expect(screen.getByText('Running')).toBeInTheDocument();
    expect(screen.queryByText('Resuming…')).toBeNull();
  });
});

describe('the stop toast', () => {
  it('offers Resume, which reopens the stop just made (its entry’s terminal_id)', async () => {
    h = renderRunApp('/t/morning/record', lapTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await waitFor(() => expect(server().events()).toHaveLength(1));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().events()).toHaveLength(2));
    const stop = server().events()[1];

    const toast = (await screen.findByText(/^Saved Morning: \d+:\d\d$/)).closest<HTMLElement>(
      '[role]',
    );
    await user.click(within(toast ?? document.body).getByRole('button', { name: 'Resume' }));
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
    expect(server().entries[0]?.timing?.terminal_id).toBe(stop?.id);
  });
});

describe('Undo resume…', () => {
  it('confirms, then sends the reopened run’s discard: the stop and its entry stay', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), (s) => seedStopped(s, 114_000, 10_000));
    const user = userEvent.setup();
    await user.click(await screen.findByTestId('run-reopen'));
    await screen.findByTestId('run-stop');
    await user.click(screen.getByRole('button', { name: 'More' }));
    const list = await screen.findByRole('list', { name: 'More run actions' });
    expect(within(list).queryByTestId('run-discard')).toBeNull();
    await user.click(
      within(list).getByRole('button', { name: 'Undo the resume and keep the stop' }),
    );
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Undo resume' }));

    await waitFor(() => expect(server().events().at(-1)?.type).toBe('discard'), {
      timeout: 4000,
    });
    expect(await screen.findByText('Resume undone')).toBeInTheDocument();
    expect(server().runs.get(RUN_ID)?.status).toBe('stopped');
    expect(server().entries[0]?.timing?.terminal_id).toBe(STOP_ID);
  });
});
