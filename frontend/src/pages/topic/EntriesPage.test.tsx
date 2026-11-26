/**
 * The entries list's rows (content-display.md §3.1): the summary line on every row, the timing
 * chip with its spoken label on timed entries (synced and still queued), none on an untimed
 * entry of a timed topic, and the desktop table's Timing column.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, render, screen, waitFor, within } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { EntryOut, EntryPage, TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../../components/ui/Toast';
import type { OutboxItem } from '../../lib/outbox/types';
import type { UseOutbox } from '../../lib/outbox/useOutbox';
import type { Question } from '../../lib/questions';
import { T0, runItem } from '../../test/runs';
import { normalTimer } from '../../test/timer';
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
/** The removable timing's event ids: this, then the segment's index. */
const EVENT = '6f1c0000-0000-4000-8000-0000000000d';

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
  timer: normalTimer({ steps: [] }),
  last_entry: null,
  questions: [reps],
};

/**
 * Version 1 called the same question "Count" and had a "Felt" text question v2 removed: an
 * entry of v1 reads its own labels and keeps its removed question's answer.
 */
const versions: TopicVersionOut[] = [
  {
    version: 2,
    questions: [reps],
    timer: normalTimer({ steps: [] }),
    change_note: '',
    created_at: '2026-10-02T00:00:00Z',
    entry_count: 2,
  },
  {
    version: 1,
    questions: [
      { ...reps, label: 'Count' },
      {
        type: 'str',
        key: 'felt',
        label: 'Felt',
        required: false,
        help_text: null,
        min_length: 0,
        max_length: 200,
        multiline: false,
      },
    ],
    timer: normalTimer({ steps: [] }),
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
  lap_type: null,
  event_id: null,
  opened_by: null,
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
    terminal_id: null,
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

/** `versionsUp`: false fails the versions request; a promise answers it when it settles. */
function stubServer(items: EntryOut[], versionsUp: boolean | Promise<void> = true) {
  const page: EntryPage = { items, total: items.length, offset: 0, limit: 25 };
  vi.stubGlobal(
    'fetch',
    vi.fn((input: Request) => {
      const path = new URL(input.url).pathname;
      if (path.endsWith('/entries')) return Promise.resolve(json(200, page));
      if (path.endsWith('/versions'))
        return typeof versionsUp === 'boolean'
          ? Promise.resolve(
              versionsUp
                ? json(200, versions)
                : json(500, { code: 'internal', detail: 'down', errors: [] }),
            )
          : versionsUp.then(() => json(200, versions));
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

/**
 * A run on this device against v1: two steps of a minute, then a queued stop that makes the
 * entry, with `answers`.
 */
function queueRun(answers: Record<string, unknown>): OutboxItem[] {
  const ofTopic = (item: OutboxItem): OutboxItem => {
    const run = item as ReturnType<typeof runItem>;
    return {
      ...run,
      payload: {
        ...run.payload,
        topic: { id: TOPIC_ID, slug: topic.slug, name: topic.name },
        version: 1,
        event: {
          ...run.payload.event,
          ...(run.payload.event.type === 'start' ? { topic_id: TOPIC_ID, version: 1 } : {}),
        },
      },
    };
  };
  return [
    runItem('start', { id: RUN, run: RUN, at: T0 }),
    runItem('next', { id: `${RUN.slice(0, -2)}a1`, run: RUN, at: T0 + 60_000, seg: 0 }),
    runItem('stop', {
      id: `${RUN.slice(0, -2)}a2`,
      run: RUN,
      at: T0 + 120_000,
      makes_entry: true,
      answers: answers as never,
    }),
  ].map(ofTopic);
}

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
    const [timedCaptured, timedTiming] = within(timedRow).getAllByRole('cell') as [
      HTMLElement,
      HTMLElement,
    ];
    // Every row shows its summary line, the table's under the captured-at date.
    expect(within(timedCaptured).getByTestId('entry-summary').textContent).toBe(
      '12:40 · 3 laps · Reps: 12',
    );
    expect(within(timedTiming).getByTestId('entry-timing').textContent).toBe('12:40 · 3 laps');
    const [, untimedTiming] = within(untimedRow).getAllByRole('cell') as [HTMLElement, HTMLElement];
    expect(within(untimedTiming).queryByTestId('entry-timing')).toBeNull();
    expect(untimedTiming.textContent).toBe('—');
  });

  it('show the same chip and summary on a timed entry still waiting to sync', async () => {
    queued = queueRun({ reps: 7, felt: 'strong' });
    stubServer([untimed]);
    renderPage();
    // Once the versions are in (the table's v1 column), so labels are v1's.
    await screen.findByRole('columnheader', { name: 'Felt' });
    const pending = screen.getByRole('list', { name: 'Not yet synced' });
    const chip = within(pending).getByTestId('entry-timing');
    expect(chip.textContent).toBe('2:00');
    expect(within(pending).getByRole('img', { name: '2 minutes, 2 steps' })).toBe(chip);
    // Recorded against v1: its labels, and the answer to the question v2 removed.
    expect(within(pending).getByTestId('entry-summary').textContent).toBe(
      '2:00 · Count: 7 · Felt: strong',
    );
  });

  it('leave out a queued answer that doesn’t fit while its version’s questions are not in', async () => {
    // The versions request fails: the current questions type the answers for the grid, and
    // v1's list answer to a question that is now an int is dropped rather than read as a
    // number; the summary line shows only the timing until v1's questions are known.
    queued = queueRun({ reps: ['a', 'b'] });
    stubServer([untimed], false);
    renderPage();
    const pending = await screen.findByRole('list', { name: 'Not yet synced' });
    expect(within(pending).getByTestId('entry-summary').textContent).toBe('2:00');
    expect(within(pending).getByTestId('entry-timing').textContent).toBe('2:00');
  });
});

/** 12:40 over three laps, each boundary a `lap` event (removable, content-display.md §3.2). */
const removable = entry(TIMED, {
  timing: timed.timing && {
    ...timed.timing,
    segments: timed.timing.segments.map((x, i) => ({
      ...x,
      event_id: `${EVENT}${String(i)}`,
      opened_by: i === 0 ? 'start' : 'lap',
    })),
  },
});

/** A v1 entry with timing: its answer is v1's "Count". */
const oldTimed = entry(OLD, {
  version: 1,
  captured_at: '2026-10-21T08:00:00Z',
  answers: [{ key: 'reps', type: 'int', value: 9 }],
  timing: timed.timing,
});

describe('EntriesPage A14 projection', () => {
  it('shows a row’s chip with its queued remove applied, marked Waiting to sync', async () => {
    // Remove lap 2's boundary: its time joins lap 1, so 12:40 over two laps.
    queued = [runItem('remove', { id: 'x1', run: TIMED, at: T0, target: `${EVENT}1`, steps: [] })];
    stubServer([removable, untimed]);
    renderPage();
    const [timedRow, untimedRow] = (await cards()) as [HTMLElement, HTMLElement];
    expect(within(timedRow).getByTestId('entry-timing').textContent).toBe('12:40 · 2 laps');
    expect(within(timedRow).getByRole('img', { name: '12 minutes 40 seconds, 2 laps' })).toBe(
      within(timedRow).getByTestId('entry-timing'),
    );
    expect(within(timedRow).getByTestId('entry-summary').textContent).toBe(
      '12:40 · 2 laps · Reps: 12',
    );
    expect(within(timedRow).getByTestId('entry-pending').textContent).toBe(' Waiting to sync');
    expect(within(untimedRow).queryByTestId('entry-pending')).toBeNull();
    // The table's Timing cell too.
    const [, tableRow] = within(screen.getByRole('table')).getAllByRole('row') as [
      HTMLElement,
      HTMLElement,
    ];
    const [, timingCell] = within(tableRow).getAllByRole('cell') as [HTMLElement, HTMLElement];
    expect(within(timingCell).getByTestId('entry-timing').textContent).toBe('12:40 · 2 laps');
    expect(within(timingCell).getByTestId('entry-pending')).toBeInTheDocument();
  });

  it('shows the server’s timing, unmarked, with no remove queued for the run', async () => {
    queued = [
      runItem('remove', { id: 'x1', run: UNTIMED, at: T0, target: `${EVENT}1`, steps: [] }),
    ];
    stubServer([removable]);
    renderPage();
    const [timedRow] = (await cards()) as [HTMLElement];
    expect(within(timedRow).getByTestId('entry-timing').textContent).toBe('12:40 · 3 laps');
    expect(within(timedRow).queryByTestId('entry-pending')).toBeNull();
  });
});

describe('EntriesPage summaries before the entry’s version is known (§1.2)', () => {
  const summaries = (rows: HTMLElement[]) =>
    rows.map((r) => within(r).queryByTestId('entry-summary')?.textContent ?? null);

  it('show only the timing part while the versions are loading, then the version’s labels', async () => {
    let answer: () => void = () => undefined;
    stubServer(
      [timed, oldTimed, old],
      new Promise<void>((r) => {
        answer = r;
      }),
    );
    renderPage();
    // v1 renamed nothing yet known: "Reps" (the current label) would mislabel v1's answer.
    expect(summaries(await cards())).toEqual(['12:40 · 3 laps · Reps: 12', '12:40 · 3 laps', null]);
    answer();
    await screen.findByRole('columnheader', { name: 'Felt' });
    expect(summaries(await cards())).toEqual([
      '12:40 · 3 laps · Reps: 12',
      '12:40 · 3 laps · Count: 9',
      'Count: 9',
    ]);
  });

  it('keep showing only the timing part when the versions can’t be listed', async () => {
    stubServer([timed, oldTimed, old], false);
    renderPage();
    const rows = await cards();
    const calls = (fetch as unknown as { mock: { calls: [Request][] } }).mock.calls;
    await waitFor(() => {
      expect(calls.some(([r]) => r.url.includes('/versions'))).toBe(true);
    });
    await act(() => Promise.resolve());
    expect(summaries(rows)).toEqual(['12:40 · 3 laps · Reps: 12', '12:40 · 3 laps', null]);
  });
});

/**
 * OQ-14 (timers2.md §5.3, content-display.md §3.2): an entry whose run is open or finishing
 * on this device (here: a Resume queued from it) is the run's, not listed as an entry; the
 * total still counts it.
 */
describe('EntriesPage OQ-14', () => {
  /** A Resume tapped on `TIMED`'s detail, still queued: the run is projected resuming. */
  function queueReopen(): OutboxItem[] {
    const t = timed.timing;
    if (!t) throw new Error('timed has a timing');
    const item = runItem('reopen', {
      id: '6f1c0000-0000-4000-8000-0000000000a9',
      run: TIMED,
      at: Date.parse(t.ended_at) + 60_000,
      target: null,
      steps: [],
      entry: { timing: t, revision: timed.revision },
    });
    return [
      {
        ...item,
        payload: { ...item.payload, topic: { id: TOPIC_ID, slug: topic.slug, name: topic.name } },
      },
    ];
  }

  it('lists the entry while its run is closed', async () => {
    stubServer([timed, untimed]);
    renderPage();
    expect(await cards()).toHaveLength(2);
  });

  it('leaves out an entry whose run is open here, and still counts it', async () => {
    queued = queueReopen();
    stubServer([timed, untimed]);
    renderPage();
    const rows = await cards();
    expect(rows).toHaveLength(1);
    expect(rows[0]?.textContent).not.toContain('12:40');
    expect(screen.queryByRole('list', { name: 'Not yet synced' })).toBeNull();
    expect(screen.getByText(/^2 entries/)).toBeInTheDocument();
    // The desktop table too.
    const table = screen.getByRole('table');
    expect(within(table).getAllByRole('row')).toHaveLength(2); // the header and one entry
  });

  it('keeps Load more when every loaded entry is hidden', async () => {
    queued = queueReopen();
    // One entry per page: the first page holds only the hidden one.
    const pages = [timed, untimed];
    vi.stubGlobal(
      'fetch',
      vi.fn((input: Request) => {
        const url = new URL(input.url);
        if (url.pathname.endsWith('/entries')) {
          const offset = Number(url.searchParams.get('offset') ?? 0);
          const page: EntryPage = {
            items: pages.slice(offset, offset + 1),
            total: pages.length,
            offset,
            limit: 1,
          };
          return Promise.resolve(json(200, page));
        }
        if (url.pathname.endsWith('/versions')) return Promise.resolve(json(200, versions));
        if (url.pathname.endsWith('/runs')) return Promise.resolve(json(200, []));
        return Promise.resolve(json(404, { code: 'not_found', detail: 'nf', errors: [] }));
      }),
    );
    renderPage();
    const more = await screen.findByRole('button', { name: /load more/i });
    expect(screen.queryByText('No entries match')).toBeNull();
    more.click();
    // The second page's entry, the untimed one.
    await waitFor(async () => expect(await cards()).toHaveLength(1));
    expect((await cards())[0]?.textContent).not.toContain('12:40');
  });
});
