/** A single topic's tile (no questions): one tap logs it, with the Undo toast and no form. */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { TopicSummary } from '../../client';
import { outbox } from '../../lib/outbox/client';
import type { EntryCreatePayload } from '../../lib/outbox/kinds';
import { lapTopic, reopens, seedStopped, STOP_ID } from '../../test/resume';
import { renderRunApp, type Harness } from '../../test/runUi';
import { REOPEN_WINDOW_MS } from '../runs/model';
import { ToastProvider } from '../ui/Toast';
import { TopicTile } from './TopicTile';

const vitamins: TopicSummary = {
  id: '6f1c0000-0000-4000-8000-000000000009',
  slug: 'vitamins',
  name: 'Vitamins',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 0,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: null,
};

function renderTile(topic: TopicSummary) {
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ToastProvider>
        <MemoryRouter initialEntries={['/']}>
          <Routes>
            <Route path="/" element={<TopicTile topic={topic} now={new Date()} />} />
            <Route path="/t/:slug/*" element={<p>Topic page</p>} />
          </Routes>
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

afterEach(async () => {
  vi.unstubAllGlobals();
  await outbox.clear();
});

describe('a single topic tile', () => {
  it.each([['the tile'], ['its Log button']])(
    'logs it with one tap on %s: an entry with no answers, the Undo toast, no form',
    async (where) => {
      // Offline: the entry waits in the outbox (what was logged is what matters here).
      vi.stubGlobal(
        'fetch',
        vi.fn(() => Promise.reject(new TypeError('offline'))),
      );
      renderTile(vitamins);
      await userEvent.click(
        where === 'the tile'
          ? await screen.findByTestId('tile-log')
          : await screen.findByRole('button', { name: 'Log Vitamins now' }),
      );
      await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Logged Vitamins'));
      expect(screen.getByRole('button', { name: 'Undo' })).toBeInTheDocument();
      expect(screen.queryByText('Topic page')).toBeNull();
      const items = await outbox.list();
      expect(items).toHaveLength(1);
      expect((items[0]?.payload as EntryCreatePayload).body.answers).toEqual({});
    },
  );

  it('offers screen readers one Log control, not two', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.reject(new TypeError('offline'))),
    );
    renderTile(vitamins);
    await screen.findByRole('button', { name: 'Log Vitamins now' });
    expect(screen.getAllByRole('button', { name: /^Log Vitamins/ })).toHaveLength(1);
  });

  it('still opens the topic from its name', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.reject(new TypeError('offline'))),
    );
    renderTile(vitamins);
    await screen.findByRole('button', { name: 'Log Vitamins now' });
    await userEvent.click(screen.getByRole('link', { name: 'Vitamins' }));
    expect(screen.getByText('Topic page')).toBeInTheDocument();
    expect(await outbox.list()).toEqual([]);
  });

  it('a topic with questions keeps its Log link to the record screen', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.reject(new TypeError('offline'))),
    );
    renderTile({ ...vitamins, question_count: 2 });
    expect(await screen.findByRole('link', { name: 'Log Vitamins' })).toHaveAttribute(
      'href',
      '/t/vitamins/record',
    );
    expect(screen.queryByRole('button', { name: 'Log Vitamins now' })).toBeNull();
  });

  it('waits, neutral, until it knows whether the topic is timed (no one-tap log yet)', async () => {
    // The versions never come: the action stays a placeholder.
    vi.stubGlobal(
      'fetch',
      vi.fn(() => new Promise<Response>(() => undefined)),
    );
    renderTile(vitamins);
    expect(await screen.findByTestId('tile-action-pending')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Log Vitamins now' })).toBeNull();
    expect(screen.queryByTestId('tile-log')).toBeNull();
  });
});

describe('an idle timed tile’s Resume (active-surfaces.md §3.3, §6.3)', () => {
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
  const tile = () => screen.getByRole('article', { name: 'Morning' });

  it('within 15 minutes: "Resume · 1:44" under the meta line, aimed at the entry’s terminal stop', async () => {
    h = renderRunApp('/', lapTopic(), (s) => seedStopped(s, 114_000, 10_000));
    const user = userEvent.setup();
    const resume = await screen.findByTestId('run-reopen');
    expect(tile()).toContainElement(resume);
    expect(resume).toHaveTextContent('Resume · 1:44');
    expect(resume).toHaveAccessibleName('Resume the last run of Morning');
    // Start keeps its place: Resume is the quick slot's, not the action block's.
    expect(within(tile()).getByRole('button', { name: 'Start Morning' })).toBeInTheDocument();

    await user.click(resume);
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(STOP_ID);
    expect(server().entries[0]?.timing?.terminal_id).toBe(STOP_ID);
    // The tile is the active card now.
    expect(await screen.findByTestId('active-card')).toBeInTheDocument();
    expect(screen.queryByTestId('run-reopen')).toBeNull();
  });

  it('past the window: no Resume, Start only', async () => {
    h = renderRunApp('/', lapTopic(), (s) =>
      seedStopped(s, REOPEN_WINDOW_MS + 120_000, REOPEN_WINDOW_MS + 1_000),
    );
    expect(await screen.findByRole('button', { name: 'Start Morning' })).toBeInTheDocument();
    await waitFor(() =>
      expect(server().requests.some((r) => r.path.endsWith('/entries'))).toBe(true),
    );
    expect(screen.queryByTestId('run-reopen')).toBeNull();
  });

  it('goes when the window ends', async () => {
    // Stopped 14:59 ago: offered now, gone a couple of seconds later (the offer ticks).
    h = renderRunApp('/', lapTopic(), (s) =>
      seedStopped(s, REOPEN_WINDOW_MS + 60_000, REOPEN_WINDOW_MS - 1_000),
    );
    expect(await screen.findByTestId('run-reopen')).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByTestId('run-reopen')).toBeNull(), {
      timeout: 4000,
    });
    expect(screen.getByRole('button', { name: 'Start Morning' })).toBeInTheDocument();
  });

  it('a just-stopped run’s tile offers it from the optimistic entry, before the server’s', async () => {
    h = renderRunApp('/', lapTopic());
    const user = userEvent.setup();
    let hold = true;
    server().override = (body) =>
      body.type === 'stop' && hold ? new Response('{}', { status: 503 }) : undefined;
    await user.click(await screen.findByRole('button', { name: 'Start Morning' }));
    await user.click(await screen.findByTestId('card-stop'));
    // The stop is queued (503): its optimistic entry makes the offer, no server entry yet.
    const resume = await screen.findByTestId('run-reopen');
    expect(server().entries).toHaveLength(0);
    const stop = (await outbox.list()).find(
      (i) => (i.payload as { event: { type: string } }).event.type === 'stop',
    );
    hold = false;
    await user.click(resume);
    await outbox.retry(stop?.id ?? '');
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
  });
});
