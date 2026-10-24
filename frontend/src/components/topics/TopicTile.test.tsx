/** A single topic's tile (no questions): one tap logs it, with the Undo toast and no form. */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type { TopicSummary } from '../../client';
import { outbox } from '../../lib/outbox/client';
import type { EntryCreatePayload } from '../../lib/outbox/kinds';
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
