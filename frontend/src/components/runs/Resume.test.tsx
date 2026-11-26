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
import { lapTopic, reopens, seedStopped, STOP_ID, WINDOW_MS } from '../../test/resume';
import type { FakeRunServer } from '../../test/fakeRunServer';
import { renderRunApp, RUN_ID, type Harness } from '../../test/runUi';

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
      seedStopped(s, WINDOW_MS + 120_000, WINDOW_MS + 1_000),
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

describe('the stop toast, checked again at the tap', () => {
  /** The fake server's `getEntry` (the toast fetches the entry when it isn't cached). */
  const withGetEntry = (s: FakeRunServer) => {
    const base = s.fetch;
    s.fetch = (input, init) => {
      const url = new URL(
        input instanceof Request ? input.url : input instanceof URL ? input.href : input,
        'https://q.test',
      );
      const m = /^\/api\/v1\/entries\/([^/]+)$/.exec(url.pathname);
      const entry = m ? s.entries.find((e) => e.id === decodeURIComponent(m[1] ?? '')) : undefined;
      if (entry) {
        s.requests.push({ method: 'GET', path: url.pathname, body: undefined });
        return Promise.resolve(
          new Response(JSON.stringify(entry), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          }),
        );
      }
      return base(input, init);
    };
  };

  /** No queued item and no fetch in flight. */
  const settled = async () => {
    await waitFor(async () => expect(await outbox.list()).toHaveLength(0));
    await waitFor(() => expect(h?.qc.isFetching()).toBe(0));
  };

  it('with the latest entry not cached, fetches the run’s entry and reopens that stop', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), withGetEntry);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const stop = server().events()[1];
    const resume = await screen.findByRole('button', { name: 'Resume' });
    // Settled: the stop is sent, and no refetch is in flight to refill the cache.
    await settled();
    // The latest-entry cache no longer has it (as after another entry, or a cache reset).
    h.qc.setQueriesData<{ items: unknown[] }>({ queryKey: [{ _id: 'listEntries' }] }, (d) =>
      d ? { ...d, items: [] } : d,
    );
    await user.click(resume);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
    expect(
      server().requests.some((r) => r.method === 'GET' && /\/entries\/[^/]+$/.test(r.path)),
    ).toBe(true);
  });

  it('an older toast whose stop was resumed and stopped again since does nothing, and says so', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), withGetEntry);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const first = server().events()[1];
    // On the topics page now: Resume from the tile, then Stop on the card (a second toast).
    // Each tap waits for the sync to settle: the tile re-renders its offer and card as the
    // acks and refetches land, and a click on a replaced button reaches nothing.
    await settled();
    await user.click(await screen.findByTestId('run-reopen'));
    await waitFor(() => expect(reopens(server())).toHaveLength(1));
    await settled();
    await user.click(await screen.findByTestId('card-stop'));
    await waitFor(() =>
      expect(
        server()
          .events()
          .filter((e) => e.type === 'stop'),
      ).toHaveLength(2),
    );
    const second = server().events().at(-1);
    await waitFor(() => expect(server().entries[0]?.timing?.terminal_id).toBe(second?.id));
    const [older, newer] = await screen.findAllByRole('button', { name: 'Resume' });
    if (!older || !newer) throw new Error('two stop toasts, each with its Resume');

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(1);
    expect(reopens(server())[0]?.target).toBe(first?.id);

    await user.click(newer);
    await waitFor(() => expect(reopens(server())).toHaveLength(2), { timeout: 4000 });
    expect(reopens(server())[1]?.target).toBe(second?.id);
  });
  it('an older toast whose stop was resumed and stopped again, the re-stop still queued, does nothing', async () => {
    h = renderRunApp('/t/morning/record', lapTopic(), withGetEntry);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const first = server().events()[1];
    await settled();
    await user.click(await screen.findByTestId('run-reopen'));
    await waitFor(() => expect(reopens(server())).toHaveLength(1));
    await settled();
    // The re-stop doesn't reach the server: the entry still ends with the first stop.
    server().override = (body) =>
      body.type === 'stop' ? new Response('{}', { status: 503 }) : undefined;
    await user.click(await screen.findByTestId('card-stop'));
    const [older] = await screen.findAllByRole('button', { name: 'Resume' });
    if (!older) throw new Error('the first stop’s toast');
    expect(server().entries[0]?.timing?.terminal_id).toBe(first?.id);

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(1);
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
