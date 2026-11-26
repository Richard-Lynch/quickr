/**
 * Editing a timed entry (timers.md §3.8, §11.5): captured_at is never sent (it is the run's
 * end), and Edit times sends `timing` with `expected_revision`, showing the server's refusals
 * on the fields they name. Then the detail's entry actions (content-display.md §3.2): lap-type
 * badges, one-tap Remove on lap and pause rows, Resume run, the queued (A14) projection and
 * the OQ-14 redirect, against the fake run server and the page's own outbox.
 */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { connectOutboxEffects } from '../../api/outboxEffects';
import { clearRunMarkers } from '../../api/runs';
import type { EntryOut, RunEventIn, TopicDetail, TopicVersionOut } from '../../client';
import { client } from '../../client/client.gen';
import { toLocalSeconds } from '../../components/runs/timingEdit';
import { setRunTapCooldown, RUN_TAP_COOLDOWN_MS } from '../../components/runs/useRunActions';
import { ToastProvider } from '../../components/ui/Toast';
import { outbox, refreshOutboxSnapshot, startOutbox } from '../../lib/outbox/client';
import { isRunEvent } from '../../lib/outbox/kinds';
import { memoryAckedStore, setAckedStore } from '../../lib/runs/acked';
import { formatInstant, parseInstant } from '../../lib/runs/instant';
import { clearRunNotices, memoryNoticeStore, setNoticeStore } from '../../lib/runs/notices';
import { resetServerOffset } from '../../lib/runs/serverClock';
import { fakeRunServer, type FakeRunServer } from '../../test/fakeRunServer';
import { normalTimer } from '../../test/timer';
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
  timer: null,
  last_entry: null,
  questions: [],
};

const version: TopicVersionOut = {
  version: 1,
  questions: [],
  timer: { steps: [], laps: [], variables: [] },
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
  terminal_id: null,
  segments: [
    {
      kind: 'lap',
      step: null,
      label: 'Lap 1',
      started_at: '2026-10-23T08:00:00Z',
      ended_at: '2026-10-23T08:01:00Z',
      active_ms: 60_000,
      paused_ms: 0,
      lap_type: null,
      event_id: null,
      opened_by: null,
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

/** The page's query client, to refetch as if the server's state moved on. */
let queryClient = new QueryClient();

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
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>,
  );
  return userEvent.setup();
}

/** Types a note and saves; whether the form had a Captured-at field. */
async function saveNotes(): Promise<boolean> {
  const user = renderPage();
  await user.type(await screen.findByRole('textbox', { name: /notes/i }), 'Slow morning');
  const shown = screen.queryByLabelText(/captured at/i) !== null;
  await user.click(screen.getByRole('button', { name: /save changes/i }));
  await screen.findByText('entries page');
  return shown;
}

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
});

describe('EntryEditPage captured_at', () => {
  it('is hidden and left out of the PATCH for a timed entry', async () => {
    const patches = stubServer(entry(timing));
    expect(await saveNotes()).toBe(false);
    expect(patches).toHaveLength(1);
    expect(patches[0]).toMatchObject({ notes: 'Slow morning' });
    expect(patches[0]).not.toHaveProperty('captured_at');
  });

  it('is shown and sent for an untimed entry', async () => {
    const patches = stubServer(entry(null));
    expect(await saveNotes()).toBe(true);
    expect(patches[0]).toHaveProperty('captured_at');
  });
});

const stepped: TopicVersionOut = {
  ...version,
  timer: {
    steps: [
      { key: 'wash', label: 'Wash', alerts: [] },
      { key: 'dry', label: 'Dry', alerts: [] },
    ],
    laps: [],
    variables: [],
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
  terminal_id: null,
  segments: [
    {
      kind: 'step',
      step: 'wash',
      label: 'Wash',
      started_at: '2026-10-23T08:00:00Z',
      ended_at: '2026-10-23T08:02:00Z',
      active_ms: 120_000,
      paused_ms: 0,
      lap_type: null,
      event_id: null,
      opened_by: null,
    },
    {
      kind: 'step',
      step: 'dry',
      label: 'Dry',
      started_at: '2026-10-23T08:02:00Z',
      ended_at: '2026-10-23T08:05:00.500Z',
      active_ms: 180_500,
      paused_ms: 0,
      lap_type: null,
      event_id: null,
      opened_by: null,
    },
  ],
  skipped: [],
  pauses: [],
};

const [washSegment, drySegment] = steppedTiming.segments as [
  NonNullable<EntryOut['timing']>['segments'][number],
  NonNullable<EntryOut['timing']>['segments'][number],
];

const localAt = (iso: string) => toLocalSeconds(parseInstant(iso));

async function openEditor(user: ReturnType<typeof userEvent.setup>) {
  const section = await screen.findByRole('region', { name: 'Timing' });
  expect(within(section).getByTestId('run-total').textContent).toBe('5:00');
  await user.click(within(section).getByRole('button', { name: 'Edit times' }));
  return screen.getByRole('form', { name: 'Edit times' });
}

describe('EntryEditPage timing rows', () => {
  it('lists the pauses as rows between the segments they fall in, in time order', async () => {
    // pauses[0] (8:03:10–8:03:30) is in Dry; pauses[1] (8:00:30–8:00:50) in Wash.
    stubServer(
      entry({
        ...steppedTiming,
        paused_ms: 40_000,
        pauses: [
          { start: '2026-10-23T08:03:10Z', end: '2026-10-23T08:03:30Z', id: null },
          { start: '2026-10-23T08:00:30Z', end: '2026-10-23T08:00:50Z', id: null },
        ],
      }),
      undefined,
      stepped,
    );
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    const rows = within(within(section).getByRole('list', { name: 'Segments' })).getAllByRole(
      'listitem',
    ) as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
    expect(rows.map((r) => r.dataset.testid)).toEqual([
      'entry.timing.segment.0',
      'entry.timing.pause.1',
      'entry.timing.segment.1',
      'entry.timing.pause.0',
    ]);
    expect(rows[1].textContent).toBe('Paused · 0:20');
    expect(rows[1]).toHaveAccessibleName('Paused, 20 seconds');
    expect(rows[0].textContent).toContain('Wash');
    expect(rows[2].textContent).toContain('Dry');
  });

  it('shows no pause rows for a run without pauses', async () => {
    stubServer(entry(steppedTiming), undefined, stepped);
    renderPage();
    const section = await screen.findByRole('region', { name: 'Timing' });
    expect(within(section).getByTestId('entry.timing.segment.1')).toBeInTheDocument();
    expect(within(section).queryByTestId('entry.timing.pause.0')).toBeNull();
  });
});

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

  it('a 409 stale_revision stops saving until the times are reloaded', async () => {
    let revision = 1;
    let current = entry(steppedTiming);
    const patches: unknown[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: Request) => {
        const path = new URL(input.url).pathname;
        if (path.endsWith(`/entries/${ENTRY_ID}`) && input.method === 'PATCH') {
          const body = JSON.parse(await input.text()) as { expected_revision: number };
          patches.push(body);
          if (body.expected_revision !== revision)
            return json(409, {
              code: 'stale_revision',
              detail: `entry is at revision ${String(revision)}`,
              errors: [{ loc: ['body', 'expected_revision'], message: 'current revision is 2' }],
            });
          return json(200, { ...current, revision: revision + 1 });
        }
        if (path.endsWith(`/entries/${ENTRY_ID}`)) return json(200, { ...current, revision });
        if (path.endsWith('/versions')) return json(200, [stepped]);
        return json(404, { code: 'not_found', detail: 'not found', errors: [] });
      }),
    );
    const user = renderPage();
    const form = await openEditor(user);
    // Meanwhile another device edits the times: Wash now ends at 8:01.
    revision = 2;
    current = {
      ...current,
      timing: {
        ...steppedTiming,
        segments: [
          { ...washSegment, ended_at: '2026-10-23T08:01:00Z', active_ms: 60_000 },
          { ...drySegment, started_at: '2026-10-23T08:01:00Z', active_ms: 240_500 },
        ],
      },
    };
    await user.click(within(form).getByRole('button', { name: 'Save times' }));
    expect(
      await within(form).findByText('These times changed since you opened them'),
    ).toBeInTheDocument();
    expect(patches).toEqual([expect.objectContaining({ expected_revision: 1 })]);
    // Saving stays off: the draft is never sent against the new revision.
    expect(within(form).getByRole('button', { name: 'Save times' })).toBeDisabled();
    await user.click(within(form).getByRole('button', { name: 'Reload times' }));
    const fresh = screen.getByRole('form', { name: 'Edit times' });
    await waitFor(() => {
      // The input drops ":00" seconds when it shows the value.
      expect(within(fresh).getByLabelText<HTMLInputElement>('Segment 1 ended').value).toBe(
        localAt('2026-10-23T08:01:00Z').slice(0, 16),
      );
    });
    expect(within(fresh).queryByText('These times changed since you opened them')).toBeNull();
    await user.click(within(fresh).getByRole('button', { name: 'Save times' }));
    expect(await screen.findByText('Times updated')).toBeInTheDocument();
    expect(patches).toHaveLength(2);
    expect(patches[1]).toMatchObject({ expected_revision: 2 });
  });

  it('a times save keeps unsaved notes in the entry form', async () => {
    stubServer(
      entry(steppedTiming),
      () =>
        json(200, {
          ...entry(steppedTiming),
          revision: 2,
          captured_at: '2026-10-23T08:06:00Z',
          updated_at: '2026-10-23T09:00:00Z',
          timing: { ...steppedTiming, edited: true },
        }),
      stepped,
    );
    const user = renderPage();
    const notes = await screen.findByRole('textbox', { name: /notes/i });
    await user.type(notes, 'Draft note');
    const form = await openEditor(user);
    await user.click(within(form).getByRole('button', { name: 'Save times' }));
    expect(await screen.findByText('Times updated')).toBeInTheDocument();
    expect(await screen.findByText('edited')).toBeInTheDocument();
    expect(screen.getByRole<HTMLTextAreaElement>('textbox', { name: /notes/i }).value).toBe(
      'Draft note',
    );
  });

  it('a newer revision fetched while the sheet is open stops saving, with no 409', async () => {
    const e = entry(steppedTiming);
    let served = e;
    const patches: unknown[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: Request) => {
        const path = new URL(input.url).pathname;
        if (path.endsWith(`/entries/${ENTRY_ID}`) && input.method === 'PATCH') {
          patches.push(JSON.parse(await input.text()));
          return json(200, served);
        }
        if (path.endsWith(`/entries/${ENTRY_ID}`)) return json(200, served);
        if (path.endsWith('/versions')) return json(200, [stepped]);
        return json(404, { code: 'not_found', detail: 'not found', errors: [] });
      }),
    );
    const user = renderPage();
    const form = await openEditor(user);
    served = { ...e, revision: 2, updated_at: '2026-10-23T09:00:00Z' };
    await act(() => queryClient.invalidateQueries());
    expect(
      await within(form).findByText('These times changed since you opened them'),
    ).toBeInTheDocument();
    expect(within(form).getByRole('button', { name: 'Reload times' })).toBeInTheDocument();
    expect(within(form).getByRole('button', { name: 'Save times' })).toBeDisabled();
    expect(patches).toHaveLength(0);
  });
});

const counted: TopicVersionOut = {
  ...version,
  timer: null,
  questions: [
    {
      type: 'int',
      key: 'loads',
      label: 'Loads',
      required: false,
      help_text: null,
      min: null,
      max: null,
      unit: null,
    },
  ] as TopicVersionOut['questions'],
};

describe('EntryEditPage when the entry changes elsewhere', () => {
  function serve(loads: number) {
    let current: EntryOut = {
      ...entry(null),
      answers: [{ key: 'loads', type: 'int', value: loads }] as EntryOut['answers'],
    };
    vi.stubGlobal(
      'fetch',
      vi.fn((input: Request) => {
        const path = new URL(input.url).pathname;
        if (path.endsWith(`/entries/${ENTRY_ID}`)) return Promise.resolve(json(200, current));
        if (path.endsWith('/versions')) return Promise.resolve(json(200, [counted]));
        return Promise.resolve(json(404, { code: 'not_found', detail: 'not found', errors: [] }));
      }),
    );
    return (next: number) => {
      current = {
        ...current,
        revision: current.revision + 1,
        updated_at: '2026-10-23T09:00:00Z',
        answers: [{ key: 'loads', type: 'int', value: next }] as EntryOut['answers'],
      };
      return act(() => queryClient.invalidateQueries());
    };
  }
  const loads = () => screen.getByRole<HTMLInputElement>('textbox', { name: /loads/i });

  it('a clean form takes the new answer', async () => {
    const change = serve(2);
    renderPage();
    await waitFor(() => {
      expect(loads().value).toBe('2');
    });
    await change(3);
    await waitFor(() => {
      expect(loads().value).toBe('3');
    });
    expect(screen.queryByText('This entry changed elsewhere')).toBeNull();
  });

  it('a dirty form keeps the edits and says so, until Reload', async () => {
    const change = serve(2);
    const user = renderPage();
    await waitFor(() => {
      expect(loads().value).toBe('2');
    });
    await user.clear(loads());
    await user.type(loads(), '7');
    await change(3);
    expect(await screen.findByText('This entry changed elsewhere')).toBeInTheDocument();
    expect(loads().value).toBe('7');
    await user.click(screen.getByRole('button', { name: 'Reload' }));
    await waitFor(() => {
      expect(loads().value).toBe('3');
    });
    expect(screen.queryByText('This entry changed elsewhere')).toBeNull();
  });
});

// MARK: - Entry actions (content-display.md §3.2)

const RUN = '6f1c0000-0000-4000-8000-0000000000b1';
/** Event ids of the seeded run, `…c<n>`. */
const evt = (n: number) => `6f1c0000-0000-4000-8000-0000000000c${String(n)}`;

/** A topic with the `tiktok` lap types (Run, Rest) and, with `steps`, a Warm-up step first. */
function lapFixture(steps = false) {
  const timer = normalTimer({
    steps: steps ? [{ key: 'warmup', label: 'Warm-up' }] : [],
    laps: [
      { key: 'run', label: 'Run' },
      { key: 'rest', label: 'Rest' },
    ],
  });
  const t: TopicDetail = { ...topic, slug: 'intervals', name: 'Intervals', timer };
  const v: TopicVersionOut = { ...version, timer };
  return { topic: t, versions: [v] };
}

interface Tap {
  type: RunEventIn['type'];
  /** Seconds after the start. */
  s: number;
  seg?: number;
  pause_id?: string;
}

/**
 * The run `RUN`, stopped with its entry on the fake server: started `ago` ms before now, with
 * `taps` (ids `evt(1)`, `evt(2)`, …) then a stop (`evt(9)`) at `stopS` seconds.
 */
function seedStopped(server: FakeRunServer, taps: Tap[], stopS: number, ago = 10 * 60_000) {
  const t0 = Date.now() - ago;
  const at = (s: number) => formatInstant(t0 + s * 1000);
  server.record(RUN, { id: RUN, type: 'start', at: at(0), topic_id: topic.id, version: 1 });
  taps.forEach((t, i) => {
    const { s: sec, ...rest } = t;
    server.record(RUN, { id: evt(i + 1), at: at(sec), ...rest });
  });
  server.record(RUN, { id: evt(9), type: 'stop', at: at(stopS) });
}

/** Run, Rest, Run laps (taps at 30 s and 60 s) with a pause in the second lap. */
const LAPS_AND_PAUSE: Tap[] = [
  { type: 'lap', s: 30, seg: 0 },
  { type: 'pause', s: 40 },
  { type: 'resume', s: 50, pause_id: evt(2) },
  { type: 'lap', s: 60, seg: 1 },
];

interface Actions {
  server: FakeRunServer;
  user: ReturnType<typeof userEvent.setup>;
  section: () => Promise<HTMLElement>;
}

let teardown: (() => Promise<void>) | null = null;

afterEach(async () => {
  await teardown?.();
  teardown = null;
});

/**
 * The entry page for `RUN` against the fake run server (its `getEntry` serves the stored
 * entry), with the page's outbox flushing on its own as in the app. `offline`: run events
 * never reach the server (a network error), so they stay queued.
 */
function renderActions(
  fixture: { topic: TopicDetail; versions: TopicVersionOut[] },
  seed: (server: FakeRunServer) => void,
  opts: { offline?: boolean; patch?: (e: EntryOut) => EntryOut } = {},
): Actions {
  const server = fakeRunServer(fixture.topic, fixture.versions);
  seed(server);
  if (opts.patch) server.entries = server.entries.map(opts.patch);
  const base = server.fetch;
  vi.stubGlobal(
    'fetch',
    vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = input instanceof Request ? input.url : String(input);
      const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
      const path = new URL(url, 'http://quickr.test').pathname;
      if (opts.offline && path.startsWith('/api/v1/runs/') && method === 'POST')
        return Promise.reject(new TypeError('Failed to fetch'));
      const one = /^\/api\/v1\/entries\/([^/]+)$/.exec(path);
      if (one && method === 'GET') {
        const e = server.entries.find((x) => x.id === one[1]);
        return Promise.resolve(e ? json(200, e) : json(404, { code: 'not_found', errors: [] }));
      }
      return base(input, init);
    }),
  );
  Element.prototype.scrollIntoView = () => undefined;
  setAckedStore(memoryAckedStore());
  setNoticeStore(memoryNoticeStore());
  setRunTapCooldown(0);
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const disconnect = connectOutboxEffects(qc, outbox);
  const stop = startOutbox();
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic: fixture.topic }} />,
        children: [
          { path: 'entries/:entryId', element: <EntryEditPage /> },
          { path: 'entries', element: <p>entries page</p> },
          { path: 'record', element: <p>run panel</p> },
        ],
      },
    ],
    { initialEntries: [`/t/${fixture.topic.slug}/entries/${RUN}`] },
  );
  render(
    <QueryClientProvider client={qc}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>,
  );
  teardown = async () => {
    cleanup();
    stop();
    disconnect();
    qc.clear();
    await outbox.clear();
    await refreshOutboxSnapshot();
    setAckedStore(memoryAckedStore());
    clearRunMarkers();
    clearRunNotices();
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    resetServerOffset();
  };
  return {
    server,
    user: userEvent.setup(),
    section: () => screen.findByRole('region', { name: 'Timing' }),
  };
}

const stored = (server: FakeRunServer) => {
  const e = server.entries.find((x) => x.id === RUN);
  if (!e?.timing) throw new Error('no entry');
  return { ...e, timing: e.timing };
};

/** The run events this device has queued, oldest first. */
async function queuedEvents() {
  return (await outbox.list()).filter(isRunEvent).map((i) => i.payload.event);
}

async function confirmRemove(a: Actions, name: string) {
  await a.user.click(within(await a.section()).getByRole('button', { name }));
  const sheet = await screen.findByRole('dialog');
  await a.user.click(within(sheet).getByRole('button', { name: 'Remove' }));
}

describe('EntryEditPage entry actions: rows', () => {
  it('label typed laps with M1’s label and a neutral lap-type badge; steps have none', async () => {
    const a = renderActions(lapFixture(true), (s) =>
      seedStopped(
        s,
        [
          { type: 'next', s: 20, seg: 0 },
          { type: 'lap', s: 50, seg: 1 },
        ],
        80,
      ),
    );
    const section = await a.section();
    const rows = (await within(section).findAllByRole('listitem')).filter((r) =>
      r.dataset.testid?.startsWith('entry.timing.segment.'),
    );
    expect(rows.map((r) => r.textContent.replace(/\d+:\d\d/g, '').trim())).toEqual([
      '1Warm-up',
      '2Run 1Run',
      '3Rest 1Rest',
    ]);
    expect(within(section).queryByTestId('entry.timing.laptype.0')).toBeNull();
    expect(within(section).getByTestId('entry.timing.laptype.1').textContent).toBe('Run');
    expect(within(section).getByTestId('entry.timing.laptype.2').textContent).toBe('Rest');
  });

  it('offer Remove on lap and pause rows only: never on a step or the first segment', async () => {
    const a = renderActions(lapFixture(true), (s) =>
      seedStopped(
        s,
        [
          { type: 'next', s: 20, seg: 0 },
          { type: 'lap', s: 50, seg: 1 },
          { type: 'pause', s: 60 },
          { type: 'resume', s: 70, pause_id: evt(3) },
        ],
        90,
      ),
    );
    const section = await a.section();
    await within(section).findByTestId('entry.timing.segment.2');
    expect(within(section).queryByTestId('entry.timing.remove.0')).toBeNull(); // the step
    // The lap after the last step was opened by a `next`: removing it would be no_target.
    expect(within(section).getByTestId('entry.timing.remove.1')).toBeDisabled();
    expect(within(section).getByTestId('entry.timing.remove.2')).toBeEnabled();
    expect(within(section).getByTestId('entry.timing.pause.remove.0')).toBeEnabled();
  });

  it('give an untyped run’s first lap no Remove, and a pre-v2 timing (null ids) none at all', async () => {
    const a = renderActions(
      { topic, versions: [version] },
      (s) => seedStopped(s, [{ type: 'lap', s: 30, seg: 0 }], 60),
      {
        patch: (e) => ({
          ...e,
          timing: e.timing && {
            ...e.timing,
            terminal_id: null,
            segments: e.timing.segments.map((x) => ({ ...x, event_id: null, opened_by: null })),
          },
        }),
      },
    );
    const section = await a.section();
    await within(section).findByTestId('entry.timing.segment.1');
    expect(within(section).queryByTestId('entry.timing.remove.0')).toBeNull();
    expect(within(section).queryByTestId('entry.timing.remove.1')).toBeNull();
  });
});

describe('EntryEditPage Edit times with lap types', () => {
  it('reads each lap’s label after the save, relabelled in order through the lap types', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90));
    const section = await a.section();
    await a.user.click(await within(section).findByRole('button', { name: 'Edit times' }));
    const form = screen.getByRole('form', { name: 'Edit times' });
    const hints = () =>
      within(form)
        .getAllByText(/^(Run|Rest) \d: /)
        .map((h) => h.textContent?.split(':')[0]);
    expect(hints()).toEqual(['Run 1', 'Rest 1', 'Run 2']);
    // Dropping the second lap's boundary: the third lap becomes Rest 1 (timers2.md §3.2).
    await a.user.click(within(form).getByRole('button', { name: 'Remove segment 2' }));
    expect(hints()).toEqual(['Run 1', 'Rest 1']);
  });
});

describe('EntryEditPage entry actions: Remove', () => {
  it('a lap: confirms, sends one `remove` naming segments[i].event_id, and the row merges', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90));
    const before = stored(a.server);
    const section = await a.section();
    await within(section).findByTestId('entry.timing.segment.2');
    await confirmRemove(a, 'Remove Rest 1');
    await waitFor(() => expect(a.server.events().map((e) => e.type)).toEqual(['remove']));
    const sent = a.server.events()[0];
    expect(sent?.target).toBe(before.timing.segments[1]?.event_id);
    expect(sent?.target).toBe(evt(1));
    // The ack's entry replaces it: two segments, the laps relabelled, not edited.
    await waitFor(() => expect(within(section).queryByTestId('entry.timing.segment.2')).toBeNull());
    const after = stored(a.server);
    expect(after.revision).toBe(before.revision + 1);
    expect(after.timing.edited).toBe(false);
    expect(within(section).getByTestId('entry.timing.segment.1').textContent).toContain('Rest 1');
    expect(within(section).queryByText('edited')).toBeNull();
  });

  it('a pause: sends `remove` naming pauses[j].id, and the pause row goes', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90));
    const section = await a.section();
    await within(section).findByTestId('entry.timing.pause.0');
    await confirmRemove(a, 'Remove pause, 0:10');
    await waitFor(() => expect(a.server.events()).toHaveLength(1));
    expect(a.server.events()[0]).toMatchObject({ type: 'remove', target: evt(2) });
    await waitFor(() => expect(within(section).queryByTestId('entry.timing.pause.0')).toBeNull());
    expect(within(section).getByTestId('run-total').textContent).toBe('1:30');
  });

  it('Cancel sends nothing', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90));
    const section = await a.section();
    await a.user.click(await within(section).findByRole('button', { name: 'Remove Rest 1' }));
    await a.user.click(
      within(await screen.findByRole('dialog')).getByRole('button', { name: 'Cancel' }),
    );
    expect(await queuedEvents()).toEqual([]);
    expect(a.server.events()).toEqual([]);
  });

  it('offline: queues the remove; the entry stays with its timing re-projected and a pending mark', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      offline: true,
    });
    const section = await a.section();
    await within(section).findByTestId('entry.timing.segment.2');
    expect(within(section).queryByTestId('entry.timing.pending')).toBeNull();
    await confirmRemove(a, 'Remove Rest 1');
    await within(section).findByTestId('entry.timing.pending');
    const queued = await queuedEvents();
    expect(queued).toMatchObject([{ type: 'remove', target: evt(1) }]);
    // A14: no run projected (the entry is still shown here), the boundary merged and the
    // later lap relabelled, the total unchanged, nothing sent and no PATCH.
    expect(screen.queryByText('run panel')).toBeNull();
    expect(within(section).queryByTestId('entry.timing.segment.2')).toBeNull();
    expect(within(section).getByTestId('entry.timing.segment.1').textContent).toContain('Rest 1');
    expect(within(section).getByTestId('run-total').textContent).toBe('1:20');
    expect(a.server.entries[0]?.revision).toBe(1);
    expect(a.server.events()).toEqual([]);
  });
});

describe('EntryEditPage entry actions: Resume run', () => {
  it('sends `reopen` naming timing.terminal_id and goes to the run panel', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90));
    const terminal = stored(a.server).timing.terminal_id;
    expect(terminal).toBe(evt(9));
    await a.user.click(await within(await a.section()).findByTestId('entry-resume'));
    await screen.findByText('run panel');
    await waitFor(() => expect(a.server.events()).toHaveLength(1));
    expect(a.server.events()[0]).toMatchObject({ type: 'reopen', target: terminal });
  });

  it('offline: queues the reopen and goes to the run panel, which the run now represents', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      offline: true,
    });
    await a.user.click(await within(await a.section()).findByTestId('entry-resume'));
    await screen.findByText('run panel');
    expect(await queuedEvents()).toMatchObject([{ type: 'reopen', target: evt(9) }]);
    expect(a.server.events()).toEqual([]);
  });

  it('a pre-v2 timing (terminal_id null) sends target null: the server resolves it', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      offline: true,
      patch: (e) => ({ ...e, timing: e.timing && { ...e.timing, terminal_id: null } }),
    });
    await a.user.click(await within(await a.section()).findByTestId('entry-resume'));
    await screen.findByText('run panel');
    expect(await queuedEvents()).toMatchObject([{ type: 'reopen', target: null }]);
  });

  it('is offered within 7 days of the run’s start, not after', async () => {
    const day = 24 * 60 * 60_000;
    renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90, 8 * day));
    const section = await screen.findByRole('region', { name: 'Timing' });
    await within(section).findByTestId('entry.timing.segment.2');
    expect(within(section).queryByTestId('entry-resume')).toBeNull();
    // Remove has no window (timers2.md: a remove is an edit, bounded only by its target).
    expect(within(section).getByTestId('entry.timing.remove.2')).toBeEnabled();
  });

  it('is hidden while the topic has another run open here (A15)', async () => {
    const a = renderActions(lapFixture(), (s) => {
      seedStopped(s, LAPS_AND_PAUSE, 90);
      s.record(evt(7), {
        id: evt(7),
        type: 'start',
        at: formatInstant(Date.now() - 1000),
        topic_id: topic.id,
        version: 1,
      });
    });
    const section = await a.section();
    await within(section).findByTestId('entry.timing.remove.2');
    // listRuns lists the open run; Resume waits for it to load and then stays hidden.
    await waitFor(() =>
      expect(a.server.requests.some((r) => r.path === '/api/v1/runs')).toBe(true),
    );
    await waitFor(() => expect(within(section).queryByTestId('entry-resume')).toBeNull());
  });

  it('is hidden while a remove of the entry is queued', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      offline: true,
    });
    const section = await a.section();
    expect(await within(section).findByTestId('entry-resume')).toBeInTheDocument();
    await confirmRemove(a, 'Remove Rest 1');
    await within(section).findByTestId('entry.timing.pending');
    expect(within(section).queryByTestId('entry-resume')).toBeNull();
  });
});

describe('EntryEditPage entry actions on an edited entry', () => {
  it('offers neither Remove nor Resume', async () => {
    renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      patch: (e) => ({ ...e, timing: e.timing && { ...e.timing, edited: true } }),
    });
    const section = await screen.findByRole('region', { name: 'Timing' });
    await within(section).findByText('edited');
    expect(within(section).queryByTestId('entry-resume')).toBeNull();
    expect(within(section).queryByTestId(/^entry\.timing\.(pause\.)?remove\./)).toBeNull();
    expect(within(section).getByRole('button', { name: 'Edit times' })).toBeInTheDocument();
  });
});

describe('EntryEditPage OQ-14', () => {
  it('redirects to the run when the entry’s run is open here (a queued reopen)', async () => {
    const a = renderActions(lapFixture(), (s) => seedStopped(s, LAPS_AND_PAUSE, 90), {
      offline: true,
    });
    await within(await a.section()).findByTestId('entry-resume');
    // Another tab of this device resumed it: the local view now has the run open.
    const e = stored(a.server);
    await outbox.enqueue('run.event', {
      topic: { id: topic.id, slug: 'intervals', name: 'Intervals' },
      run_id: RUN,
      version: 1,
      steps: [],
      requires_answers: false,
      makes_entry: false,
      event: { type: 'reopen', at: formatInstant(Date.now()), target: e.timing.terminal_id },
      entry: { timing: e.timing, revision: e.revision },
    } as never);
    await refreshOutboxSnapshot();
    await screen.findByText('run panel');
  });
});
