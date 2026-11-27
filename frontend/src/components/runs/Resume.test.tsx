/**
 * Resume on the record page (active-surfaces.md §2.4, §6.3; timers2.md §5.3): "Resume · {total}"
 * under Start while the latest stop is resumable (OQ-1's 15 minutes), the stop toast's Resume,
 * both aimed at the entry's `timing.terminal_id`; the "Resuming…" header without controls
 * until the reopen's ack; and Undo resume…, the reopened run's discard.
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import { runsQueryKey } from '../../api/runs';
import { outbox } from '../../lib/outbox/client';
import { lapTopic, reopens, seedStopped, STOP_ID, WINDOW_MS } from '../../test/resume';
import type { FakeRunServer } from '../../test/fakeRunServer';
import { renderRunApp, RUN_ID, type Harness } from '../../test/runUi';
import { RUN_TAP_COOLDOWN_MS } from './useRunActions';

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
  /** No queued item and no fetch in flight. */
  const settled = async () => {
    await waitFor(async () => expect(await outbox.list()).toHaveLength(0));
    await waitFor(() => expect(h?.qc.isFetching()).toBe(0));
  };

  it('with the latest entry not cached, fetches it and reopens that stop', async () => {
    h = renderRunApp('/t/morning/record', lapTopic());
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
    const lists = () =>
      server().requests.filter((r) => r.method === 'GET' && r.path.endsWith('/entries')).length;
    const before = lists();
    await user.click(resume);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
    // Fetched at the tap: the latest entry, now.
    expect(lists()).toBeGreaterThan(before);
  });

  it('an older toast whose stop was resumed and stopped again since does nothing, and says so', async () => {
    h = renderRunApp('/t/morning/record', lapTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const first = server().events()[1];
    // On the topics page now: Resume from the tile, then Stop on the card (a second toast).
    // Each tap waits for the sync to settle: the tile re-renders its offer and card as the
    // acks and refetches land, and a click on a replaced button reaches nothing.
    await settled();
    const firstEntry = structuredClone(server().entries[0]);
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
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Resume' })).toHaveLength(2));
    const [older, newer] = screen.getAllByRole('button', { name: 'Resume' });
    if (!older || !newer) throw new Error('two stop toasts, each with its Resume');
    // A stale latest-entry cache that still ends with the first stop: the entry is fetched
    // at the tap.
    await settled();
    h.qc.setQueriesData<{ items: unknown[] }>({ queryKey: [{ _id: 'listEntries' }] }, (d) =>
      d ? { ...d, items: [firstEntry] } : d,
    );

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(1);
    expect(reopens(server())[0]?.target).toBe(first?.id);

    await user.click(newer);
    await waitFor(() => expect(reopens(server())).toHaveLength(2), { timeout: 4000 });
    expect(reopens(server())[1]?.target).toBe(second?.id);
  });
  it('offline, an older toast with a stale cache does nothing while the run row has the re-stop', async () => {
    let offline = false;
    h = renderRunApp('/t/morning/record', lapTopic(), (s) => {
      const base = s.fetch;
      s.fetch = (input, init) =>
        offline ? Promise.reject(new TypeError('Failed to fetch')) : base(input, init);
    });
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    await settled();
    const firstEntry = structuredClone(server().entries[0]);
    await user.click(await screen.findByTestId('run-reopen'));
    await waitFor(() => expect(reopens(server())).toHaveLength(1));
    await settled();
    await user.click(await screen.findByTestId('card-stop'));
    const second = await waitFor(() => {
      const stops = server()
        .events()
        .filter((e) => e.type === 'stop');
      expect(stops).toHaveLength(2);
      return stops[1];
    });
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Resume' })).toHaveLength(2));
    const [older] = screen.getAllByRole('button', { name: 'Resume' });
    if (!older) throw new Error('the first stop’s toast');
    await settled();
    // Offline now: the cache still ends with the first stop, the run row with the re-stop.
    offline = true;
    h.qc.setQueriesData<{ items: unknown[] }>({ queryKey: [{ _id: 'listEntries' }] }, (d) =>
      d ? { ...d, items: [firstEntry] } : d,
    );
    const runId = firstEntry?.id ?? '';
    h.qc.setQueryData(runsQueryKey(), [server().runOut(runId)]);
    expect(server().runOut(runId).state.terminal_id).toBe(second?.id);

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(await outbox.list()).toHaveLength(0);
  });

  /** Hold the next `listEntries` request (the toast's refresh) until `release`, or forever. */
  const holdable = () => {
    const ctl: { next: boolean; release: () => void } = {
      next: false,
      release: () => {
        throw new Error('nothing held');
      },
    };
    const setup = (s: FakeRunServer) => {
      const base = s.fetch;
      s.fetch = (input, init) => {
        const url = input instanceof Request ? input.url : String(input);
        if (!ctl.next || !new URL(url, 'https://q.test').pathname.endsWith('/entries'))
          return base(input, init);
        ctl.next = false;
        return new Promise((resolve) => {
          ctl.release = () => {
            resolve(base(input, init));
          };
        });
      };
    };
    return { ctl, setup };
  };

  it('a refresh that never answers: after the tap timeout, the cached entry decides', async () => {
    const { ctl, setup } = holdable();
    h = renderRunApp('/t/morning/record', lapTopic(), setup);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const stop = server().events()[1];
    const resume = await screen.findByRole('button', { name: 'Resume' });
    await settled();
    ctl.next = true;
    await user.click(resume);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 5000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
  }, 10_000);

  it('a slow refresh, and the run resumed and stopped again meanwhile: the toast does nothing', async () => {
    const { ctl, setup } = holdable();
    h = renderRunApp('/t/morning/record', lapTopic(), setup);
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const older = await screen.findByRole('button', { name: 'Resume' });
    await settled();
    // The toast's refresh is held; meanwhile the tile resumes and the card stops again (the
    // re-stop stays queued).
    ctl.next = true;
    await user.click(older);
    await user.click(await screen.findByTestId('run-reopen'));
    await waitFor(() => expect(reopens(server())).toHaveLength(1));
    // The reopen is acked; the toast's refresh is still held (no `settled()`: that waits for it).
    // Before T2-WIRE-F the tile's own latest-entry query took the hold instead.
    await waitFor(async () => expect(await outbox.list()).toHaveLength(0));
    server().override = (body) =>
      body.type === 'stop' ? new Response('{}', { status: 503 }) : undefined;
    await user.click(await screen.findByTestId('card-stop'));
    await waitFor(async () =>
      expect(
        (await outbox.list()).filter(
          (i) => (i.payload as { event: { type: string } }).event.type === 'stop',
        ),
      ).toHaveLength(1),
    );
    // Past the card's tap cooldown, so only the toast's own check can refuse.
    await new Promise((r) => setTimeout(r, RUN_TAP_COOLDOWN_MS + 50));
    ctl.release();
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(1);
    expect(
      (await outbox.list()).filter(
        (i) => (i.payload as { event: { type: string } }).event.type === 'reopen',
      ),
    ).toHaveLength(0);
  });

  it('a toast whose run is no longer the topic’s latest stop does nothing', async () => {
    h = renderRunApp('/t/morning/record', lapTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await user.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await waitFor(() => expect(server().entries).toHaveLength(1));
    const firstEntry = structuredClone(server().entries[0]);
    // Another run of the topic, started and stopped from the tile: a second toast.
    await settled();
    await user.click(await screen.findByRole('button', { name: 'Start Morning' }));
    await settled();
    await user.click(await screen.findByTestId('card-stop'));
    await waitFor(() => expect(server().entries).toHaveLength(2));
    const later = server().events().at(-1);
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Resume' })).toHaveLength(2));
    const [older, newer] = screen.getAllByRole('button', { name: 'Resume' });
    if (!older || !newer) throw new Error('two stop toasts, each with its Resume');
    await settled();
    // The later run has left the local view, and the latest-entry cache still has the first
    // run's entry: the tap fetches the latest entry.
    expect(h.qc.getQueryData<unknown[]>(runsQueryKey()) ?? []).toHaveLength(0);
    h.qc.setQueriesData<{ items: unknown[] }>({ queryKey: [{ _id: 'listEntries' }] }, (d) =>
      d ? { ...d, items: [firstEntry] } : d,
    );

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(0);

    await user.click(newer);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(later?.id);
  });

  it('an older toast whose stop was resumed and stopped again, the re-stop still queued, does nothing; the newer one resumes the re-stop', async () => {
    h = renderRunApp('/t/morning/record', lapTopic());
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
    await waitFor(() => expect(screen.getAllByRole('button', { name: 'Resume' })).toHaveLength(2));
    const [older, newer] = screen.getAllByRole('button', { name: 'Resume' });
    if (!older || !newer) throw new Error('two stop toasts, each with its Resume');
    expect(server().entries[0]?.timing?.terminal_id).toBe(first?.id);

    await user.click(older);
    expect(await screen.findByText('That run can’t be resumed now')).toBeInTheDocument();
    expect(reopens(server())).toHaveLength(1);

    // The newer toast's stop is the queued one: the run row is local, its terminal that stop.
    const queued = async (type: string) =>
      (await outbox.list()).filter(
        (i) => (i.payload as { event: { type: string } }).event.type === type,
      );
    const [restop] = await queued('stop');
    // Nor does it need the latest-entry cache: the row's own projection will do.
    h.qc.removeQueries({ queryKey: [{ _id: 'listEntries' }] });
    await user.click(newer);
    await waitFor(async () => expect(await queued('reopen')).toHaveLength(1));
    const [reopen] = await queued('reopen');
    expect((reopen?.payload as { event: { target: string } }).event.target).toBe(restop?.id);
    expect(screen.getAllByText('That run can’t be resumed now')).toHaveLength(1);
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
