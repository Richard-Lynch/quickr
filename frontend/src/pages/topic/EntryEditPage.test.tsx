/** Editing a timed entry never sends captured_at: it is the run's end (timers.md §3.8). */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { EntryOut, TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../../components/ui/Toast';
import { EntryEditPage } from './EntryEditPage';

const ENTRY_ID = '6f1c0000-0000-4000-8000-0000000000e1';

const topic: TopicDetail = {
  id: '6f1c0000-0000-4000-8000-000000000001',
  slug: 'routine',
  name: 'Routine',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 0,
  entry_count: 1,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  questions: [],
};

const version: TopicVersionOut = {
  version: 1,
  questions: [],
  timer: { steps: [] },
  change_note: '',
  created_at: '2026-10-01T00:00:00Z',
  entry_count: 1,
};

const timing: EntryOut['timing'] = {
  started_at: '2026-10-23T08:00:00Z',
  ended_at: '2026-10-23T08:01:00Z',
  active_ms: 60_000,
  paused_ms: 0,
  complete: true,
  edited: false,
  segments: [
    {
      kind: 'lap',
      step: null,
      label: 'Lap 1',
      started_at: '2026-10-23T08:00:00Z',
      ended_at: '2026-10-23T08:01:00Z',
      active_ms: 60_000,
      paused_ms: 0,
    },
  ],
  skipped: [],
  pauses: [],
};

function entry(t: EntryOut['timing']): EntryOut {
  return {
    id: ENTRY_ID,
    topic_id: topic.id,
    version: 1,
    revision: 1,
    source: 'phone',
    channel: 'ui',
    captured_at: '2026-10-23T08:01:00Z',
    created_at: '2026-10-23T08:01:00Z',
    updated_at: '2026-10-23T08:01:00Z',
    notes: '',
    meta: {},
    answers: [],
    timing: t,
  };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

/** The server: the entry given, its version, and a PATCH that echoes the entry back. */
function stubServer(e: EntryOut) {
  const patches: unknown[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: Request) => {
      const path = new URL(input.url).pathname;
      if (path.endsWith(`/entries/${ENTRY_ID}`) && input.method === 'PATCH') {
        patches.push(JSON.parse(await input.text()));
        return json(200, { ...e, revision: 2 });
      }
      if (path.endsWith(`/entries/${ENTRY_ID}`)) return json(200, e);
      if (path.endsWith('/versions')) return json(200, [version]);
      return json(404, { code: 'not_found', detail: 'not found', errors: [] });
    }),
  );
  return patches;
}

/** Types a note and saves; whether the Captured-at field was read-only. */
async function saveNotes(): Promise<boolean> {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [
          { path: 'entries/:entryId', element: <EntryEditPage /> },
          { path: 'entries', element: <p>entries page</p> },
        ],
      },
    ],
    { initialEntries: [`/t/routine/entries/${ENTRY_ID}`] },
  );
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>,
  );
  const user = userEvent.setup();
  await user.type(await screen.findByLabelText(/notes/i), 'Slow morning');
  const readOnly = screen.getByLabelText<HTMLInputElement>(/captured at/i).readOnly;
  await user.click(screen.getByRole('button', { name: /save changes/i }));
  await screen.findByText('entries page');
  return readOnly;
}

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('EntryEditPage captured_at', () => {
  it('is read-only and left out of the PATCH for a timed entry', async () => {
    const patches = stubServer(entry(timing));
    expect(await saveNotes()).toBe(true);
    expect(patches).toHaveLength(1);
    expect(patches[0]).toMatchObject({ notes: 'Slow morning' });
    expect(patches[0]).not.toHaveProperty('captured_at');
  });

  it('is sent for an untimed entry', async () => {
    const patches = stubServer(entry(null));
    expect(await saveNotes()).toBe(false);
    expect(patches[0]).toHaveProperty('captured_at');
  });
});
