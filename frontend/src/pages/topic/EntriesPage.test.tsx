/**
 * The entries list's rows (content-display.md §3.1): the summary line on every row, the timing
 * chip with its spoken label on timed entries (synced and still queued), none on an untimed
 * entry of a timed topic, and the desktop table's Timing column.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, within } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { EntryOut, EntryPage, TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../../components/ui/Toast';
import type { OutboxItem } from '../../lib/outbox/types';
import type { UseOutbox } from '../../lib/outbox/useOutbox';
import type { Question } from '../../lib/questions';
import { T0, runItem } from '../../test/runs';
import { EntriesPage } from './EntriesPage';

/** What the outbox holds: the queued run events behind a pending timed entry. */
let queued: OutboxItem[] = [];

vi.mock('../../lib/outbox/useOutbox', () => ({
  useOutbox: (): Partial<UseOutbox> => ({
    items: queued,
    pending: queued,
    failed: [],
    pendingCount: queued.length,
    failedCount: 0,
    loaded: true,
    online: true,
  }),
}));

const TOPIC_ID = '6f1c0000-0000-4000-8000-000000000001';
const TIMED = '6f1c0000-0000-4000-8000-0000000000e1';
const UNTIMED = '6f1c0000-0000-4000-8000-0000000000e2';
const OLD = '6f1c0000-0000-4000-8000-0000000000e3';
const RUN = '6f1c0000-0000-4000-8000-0000000000f1';

const reps: Question = {
  type: 'int',
  key: 'reps',
  label: 'Reps',
  required: false,
  help_text: null,
  min: null,
  max: null,
  unit: null,
};

const topic: TopicDetail = {
  id: TOPIC_ID,
  slug: 'intervals',
  name: 'Intervals',
  description: '',
  status: 'active',
  current_version: 2,
  revision: 1,
  question_count: 1,
  entry_count: 3,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: { steps: [] },
  last_entry: null,
  questions: [reps],
};

/** Version 1 called the same question "Count": an entry of v1 reads its own label. */
const versions: TopicVersionOut[] = [
  {
    version: 2,
    questions: [reps],
    timer: { steps: [] },
    change_note: '',
    created_at: '2026-10-02T00:00:00Z',
    entry_count: 2,
  },
  {
    version: 1,
    questions: [{ ...reps, label: 'Count' }],
    timer: { steps: [] },
    change_note: '',
    created_at: '2026-10-01T00:00:00Z',
    entry_count: 1,
  },
];

const lap = (n: number, from: string, to: string, ms: number) => ({
  kind: 'lap' as const,
  step: null,
  label: `Lap ${String(n)}`,
  started_at: from,
  ended_at: to,
  active_ms: ms,
  paused_ms: 0,
});

function entry(id: string, over: Partial<EntryOut>): EntryOut {
  return {
    id,
    topic_id: TOPIC_ID,
    version: 2,
    revision: 1,
    source: 'phone',
    channel: 'ui',
    captured_at: '2026-10-23T08:12:40Z',
    created_at: '2026-10-23T08:12:40Z',
    updated_at: '2026-10-23T08:12:40Z',
    notes: '',
    meta: {},
    answers: [{ key: 'reps', type: 'int', value: 12 }],
    timing: null,
    ...over,
  };
}

/** 12:40 over three laps. */
const timed = entry(TIMED, {
  timing: {
    started_at: '2026-10-23T08:00:00Z',
    ended_at: '2026-10-23T08:12:40Z',
    active_ms: 760_000,
    paused_ms: 0,
    complete: true,
    edited: false,
    segments: [
      lap(1, '2026-10-23T08:00:00Z', '2026-10-23T08:04:00Z', 240_000),
      lap(2, '2026-10-23T08:04:00Z', '2026-10-23T08:08:00Z', 240_000),
      lap(3, '2026-10-23T08:08:00Z', '2026-10-23T08:12:40Z', 280_000),
    ],
    skipped: [],
    pauses: [],
  },
});
const untimed = entry(UNTIMED, { captured_at: '2026-10-22T08:00:00Z' });
const old = entry(OLD, {
  version: 1,
  captured_at: '2026-10-21T08:00:00Z',
  answers: [{ key: 'reps', type: 'int', value: 9 }],
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function stubServer(items: EntryOut[]) {
  const page: EntryPage = { items, total: items.length, offset: 0, limit: 25 };
  vi.stubGlobal(
    'fetch',
    vi.fn((input: Request) => {
      const path = new URL(input.url).pathname;
      if (path.endsWith('/entries')) return Promise.resolve(json(200, page));
      if (path.endsWith('/versions')) return Promise.resolve(json(200, versions));
      if (path.endsWith('/runs')) return Promise.resolve(json(200, []));
      return Promise.resolve(json(404, { code: 'not_found', detail: 'not found', errors: [] }));
    }),
  );
}

function renderPage() {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [{ path: 'entries', element: <EntriesPage /> }],
      },
    ],
    { initialEntries: ['/t/intervals/entries'] },
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

/** The phone cards (jsdom renders both layouts; the table is the other one). */
async function cards() {
  const table = await screen.findByRole('table');
  const list = table.closest('.hidden')?.previousElementSibling;
  if (!(list instanceof HTMLElement)) throw new Error('no card list');
  return within(list).getAllByRole('listitem');
}

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
  queued = [];
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('EntriesPage rows', () => {
  it('show every entry’s summary line, in its own version’s labels', async () => {
    stubServer([timed, untimed, old]);
    renderPage();
    const rows = await cards();
    expect(rows.map((r) => within(r).getByTestId('entry-summary').textContent)).toEqual([
      '12:40 · 3 laps · Reps: 12',
      'Reps: 12',
      'Count: 9',
    ]);
  });

  it('show the timing chip on a timed entry, with the segment count in its label', async () => {
    stubServer([timed, untimed]);
    renderPage();
    const [timedRow, untimedRow] = (await cards()) as [HTMLElement, HTMLElement];
    const chip = within(timedRow).getByTestId('entry-timing');
    expect(chip.textContent).toBe('12:40 · 3 laps');
    expect(within(timedRow).getByRole('img', { name: '12 minutes 40 seconds, 3 laps' })).toBe(chip);
    // The chip comes before the answers.
    const grid = timedRow.querySelector('dl');
    expect(grid && chip.compareDocumentPosition(grid) & Node.DOCUMENT_POSITION_FOLLOWING).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING,
    );
    // An untimed entry of a timed topic has none (timers.md §11.1).
    expect(within(untimedRow).queryByTestId('entry-timing')).toBeNull();
  });

  it('give the desktop table a Timing column after Captured', async () => {
    stubServer([timed, untimed]);
    renderPage();
    const table = await screen.findByRole('table');
    const headers = within(table)
      .getAllByRole('columnheader')
      .map((h) => h.textContent);
    expect(headers.slice(0, 3)).toEqual(['Captured', 'Timing', 'Reps']);
    const [, timedRow, untimedRow] = within(table).getAllByRole('row') as [
      HTMLElement,
      HTMLElement,
      HTMLElement,
    ];
    const [, timedTiming] = within(timedRow).getAllByRole('cell') as [HTMLElement, HTMLElement];
    expect(within(timedTiming).getByTestId('entry-timing').textContent).toBe('12:40 · 3 laps');
    const [, untimedTiming] = within(untimedRow).getAllByRole('cell') as [HTMLElement, HTMLElement];
    expect(within(untimedTiming).queryByTestId('entry-timing')).toBeNull();
    expect(untimedTiming.textContent).toBe('—');
  });

  it('show the same chip and summary on a timed entry still waiting to sync', async () => {
    // A run on this device: two steps of a minute, then a queued stop that makes the entry.
    const ofTopic = (item: OutboxItem): OutboxItem => {
      const run = item as ReturnType<typeof runItem>;
      return {
        ...run,
        payload: {
          ...run.payload,
          topic: { id: TOPIC_ID, slug: topic.slug, name: topic.name },
          version: 2,
          event: {
            ...run.payload.event,
            ...(run.payload.event.type === 'start' ? { topic_id: TOPIC_ID, version: 2 } : {}),
          },
        },
      };
    };
    queued = [
      runItem('start', { id: RUN, run: RUN, at: T0 }),
      runItem('next', { id: `${RUN.slice(0, -2)}a1`, run: RUN, at: T0 + 60_000, seg: 0 }),
      runItem('stop', {
        id: `${RUN.slice(0, -2)}a2`,
        run: RUN,
        at: T0 + 120_000,
        makes_entry: true,
        answers: { reps: 7 },
      }),
    ].map(ofTopic);
    stubServer([untimed]);
    renderPage();
    const pending = await screen.findByRole('list', { name: 'Not yet synced' });
    const chip = within(pending).getByTestId('entry-timing');
    expect(chip.textContent).toBe('2:00');
    expect(within(pending).getByRole('img', { name: '2 minutes, 2 steps' })).toBe(chip);
    expect(within(pending).getByTestId('entry-summary').textContent).toBe('2:00 · Reps: 7');
  });
});
