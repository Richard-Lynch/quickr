/** The run UI's test harness: a timed topic, the fake server, and the app's routes. */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { cleanup, render } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider, useLocation } from 'react-router';
import { vi } from 'vitest';

import { connectOutboxEffects } from '../api/outboxEffects';
import { client } from '../client/client.gen';
import type { RunEventIn, TopicDetail, TopicSummary, TopicVersionOut } from '../client';
import { AppShell, TopBar } from '../components/AppShell';
import { RUN_TAP_COOLDOWN_MS, setRunTapCooldown } from '../components/runs/useRunActions';
import { ToastProvider } from '../components/ui/Toast';
import { outbox, refreshOutboxSnapshot, startOutbox } from '../lib/outbox/client';
import type { Question } from '../lib/questions';
import { memoryAckedStore, setAckedStore } from '../lib/runs/acked';
import { clearRunNotices, memoryNoticeStore, setNoticeStore } from '../lib/runs/notices';
import { resetServerOffset } from '../lib/runs/serverClock';
import type { TimerStep } from '../lib/runs/types';
import { RecordPage } from '../pages/topic/RecordPage';
import { TopicLayout } from '../pages/topic/TopicLayout';
import { TopicsPage } from '../pages/TopicsPage';
import { fakeRunServer, type FakeRunServer } from './fakeRunServer';

export const TOPIC_ID = '6f1c0000-0000-4000-8000-0000000000a1';

export const STEPS3: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
  { key: 'teeth', label: 'Teeth' },
];

export const HOW: Question = {
  key: 'how',
  label: 'How did it go',
  help_text: null,
  required: true,
  type: 'str',
  min_length: 0,
  max_length: 500,
  multiline: false,
};

export function timedTopic(opts: { steps?: TimerStep[] | null; questions?: Question[] } = {}): {
  topic: TopicDetail;
  versions: TopicVersionOut[];
} {
  const questions = opts.questions ?? [HOW];
  const steps = opts.steps === undefined ? STEPS3 : opts.steps;
  const topic: TopicDetail = {
    id: TOPIC_ID,
    slug: 'morning',
    name: 'Morning',
    description: '',
    status: 'active',
    current_version: 1,
    revision: 1,
    question_count: questions.length,
    entry_count: 0,
    last_captured_at: null,
    created_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-01T00:00:00Z',
    archived_at: null,
    schedule: null,
    schedule_updated_at: null,
    due: null,
    questions,
  };
  const versions: TopicVersionOut[] = [
    {
      version: 1,
      questions,
      timer: steps === null ? null : { steps },
      change_note: '',
      created_at: '2026-10-01T00:00:00Z',
      entry_count: 0,
    },
  ];
  return { topic, versions };
}

export function summaryOf(t: TopicDetail): TopicSummary {
  const summary: TopicSummary & { questions?: unknown } = { ...t };
  delete summary.questions;
  return summary;
}

/** Shows the current location, so tests can see where the app went. */
function Where() {
  const loc = useLocation();
  return <output data-testid="where">{loc.pathname + loc.search}</output>;
}

export interface Harness {
  server: FakeRunServer;
  qc: QueryClient;
  teardown: () => Promise<void>;
}

/**
 * Render the app at `path` against a fresh fake server for `topic`. The page's outbox
 * (IndexedDB, fake) flushes on its own, as in the app.
 */
export function renderRunApp(
  path: string,
  fixture: { topic: TopicDetail; versions: TopicVersionOut[] },
  seed?: (server: FakeRunServer) => void,
): Harness {
  const server = fakeRunServer(fixture.topic, fixture.versions);
  seed?.(server);
  const summary = summaryOf(fixture.topic);
  const base = server.fetch;
  server.fetch = (input, init) => {
    const url = new URL(
      input instanceof Request ? input.url : input instanceof URL ? input.href : input,
      'https://q.test',
    );
    if (url.pathname === '/api/v1/topics') {
      return Promise.resolve(
        new Response(JSON.stringify({ items: [summary], total: 1, limit: 50, offset: 0 }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      );
    }
    return base(input, init);
  };
  vi.stubGlobal('fetch', vi.fn(server.fetch));
  // jsdom has no layout: the forms scroll to their first error.
  Element.prototype.scrollIntoView = () => undefined;
  // Node's Request needs an absolute URL.
  client.setConfig({ baseUrl: 'http://quickr.test' });
  setAckedStore(memoryAckedStore());
  setNoticeStore(memoryNoticeStore());
  // Tests tap as fast as they like; the cooldown's own tests turn it back on.
  setRunTapCooldown(0);
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const disconnect = connectOutboxEffects(qc, outbox);
  const stop = startOutbox();
  const router = createMemoryRouter(
    [
      {
        element: (
          <>
            <Outlet />
            <Where />
          </>
        ),
        children: [
          {
            path: '/',
            element: <AppShell />,
            children: [
              { index: true, element: <TopicsPage /> },
              {
                path: 't/:ref',
                element: <TopicLayout />,
                children: [
                  {
                    index: true,
                    element: (
                      <>
                        <TopBar back="/" />
                        <p>Topic overview</p>
                      </>
                    ),
                  },
                  { path: 'record', element: <RecordPage /> },
                ],
              },
            ],
          },
        ],
      },
    ],
    { initialEntries: [path] },
  );
  render(
    <QueryClientProvider client={qc}>
      <ToastProvider>
        <RouterProvider router={router} />
      </ToastProvider>
    </QueryClientProvider>,
  );
  return {
    server,
    qc,
    teardown: async () => {
      cleanup();
      stop();
      disconnect();
      qc.clear();
      await outbox.clear();
      // The page's snapshots are module state: start the next test from empty ones.
      await refreshOutboxSnapshot();
      setAckedStore(memoryAckedStore());
      clearRunNotices();
      setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
      resetServerOffset();
      client.setConfig({ baseUrl: '' });
      vi.unstubAllGlobals();
    },
  };
}

export const RUN_ID = '0b5e0000-0000-4000-8000-0000000000b1';
const at = (s: number) => new Date(Date.now() - 60_000 + s * 1000).toISOString();

/** Seed a run of the topic, started a minute ago, with taps `s` seconds after its start. */
export function seedRun(
  server: FakeRunServer,
  taps: {
    type: RunEventIn['type'];
    s: number;
    seg?: number;
    step?: string;
    pause_id?: string;
    id?: string;
  }[] = [],
): void {
  server.record(RUN_ID, { id: RUN_ID, type: 'start', at: at(0), topic_id: TOPIC_ID, version: 1 });
  taps.forEach((t, i) => {
    const { s, id, ...rest } = t;
    server.record(RUN_ID, {
      id: id ?? `0b5e0000-0000-4000-8000-0000000001${String(i).padStart(2, '0')}`,
      at: at(s),
      ...rest,
    });
  });
}
