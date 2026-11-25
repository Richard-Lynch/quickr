/**
 * The Overview's Timing section (timers.md §9, §11.5), rendered from the server's own
 * answers: `shared/fixtures/api/getTopicTiming.json` and a `timing-stats-vectors.json` case;
 * and its activity strip and numeric sparklines (content-display.md §4.2, §4.3) from
 * `listEntries.json` and `getQuestionSeries*.json`.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import timingRaw from '../../../../shared/fixtures/api/getTopicTiming.json?raw';
import untimedRaw from '../../../../shared/fixtures/api/getTopicTiming.untimed.json?raw';
import statsRaw from '../../../../shared/fixtures/api/getTopicStats.json?raw';
import entriesRaw from '../../../../shared/fixtures/api/listEntries.json?raw';
import seriesRaw from '../../../../shared/fixtures/api/getQuestionSeries.json?raw';
import enumSeriesRaw from '../../../../shared/fixtures/api/getQuestionSeries.enum.json?raw';
import vectorsRaw from '../../../../shared/fixtures/timing-stats-vectors.json?raw';
import type { EntryPage, QuestionSeries, TopicDetail, TopicStats, TopicTiming } from '../../client';
import { client } from '../../client/client.gen';
import { activityStrip, localDay, localMidnight } from '../../components/charts/timingModels';
import { ToastProvider } from '../../components/ui/Toast';
import { browserTimeZone } from '../../lib/dates';
import { OverviewPage } from './OverviewPage';

const timingFixture = (JSON.parse(timingRaw) as { body: TopicTiming }).body;
const untimedFixture = (JSON.parse(untimedRaw) as { body: TopicTiming }).body;
const statsFixture = (JSON.parse(statsRaw) as { body: TopicStats }).body;
const entriesFixture = (JSON.parse(entriesRaw) as { body: EntryPage }).body;
const seriesFixture = (JSON.parse(seriesRaw) as { body: QuestionSeries }).body;
const enumSeriesFixture = (JSON.parse(enumSeriesRaw) as { body: QuestionSeries }).body;
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
  timer: null,
  questions: [],
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const versionWith = (timer: { steps: { key: string; label: string }[] } | null) => ({
  version: 1,
  questions: [],
  timer,
  change_note: '',
  created_at: '2026-10-01T00:00:00Z',
  entry_count: 4,
});

function stubServer(
  timing: TopicTiming,
  timer: { steps: { key: string; label: string }[] } | null = null,
) {
  const paths: string[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn((input: Request) => {
      const path = new URL(input.url).pathname;
      paths.push(path);
      if (path.endsWith('/timing')) return Promise.resolve(json(200, timing));
      if (path.endsWith('/versions')) return Promise.resolve(json(200, [versionWith(timer)]));
      if (path.endsWith('/entries')) return Promise.resolve(json(200, entriesFixture));
      // The question cards aren't under test: the stats with no questions.
      if (path.endsWith('/stats'))
        return Promise.resolve(json(200, { ...statsFixture, entry_count: 4, questions: [] }));
      return Promise.resolve(json(404, { code: 'not_found', detail: 'not found', errors: [] }));
    }),
  );
  return paths;
}

function renderPage(range = 'all') {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [{ index: true, element: <OverviewPage /> }],
      },
    ],
    { initialEntries: [`/t/routine?range=${range}`] },
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

  it('a timed topic with no runs in range says so', async () => {
    stubServer(untimedFixture, { steps: [] });
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    expect(within(section).getByText(/No runs in this range/)).toBeInTheDocument();
  });

  it('best, median and mean are told apart', async () => {
    const spread: TopicTiming = {
      ...timingFixture,
      runs: 3,
      complete_runs: 3,
      total: { best_ms: 240_000, median_ms: 300_000, mean_ms: 320_000 },
    };
    stubServer(spread);
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    expect(within(section).getByTestId('timing-best').textContent).toBe('4:00');
    expect(within(section).getByTestId('timing-median').textContent).toBe('5:00');
    expect(within(section).getByTestId('timing-mean').textContent).toBe('5:20');
  });
});

/** The stats fixture's questions (two numeric, two enum, one str), their series and entries. */
function stubContent(
  entries: EntryPage = entriesFixture,
  { stats = statsFixture, seriesStatus = 200 }: { stats?: TopicStats; seriesStatus?: number } = {},
) {
  const requests: URL[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn((input: Request) => {
      const url = new URL(input.url);
      requests.push(url);
      const path = url.pathname;
      if (path.endsWith('/timing')) return Promise.resolve(json(200, untimedFixture));
      if (path.endsWith('/versions')) return Promise.resolve(json(200, [versionWith(null)]));
      if (path.endsWith('/entries')) return Promise.resolve(json(200, entries));
      if (path.endsWith('/stats')) return Promise.resolve(json(200, stats));
      const series = /\/questions\/([^/]+)\/series$/.exec(path);
      if (series && seriesStatus !== 200)
        return Promise.resolve(
          json(seriesStatus, { code: 'internal', detail: 'boom', errors: [] }),
        );
      if (series) {
        const key = series[1] ?? '';
        const q = statsFixture.questions.find((x) => x.key === key);
        const body =
          q?.type === 'int' || q?.type === 'double'
            ? { ...seriesFixture, key, type: q.type, bucket: url.searchParams.get('bucket') }
            : { ...enumSeriesFixture, key, bucket: url.searchParams.get('bucket') };
        return Promise.resolve(json(200, body));
      }
      return Promise.resolve(json(404, { code: 'not_found', detail: 'not found', errors: [] }));
    }),
  );
  return requests;
}

describe('OverviewPage activity strip', () => {
  beforeEach(() => {
    // The day after the fixture's last entry (2026-03-03); only Date is faked.
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-03-04T12:00:00Z'));
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('draws one cell per local day of the last 12 weeks from listEntries', async () => {
    const requests = stubContent();
    renderPage();
    const region = await screen.findByRole('region', { name: 'Activity' });
    const caption = await within(region).findByTestId('activity-caption');
    expect(caption.textContent).toBe('3 entries in the last 12 weeks');

    const tz = browserTimeZone();
    const today = localDay(Date.now(), tz);
    const expected = activityStrip(
      entriesFixture.items.map((e) => Date.parse(e.captured_at)),
      today,
      tz,
    );
    const cells = within(region).getAllByTestId('activity-cell');
    expect(cells.map((c) => [c.dataset.day, Number(c.dataset.count)])).toEqual(
      expected.cells.map((c) => [c.day, c.count]),
    );
    expect(cells[0]?.dataset.day).toBe(expected.firstDay);
    // The grid always has 84 slots; today is the last cell and is outlined.
    expect(within(region).getByRole('img').children).toHaveLength(84);
    expect(cells.at(-1)?.dataset.day).toBe(today);
    expect(cells.at(-1)?.className).toContain('outline-ink');

    // One query from the first cell's local midnight, newest first, 500 at most.
    const list = requests.filter((u) => u.pathname.endsWith('/topics/routine/entries'));
    expect(list).toHaveLength(1);
    expect(list[0]?.searchParams.get('captured_from')).toBe(
      new Date(localMidnight(expected.firstDay, tz)).toISOString(),
    );
    expect(list[0]?.searchParams.get('limit')).toBe('500');
    expect(list[0]?.searchParams.get('order')).toBe('-captured_at');
  });

  it('stays when the selected range is empty: it has its own 12 weeks', async () => {
    stubContent(entriesFixture, { stats: { ...statsFixture, entry_count: 0, questions: [] } });
    renderPage('7d');
    expect(await screen.findByText('Nothing in this range')).toBeInTheDocument();
    const region = await screen.findByRole('region', { name: 'Activity' });
    expect((await within(region).findByTestId('activity-caption')).textContent).toBe(
      '3 entries in the last 12 weeks',
    );
  });

  it('says it shows the last 500 entries when there are more', async () => {
    stubContent({ ...entriesFixture, total: 501, limit: 500 });
    renderPage();
    const region = await screen.findByRole('region', { name: 'Activity' });
    expect((await within(region).findByTestId('activity-caption')).textContent).toBe(
      'Showing the last 500 entries',
    );
  });
});

describe('OverviewPage sparklines', () => {
  it('draws one sparkline per numeric card, max and min as end labels', async () => {
    stubContent();
    renderPage();
    for (const key of ['glasses', 'hours']) {
      const spark = await screen.findByTestId(`sparkline-${key}`);
      const img = await within(spark).findByRole('img');
      expect(img.getAttribute('aria-label')).toMatch(/: trend, last 8\.25$/);
      const ends = spark.nextElementSibling;
      expect(ends?.querySelector('[data-testid="sparkline-max"]')?.textContent).toBe('8.25');
      expect(ends?.querySelector('[data-testid="sparkline-min"]')?.textContent).toBe('6');
    }
    expect(screen.queryByTestId('sparkline-mood')).toBeNull();
    expect(screen.queryByTestId('sparkline-note')).toBeNull();
  });

  it('says so when the series fails, rather than drawing an empty trend', async () => {
    stubContent(entriesFixture, { seriesStatus: 500 });
    renderPage();
    const spark = await screen.findByTestId('sparkline-glasses');
    expect(await within(spark).findByText('Trend unavailable')).toBeInTheDocument();
    expect(within(spark).queryByRole('img')).toBeNull();
  });

  it("stays on the range's default bucket when the charts change bucket", async () => {
    const requests = stubContent();
    renderPage('7d');
    await within(await screen.findByTestId('sparkline-glasses')).findByRole('img');
    const series = (bucket: string, key: string) =>
      requests.filter(
        (u) =>
          u.pathname.endsWith(`/questions/${key}/series`) &&
          u.searchParams.get('bucket') === bucket,
      ).length;
    // 7 days defaults to days: the sparkline shares the line chart's query.
    expect(series('day', 'glasses')).toBe(1);
    fireEvent.click(screen.getByRole('radio', { name: 'Week' }));
    await waitFor(() => {
      expect(series('week', 'glasses')).toBe(1);
    });
    expect(series('day', 'glasses')).toBe(1);
    expect(within(screen.getByTestId('sparkline-glasses')).getByRole('img')).toBeTruthy();
  });

  it('waits until the card is on screen when nothing else loaded its series', async () => {
    const observed: Element[] = [];
    let notify: ((entries: { isIntersecting: boolean }[]) => void)[] = [];
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        constructor(cb: (entries: { isIntersecting: boolean }[]) => void) {
          notify.push(cb);
        }
        observe(el: Element) {
          observed.push(el);
        }
        disconnect() {
          notify = [];
        }
      },
    );
    const requests = stubContent();
    renderPage('7d');
    // Switch the charts to weeks before anything is on screen: only the sparklines want days.
    fireEvent.click(await screen.findByRole('radio', { name: 'Week' }));
    const spark = await screen.findByTestId('sparkline-glasses');
    expect(observed).toContain(spark);
    const days = () =>
      requests.filter(
        (u) => u.pathname.endsWith('/series') && u.searchParams.get('bucket') === 'day',
      ).length;
    await waitFor(() => {
      expect(requests.some((u) => u.searchParams.get('bucket') === 'week')).toBe(true);
    });
    // Neither the charts (weeks) nor the off-screen sparklines asked for days.
    expect(days()).toBe(0);
    const callbacks = notify;
    notify = [];
    for (const cb of callbacks) cb([{ isIntersecting: true }]);
    await within(spark).findByRole('img');
    expect(days()).toBeGreaterThan(0);
  });
});
