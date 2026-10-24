/**
 * The Overview's Timing section (timers.md §9, §11.5), rendered from the server's own
 * answers: `shared/fixtures/api/getTopicTiming.json` and a `timing-stats-vectors.json` case.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, waitFor, within } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import timingRaw from '../../../../shared/fixtures/api/getTopicTiming.json?raw';
import untimedRaw from '../../../../shared/fixtures/api/getTopicTiming.untimed.json?raw';
import statsRaw from '../../../../shared/fixtures/api/getTopicStats.json?raw';
import vectorsRaw from '../../../../shared/fixtures/timing-stats-vectors.json?raw';
import type { TopicDetail, TopicStats, TopicTiming } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../../components/ui/Toast';
import { OverviewPage } from './OverviewPage';

const timingFixture = (JSON.parse(timingRaw) as { body: TopicTiming }).body;
const untimedFixture = (JSON.parse(untimedRaw) as { body: TopicTiming }).body;
const statsFixture = (JSON.parse(statsRaw) as { body: TopicStats }).body;
const vectors = JSON.parse(vectorsRaw) as { cases: { name: string; expected: TopicTiming }[] };
const renamed = vectors.cases.find((c) => c.name === 'renamed-and-removed-steps')?.expected;

const topic: TopicDetail = {
  id: '6f1c0000-0000-4000-8000-000000000001',
  slug: 'routine',
  name: 'Routine',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 0,
  entry_count: 4,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  questions: [],
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function stubServer(timing: TopicTiming) {
  const paths: string[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn((input: Request) => {
      const path = new URL(input.url).pathname;
      paths.push(path);
      if (path.endsWith('/timing')) return Promise.resolve(json(200, timing));
      // The question cards aren't under test: the stats with no questions.
      if (path.endsWith('/stats'))
        return Promise.resolve(json(200, { ...statsFixture, entry_count: 4, questions: [] }));
      return Promise.resolve(json(404, { code: 'not_found', detail: 'not found', errors: [] }));
    }),
  );
  return paths;
}

function renderPage() {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [{ index: true, element: <OverviewPage /> }],
      },
    ],
    { initialEntries: ['/t/routine?range=all'] },
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
}

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('OverviewPage Timing', () => {
  it('renders best, median and per-step bars from the getTopicTiming fixture', async () => {
    const paths = stubServer(timingFixture);
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    expect(within(section).getByTestId('timing-median').textContent).toBe('5:00');
    expect(within(section).getByTestId('timing-best').textContent).toBe('5:00');
    expect(within(section).getByTestId('complete-note').textContent).toContain('1 of 1 run');
    const pour = within(section).getByTestId('step-pour');
    expect(pour.textContent).toContain('Pour');
    expect(pour.textContent).toContain('median 2:00 · best 2:00');
    expect(within(section).getByTestId('step-drink').textContent).toContain('median 3:00');
    expect(within(section).getByText('Paused (median)').nextSibling?.textContent).toBe('0:30');
    expect(within(section).getByRole('img', { name: 'Run time: average per week' })).toBeTruthy();
    expect(within(section).getByRole('img', { name: 'Steps: time per week' })).toBeTruthy();
    expect(paths.some((p) => p.endsWith('/topics/routine/timing'))).toBe(true);
  });

  it('counts complete runs only for best and median, and marks retired steps', async () => {
    if (!renamed) throw new Error('vector case missing');
    stubServer(renamed);
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    expect(within(section).getByTestId('complete-note').textContent).toContain('3 of 4 runs');
    const steps = within(section).getByRole('list', { name: 'Steps' });
    expect(
      within(steps)
        .getAllByRole('listitem')
        .map((li) => li.dataset.testid),
    ).toEqual(renamed.steps.map((s) => `step-${s.key}`));
    expect(within(section).getByTestId('step-shower').textContent).toContain('Wash');
    expect(within(section).getByTestId('step-brekkie').textContent).toContain('skipped 1×');
    expect(within(within(section).getByTestId('step-ghost')).getByText('retired')).toBeTruthy();
  });

  it('shows no Timing section for an untimed topic', async () => {
    stubServer(untimedFixture);
    const real = globalThis.fetch;
    let answered = false;
    vi.stubGlobal('fetch', async (input: Request) => {
      const res = await real(input);
      if (new URL(input.url).pathname.endsWith('/timing')) answered = true;
      return res;
    });
    renderPage();
    expect(await screen.findByText('Entries')).toBeTruthy();
    await waitFor(() => {
      expect(answered).toBe(true);
    });
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.queryByRole('region', { name: 'Timing' })).toBeNull();
  });
});
