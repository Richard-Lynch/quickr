/**
 * Editing a timed entry (timers.md §3.8, §11.5): captured_at is never sent (it is the run's
 * end), and Edit times sends `timing` with `expected_revision`, showing the server's refusals
 * on the fields they name.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { fireEvent, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { EntryOut, TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { toLocalSeconds } from '../../components/runs/timingEdit';
import { ToastProvider } from '../../components/ui/Toast';
import { parseInstant } from '../../lib/runs/instant';
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
function stubServer(e: EntryOut, patchReply?: (body: unknown) => Response, v = version) {
  const patches: unknown[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: Request) => {
      const path = new URL(input.url).pathname;
      if (path.endsWith(`/entries/${ENTRY_ID}`) && input.method === 'PATCH') {
        const body: unknown = JSON.parse(await input.text());
        patches.push(body);
        return patchReply ? patchReply(body) : json(200, { ...e, revision: 2 });
      }
      if (path.endsWith(`/entries/${ENTRY_ID}`)) return json(200, e);
      if (path.endsWith('/versions')) return json(200, [v]);
      return json(404, { code: 'not_found', detail: 'not found', errors: [] });
    }),
  );
  return patches;
}

function renderPage() {
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
  return userEvent.setup();
}

/** Types a note and saves; whether the Captured-at field was read-only. */
async function saveNotes(): Promise<boolean> {
  const user = renderPage();
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

const stepped: TopicVersionOut = {
  ...version,
  timer: {
    steps: [
      { key: 'wash', label: 'Wash' },
      { key: 'dry', label: 'Dry' },
    ],
  },
};

/** Wash 8:00:00–8:02:00, Dry to 8:05:00.500, no pauses. */
const steppedTiming: NonNullable<EntryOut['timing']> = {
  started_at: '2026-10-23T08:00:00Z',
  ended_at: '2026-10-23T08:05:00.500Z',
  active_ms: 300_500,
  paused_ms: 0,
  complete: true,
  edited: false,
  segments: [
    {
      kind: 'step',
      step: 'wash',
      label: 'Wash',
      started_at: '2026-10-23T08:00:00Z',
      ended_at: '2026-10-23T08:02:00Z',
      active_ms: 120_000,
      paused_ms: 0,
    },
    {
      kind: 'step',
      step: 'dry',
      label: 'Dry',
      started_at: '2026-10-23T08:02:00Z',
      ended_at: '2026-10-23T08:05:00.500Z',
      active_ms: 180_500,
      paused_ms: 0,
    },
  ],
  skipped: [],
  pauses: [],
};

const localAt = (iso: string) => toLocalSeconds(parseInstant(iso));

async function openEditor(user: ReturnType<typeof userEvent.setup>) {
  const section = await screen.findByRole('region', { name: 'Timing' });
  expect(within(section).getByTestId('run-total').textContent).toBe('5:00');
  await user.click(within(section).getByRole('button', { name: 'Edit times' }));
  return screen.getByRole('form', { name: 'Edit times' });
}

describe('EntryEditPage Edit times', () => {
  it('sends the edited timing with expected_revision and no captured_at', async () => {
    const patches = stubServer({ ...entry(steppedTiming), revision: 4 }, undefined, stepped);
    const user = renderPage();
    const form = await openEditor(user);
    fireEvent.change(within(form).getByLabelText('Segment 1 ended'), {
      target: { value: localAt('2026-10-23T08:03:00Z') },
    });
    expect(within(form).getByTestId('edited-total').textContent).toContain('5:00');
    await user.click(within(form).getByLabelText('Segment 2'));
    await user.selectOptions(within(form).getByLabelText('Segment 2'), 'Lap');
    await user.click(within(form).getByLabelText('Skipped Dry'));
    await user.click(within(form).getByRole('button', { name: 'Save times' }));
    expect(await screen.findByText('Times updated')).toBeInTheDocument();
    expect(patches).toEqual([
      {
        expected_revision: 4,
        timing: {
          started_at: '2026-10-23T08:00:00Z',
          segments: [
            { kind: 'step', step: 'wash', ended_at: '2026-10-23T08:03:00Z' },
            // Untouched: the exact millisecond, not the second the field shows.
            { kind: 'lap', step: null, ended_at: '2026-10-23T08:05:00.500000Z' },
          ],
          skipped: ['dry'],
          pauses: [],
        },
      },
    ]);
  });

  it('refuses a segment that ends before it starts, without a request', async () => {
    const patches = stubServer(entry(steppedTiming), undefined, stepped);
    const user = renderPage();
    const form = await openEditor(user);
    fireEvent.change(within(form).getByLabelText('Segment 2 ended'), {
      target: { value: localAt('2026-10-23T08:01:00Z') },
    });
    await user.click(within(form).getByRole('button', { name: 'Save times' }));
    expect(within(form).getByText('Before the segment’s start')).toBeInTheDocument();
    expect(patches).toHaveLength(0);
  });

  it('shows the server’s 422 on the field it names, until that field is edited', async () => {
    const patches = stubServer(
      entry(steppedTiming),
      () =>
        json(422, {
          code: 'invalid_request',
          detail: 'invalid timing: pause overlaps the next one',
          errors: [
            { loc: ['body', 'timing', 'pauses', 0, 'end'], message: 'overlaps the next pause' },
          ],
        }),
      stepped,
    );
    const user = renderPage();
    const form = await openEditor(user);
    await user.click(within(form).getByRole('button', { name: 'Add pause' }));
    await user.click(within(form).getByRole('button', { name: 'Save times' }));
    expect(await within(form).findByText('Overlaps the next pause')).toBeInTheDocument();
    expect(patches).toHaveLength(1);
    expect(screen.getByRole('form', { name: 'Edit times' })).toBeInTheDocument();
    fireEvent.change(within(form).getByLabelText('Pause 1 ended'), {
      target: { value: localAt('2026-10-23T08:04:00Z') },
    });
    expect(within(form).queryByText('Overlaps the next pause')).toBeNull();
  });
});
