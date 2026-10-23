/** Publishing from the question editor keeps the base version's timer (timers.md §2.1). */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../../components/ui/Toast';
import { EditQuestionsPage } from './EditQuestionsPage';

const question = { type: 'int' as const, key: 'loads', label: 'Loads', required: true };

const topic: TopicDetail = {
  id: '6f1c0000-0000-4000-8000-000000000001',
  slug: 'dishes',
  name: 'Dishes',
  description: '',
  status: 'active',
  current_version: 2,
  revision: 2,
  question_count: 1,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  questions: [
    { ...question, help_text: null, min: null, max: null, unit: null },
  ] as TopicDetail['questions'],
};

const timer = { steps: [{ key: 'load', label: 'Load' }] };

function version(n: number, t: TopicVersionOut['timer']): TopicVersionOut {
  return {
    version: n,
    questions: topic.questions,
    timer: t,
    change_note: '',
    created_at: '2026-10-01T00:00:00Z',
    entry_count: 0,
  };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

/** The server: the version list given, a check that passes, and a publish that succeeds. */
function stubServer(versions: TopicVersionOut[]) {
  const requests: { method: string; path: string; body: unknown }[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: Request) => {
      const path = new URL(input.url).pathname;
      const text = await input.text();
      requests.push({ method: input.method, path, body: text ? JSON.parse(text) : undefined });
      if (path.endsWith('/versions/check')) {
        return json(200, { ok: true, next_version: 3, issues: [], changes: [] });
      }
      if (path.endsWith('/versions') && input.method === 'GET') return json(200, versions);
      if (path.endsWith('/versions')) return json(201, { ...topic, current_version: 3 });
      return json(404, { code: 'not_found', detail: 'not found', errors: [] });
    }),
  );
  return requests;
}

function renderPage() {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [
          { path: 'edit', element: <EditQuestionsPage /> },
          { path: 'versions', element: <p>versions page</p> },
        ],
      },
    ],
    { initialEntries: ['/t/dishes/edit'] },
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

async function reviewAndPublish(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole('button', { name: /review changes/i }));
  await user.click(await screen.findByRole('button', { name: /publish v3/i }));
}

const publishes = (requests: { method: string; path: string; body: unknown }[]) =>
  requests.filter((r) => r.method === 'POST' && r.path.endsWith('/versions'));

// The app's same-origin base URL has no origin to resolve against here.
beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('EditQuestionsPage publish', () => {
  it('sends the base version’s timer', async () => {
    const requests = stubServer([version(2, timer), version(1, null)]);
    const user = renderPage();
    await reviewAndPublish(user);
    await screen.findByText('versions page');
    const sent = publishes(requests);
    expect(sent).toHaveLength(1);
    expect(sent[0]?.body).toMatchObject({ base_version: 2, timer });
  });

  it('sends a null timer for an untimed base version', async () => {
    const requests = stubServer([version(2, null), version(1, timer)]);
    const user = renderPage();
    await reviewAndPublish(user);
    await screen.findByText('versions page');
    expect(publishes(requests)[0]?.body).toMatchObject({ timer: null });
  });

  it('sends nothing when the base version isn’t in the list', async () => {
    const requests = stubServer([version(1, timer)]);
    const user = renderPage();
    await reviewAndPublish(user);
    await waitFor(() => {
      expect(screen.getByText(/Version 2 wasn’t found/)).toBeInTheDocument();
    });
    expect(publishes(requests)).toHaveLength(0);
  });
});
