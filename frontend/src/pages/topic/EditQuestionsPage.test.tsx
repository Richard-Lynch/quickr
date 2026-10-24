/** Publishing from the question editor sends the edited timer (timers.md §2.1, §11.5). */
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
  await user.click(await screen.findByRole('button', { name: /review changes/i }));
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

  it('shows an error and no editor when the base version isn’t in the list', async () => {
    const requests = stubServer([version(1, timer)]);
    renderPage();
    expect(await screen.findByText(/Version 2 wasn’t found/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /review changes/i })).toBeNull();
    expect(publishes(requests)).toHaveLength(0);
  });

  it('renames, adds and reorders steps; a published step keeps its key', async () => {
    const requests = stubServer([version(2, timer)]);
    const user = renderPage();
    const name = await screen.findByLabelText('Step 1 name');
    await user.clear(name);
    await user.type(name, 'Unload');
    expect(screen.getAllByTestId('step-key').map((k) => k.textContent)).toEqual(['load']);
    await user.click(screen.getByRole('button', { name: 'Add step' }));
    await user.type(screen.getByLabelText('Step 2 name'), 'Wipe down');
    expect(screen.getAllByTestId('step-key').map((k) => k.textContent)).toEqual([
      'load',
      'wipe_down',
    ]);
    await user.click(screen.getByRole('button', { name: 'Move up: Wipe down (step 2)' }));
    await user.click(screen.getByRole('button', { name: /review changes/i }));
    expect(await screen.findByText('Step renamed: Load → Unload')).toBeInTheDocument();
    expect(screen.getByText('Step added: Wipe down')).toBeInTheDocument();
    // The report covers questions only, and none changed.
    expect(screen.getByText('No question changes.')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /publish v3/i }));
    await screen.findByText('versions page');
    const edited = {
      steps: [
        { key: 'wipe_down', label: 'Wipe down' },
        { key: 'load', label: 'Unload' },
      ],
    };
    const check = requests.find((r) => r.path.endsWith('/versions/check'));
    expect(check?.body).toMatchObject({ timer: edited });
    expect(publishes(requests)[0]?.body).toMatchObject({ timer: edited });
  });

  it('turns timing on as a stopwatch, and off again', async () => {
    const requests = stubServer([version(2, null)]);
    const user = renderPage();
    await user.click(await screen.findByRole('switch', { name: 'Timed' }));
    expect(screen.getByTestId('no-steps')).toBeInTheDocument();
    await reviewAndPublish(user);
    await screen.findByText('versions page');
    expect(publishes(requests)[0]?.body).toMatchObject({ timer: { steps: [] } });
  });

  it('switching Timed off sends null, and back on restores the steps', async () => {
    const requests = stubServer([version(2, timer)]);
    const user = renderPage();
    const sw = await screen.findByRole('switch', { name: 'Timed' });
    await user.click(sw);
    expect(screen.queryByLabelText('Step 1 name')).toBeNull();
    await user.click(sw);
    expect(screen.getByLabelText<HTMLInputElement>('Step 1 name').value).toBe('Load');
    await user.click(sw);
    await reviewAndPublish(user);
    await screen.findByText('versions page');
    expect(publishes(requests)[0]?.body).toMatchObject({ timer: null });
  });

  it('a blank step blocks the review with an inline error', async () => {
    const requests = stubServer([version(2, timer)]);
    const user = renderPage();
    await user.click(await screen.findByRole('button', { name: 'Add step' }));
    await user.click(screen.getByRole('button', { name: /review changes/i }));
    expect(await screen.findByText('Required')).toBeInTheDocument();
    expect(requests.some((r) => r.path.endsWith('/versions/check'))).toBe(false);
  });

  it('a new step never takes a retired step’s key, unless it is that step', async () => {
    const old = { steps: [{ key: 'prep', label: 'Prep work' }, ...timer.steps] };
    stubServer([version(2, timer), version(1, old)]);
    const user = renderPage();
    await user.click(await screen.findByRole('button', { name: 'Add step' }));
    await user.type(screen.getByLabelText('Step 2 name'), 'Prep');
    expect(screen.getAllByTestId('step-key').map((k) => k.textContent)).toEqual(['load', 'prep_2']);
    await user.clear(screen.getByLabelText('Step 2 name'));
    await user.type(screen.getByLabelText('Step 2 name'), 'prep work');
    expect(screen.getAllByTestId('step-key').map((k) => k.textContent)).toEqual(['load', 'prep']);
  });

  it('names each step’s buttons and moves focus after a remove', async () => {
    stubServer([version(2, timer)]);
    const user = renderPage();
    await user.click(await screen.findByRole('button', { name: 'Add step' }));
    await user.type(screen.getByLabelText('Step 2 name'), 'Dry');
    await user.click(screen.getByRole('button', { name: 'Remove Load (step 1)' }));
    await waitFor(() => {
      expect(screen.getByLabelText('Step 1 name')).toHaveFocus();
    });
    expect(screen.getByLabelText<HTMLInputElement>('Step 1 name').value).toBe('Dry');
    await user.click(screen.getByRole('button', { name: 'Remove Dry (step 1)' }));
    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Add step' })).toHaveFocus();
    });
  });

  it('a step error is announced on its input', async () => {
    stubServer([version(2, timer)]);
    const user = renderPage();
    await user.click(await screen.findByRole('button', { name: 'Add step' }));
    await user.click(screen.getByRole('button', { name: /review changes/i }));
    const input = await screen.findByLabelText('Step 2 name');
    await waitFor(() => {
      expect(input).toHaveAttribute('aria-invalid', 'true');
    });
    expect(input).toHaveAccessibleDescription('Required');
  });
});
