/**
 * Generator + drift check for shared/fixtures/home-due-vectors.json: the home screen's
 * due pill (`dueParts`, the decision behind `dueView`) and sections (`splitByDue`), for
 * the iOS port. The vectors hold the decision structure, not text (that is locale
 * dependent). `day_offset` depends on the local time zone, so it is pinned below.
 *
 * With QUICKR_UPDATE_VECTORS=1 (`make vectors`) this writes the file; otherwise it fails
 * when the committed file differs, like backend/tests/vectors.py.
 */
import { afterAll, describe, expect, it } from 'vitest';

import type { ScheduleOutput } from './schedule';
import { FRESH_DUE_MS, SOON_MS, dueParts, type DueStatus } from './schedule';
import { NO_OPEN_RUNS, splitByDue, type SplittableTopic } from './home';

// No @types/node in the app's tsconfig: reach Node through narrow local types.
interface NodeProcess {
  env: Record<string, string | undefined>;
}
interface NodeFs {
  existsSync(p: string): boolean;
  readFileSync(p: string, enc: 'utf8'): string;
  writeFileSync(p: string, data: string): void;
}
const nodeProcess = (globalThis as unknown as { process: NodeProcess }).process;

// Pin the zone before any Date is used (Node re-reads TZ when it is assigned). Vitest
// reuses its worker processes across test files, so put the previous value back after.
const TIMEZONE = 'Europe/London';
const previousTz = nodeProcess.env.TZ;
nodeProcess.env.TZ = TIMEZONE;
afterAll(() => {
  if (previousTz === undefined) delete nodeProcess.env.TZ;
  else nodeProcess.env.TZ = previousTz;
});

// A plain path: node:fs rejects jsdom's `URL`, and Vite rewrites
// `new URL('…', import.meta.url)` to a dev-server `/@fs/` path.
const FILE = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/../../../shared/fixtures/home-due-vectors.json`;
const FILE_LABEL = 'shared/fixtures/home-due-vectors.json';

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

const MIN = 60_000;
const NOW = '2026-10-20T12:00:00Z'; // 13:00 BST, Tuesday

function plus(iso: string, ms: number): string {
  return new Date(Date.parse(iso) + ms).toISOString().replace('.000Z', 'Z');
}

function due(patch: Partial<DueStatus>): DueStatus {
  return { is_due: false, due_since: null, next_due_at: null, last_entry_at: null, ...patch };
}

interface DueCase {
  name: string;
  now: string;
  due: DueStatus | null;
}

const DUE_CASES: DueCase[] = [
  { name: 'no due status', now: NOW, due: null },
  { name: 'unscheduled shape: nothing due, no next slot', now: NOW, due: due({}) },
  {
    name: 'last entry only, no next slot',
    now: NOW,
    due: due({ last_entry_at: plus(NOW, -60 * MIN) }),
  },
  // Server says due.
  { name: 'is_due without due_since: Due now', now: NOW, due: due({ is_due: true }) },
  {
    name: 'is_due without due_since ignores a past next_due_at',
    now: NOW,
    due: due({ is_due: true, next_due_at: plus(NOW, -120 * MIN) }),
  },
  {
    name: 'is_due fresh: since 1 min ago',
    now: NOW,
    due: due({ is_due: true, due_since: plus(NOW, -MIN) }),
  },
  {
    name: 'is_due fresh: since 29 min 59.999 s ago',
    now: NOW,
    due: due({ is_due: true, due_since: plus(NOW, -30 * MIN + 1) }),
  },
  {
    name: 'is_due at exactly 30 min: overdue',
    now: NOW,
    due: due({ is_due: true, due_since: plus(NOW, -30 * MIN) }),
  },
  {
    name: 'is_due since 3 h ago: overdue today',
    now: NOW,
    due: due({ is_due: true, due_since: plus(NOW, -180 * MIN) }),
  },
  {
    name: 'is_due since slightly in the future (clock skew): due',
    now: NOW,
    due: due({ is_due: true, due_since: plus(NOW, 5 * MIN) }),
  },
  {
    name: 'is_due uses due_since, not next_due_at',
    now: NOW,
    due: due({
      is_due: true,
      due_since: plus(NOW, -10 * MIN),
      next_due_at: plus(NOW, -300 * MIN),
    }),
  },
  {
    name: 'is_due since yesterday evening',
    now: '2026-10-20T07:00:00Z',
    due: due({ is_due: true, due_since: '2026-10-19T20:00:00Z' }),
  },
  {
    name: 'is_due since local yesterday 23:30 BST (same UTC day)',
    now: '2026-10-20T07:00:00Z',
    due: due({ is_due: true, due_since: '2026-10-19T22:30:00Z' }),
  },
  {
    name: 'is_due since 3 days ago',
    now: NOW,
    due: due({ is_due: true, due_since: '2026-10-17T07:00:00Z' }),
  },
  {
    name: 'is_due since 10 days ago',
    now: NOW,
    due: due({ is_due: true, due_since: '2026-10-10T07:00:00Z' }),
  },
  // Client-side: the next slot passed since the last fetch.
  {
    name: 'next_due_at == now: due since now',
    now: NOW,
    due: due({ next_due_at: NOW }),
  },
  {
    name: 'next_due_at 10 min ago: due',
    now: NOW,
    due: due({ next_due_at: plus(NOW, -10 * MIN) }),
  },
  {
    name: 'next_due_at 2 h ago: overdue',
    now: NOW,
    due: due({ next_due_at: plus(NOW, -120 * MIN), last_entry_at: plus(NOW, -1440 * MIN) }),
  },
  // Due in N min (wait <= SOON_MS); minutes = max(1, round(ms / 60000)).
  { name: 'wait 1 ms: 1 min', now: NOW, due: due({ next_due_at: '2026-10-20T12:00:00.001Z' }) },
  { name: 'wait 29.5 s: 1 min', now: NOW, due: due({ next_due_at: plus(NOW, 29_500) }) },
  { name: 'wait 30 s: 1 min', now: NOW, due: due({ next_due_at: plus(NOW, 30_000) }) },
  { name: 'wait 89.5 s: 1 min', now: NOW, due: due({ next_due_at: plus(NOW, 89_500) }) },
  {
    name: 'wait 90 s: 2 min (half rounds up)',
    now: NOW,
    due: due({ next_due_at: plus(NOW, 90_000) }),
  },
  { name: 'wait 25 min', now: NOW, due: due({ next_due_at: plus(NOW, 25 * MIN) }) },
  {
    name: 'wait 59 min 29.999 s: 59 min',
    now: NOW,
    due: due({ next_due_at: plus(NOW, 59 * MIN + 29_999) }),
  },
  {
    name: 'wait 59.5 min: 60 min (reads "1 h")',
    now: NOW,
    due: due({ next_due_at: plus(NOW, 59 * MIN + 30_000) }),
  },
  {
    name: 'wait exactly SOON (60 min): due in 60 min',
    now: NOW,
    due: due({ next_due_at: plus(NOW, 60 * MIN) }),
  },
  {
    name: 'wait SOON + 1 ms: next today',
    now: NOW,
    due: due({ next_due_at: '2026-10-20T13:00:00.001Z' }),
  },
  { name: 'wait 89 min: next today', now: NOW, due: due({ next_due_at: plus(NOW, 89 * MIN) }) },
  { name: 'wait 90 min: next today', now: NOW, due: due({ next_due_at: plus(NOW, 90 * MIN) }) },
  // Later.
  {
    name: 'next later today (21:00 BST)',
    now: NOW,
    due: due({ next_due_at: '2026-10-20T20:00:00Z', last_entry_at: plus(NOW, -30 * MIN) }),
  },
  {
    name: 'next 23:59 BST today',
    now: NOW,
    due: due({ next_due_at: '2026-10-20T22:59:00Z' }),
  },
  {
    name: 'next 00:30 BST tomorrow (same UTC day)',
    now: NOW,
    due: due({ next_due_at: '2026-10-20T23:30:00Z' }),
  },
  {
    name: 'next tomorrow, under 24 h away',
    now: '2026-10-20T21:00:00Z',
    due: due({ next_due_at: '2026-10-21T07:00:00Z' }),
  },
  {
    name: 'next tomorrow 08:00 BST',
    now: NOW,
    due: due({ next_due_at: '2026-10-21T07:00:00Z' }),
  },
  {
    name: 'next in 2 days',
    now: NOW,
    due: due({ next_due_at: '2026-10-22T07:00:00Z' }),
  },
  {
    name: 'next in 6 days',
    now: NOW,
    due: due({ next_due_at: '2026-10-26T08:00:00Z' }),
  },
  {
    name: 'next in exactly 7 days (same time)',
    now: NOW,
    due: due({ next_due_at: plus(NOW, 7 * 1440 * MIN) }),
  },
  {
    name: 'next in 7 days, earlier time (under 7 x 24 h)',
    now: NOW,
    due: due({ next_due_at: '2026-10-27T08:00:00Z' }),
  },
  {
    name: 'next far future',
    now: NOW,
    due: due({ next_due_at: '2027-02-14T09:00:00Z' }),
  },
  // Europe/London DST (BST ends 2026-10-25 01:00 UTC; starts 2026-03-29 01:00 UTC).
  {
    name: 'DST end: Sat 23:30 BST -> Sun 23:00 GMT is tomorrow (24.5 h)',
    now: '2026-10-24T22:30:00Z',
    due: due({ next_due_at: '2026-10-25T23:00:00Z' }),
  },
  {
    name: 'DST end: Sun -> Mon midnights are 25 h apart, still 1 day',
    now: '2026-10-25T10:00:00Z',
    due: due({ next_due_at: '2026-10-26T08:00:00Z' }),
  },
  {
    name: 'DST end: Sat 12:00 BST -> Sun 23:30 GMT',
    now: '2026-10-24T11:00:00Z',
    due: due({ next_due_at: '2026-10-25T23:30:00Z' }),
  },
  {
    name: 'DST end: due since Sat evening, now Sun morning',
    now: '2026-10-25T09:00:00Z',
    due: due({ is_due: true, due_since: '2026-10-24T19:00:00Z' }),
  },
  {
    name: 'DST end: 7 days across the change',
    now: '2026-10-20T08:00:00Z',
    due: due({ next_due_at: '2026-10-27T09:00:00Z' }),
  },
  {
    name: 'DST start: Sat 23:30 GMT -> Sun 23:45 BST is tomorrow (23.25 h)',
    now: '2026-03-28T23:30:00Z',
    due: due({ next_due_at: '2026-03-29T22:45:00Z' }),
  },
  {
    name: 'DST start: Sun -> Mon is 1 day',
    now: '2026-03-29T12:00:00Z',
    due: due({ next_due_at: '2026-03-30T07:00:00Z' }),
  },
  {
    name: 'winter (GMT): next 00:30 tomorrow',
    now: '2026-12-01T12:00:00Z',
    due: due({ next_due_at: '2026-12-02T00:30:00Z' }),
  },
  {
    name: 'year end: tomorrow is 1 Jan',
    now: '2026-12-31T12:00:00Z',
    due: due({ next_due_at: '2027-01-01T08:00:00Z' }),
  },
];

interface SplitTopic {
  id: string;
  status: 'active' | 'archived';
  scheduled: boolean;
  due: DueStatus | null;
}

interface SplitCase {
  name: string;
  now: string;
  topics: SplitTopic[];
}

const t = (id: string, patch: Partial<Omit<SplitTopic, 'id'>> = {}): SplitTopic => ({
  id,
  status: 'active',
  scheduled: true,
  due: null,
  ...patch,
});

const SPLIT_CASES: SplitCase[] = [
  { name: 'empty', now: NOW, topics: [] },
  {
    name: 'mixed: due, upcoming, unscheduled, archived',
    now: NOW,
    topics: [
      t('due-a', { due: due({ is_due: true, due_since: plus(NOW, -45 * MIN) }) }),
      t('later-b', { due: due({ next_due_at: plus(NOW, 300 * MIN) }) }),
      t('soon-c', { due: due({ next_due_at: plus(NOW, 20 * MIN) }) }),
      t('plain-d', { scheduled: false }),
      t('archived-due-e', {
        status: 'archived',
        due: due({ is_due: true, due_since: plus(NOW, -120 * MIN) }),
      }),
      t('archived-plain-f', { status: 'archived', scheduled: false }),
      t('archived-next-g', { status: 'archived', due: due({ next_due_at: plus(NOW, 10 * MIN) }) }),
    ],
  },
  {
    name: 'a passed next slot moves to due now',
    now: NOW,
    topics: [
      t('upcoming-a', { due: due({ next_due_at: plus(NOW, 30 * MIN) }) }),
      t('passed-b', { due: due({ next_due_at: plus(NOW, -MIN) }) }),
      t('exactly-now-c', { due: due({ next_due_at: NOW }) }),
    ],
  },
  {
    name: 'active unscheduled topic with a due status still counts as due',
    now: NOW,
    topics: [
      t('unscheduled-due', { scheduled: false, due: due({ is_due: true }) }),
      t('unscheduled-next', { scheduled: false, due: due({ next_due_at: plus(NOW, 60 * MIN) }) }),
    ],
  },
  {
    name: 'upcoming sorted by next_due_at, none last',
    now: NOW,
    topics: [
      t('null-due-a'),
      t('in-3h-b', { due: due({ next_due_at: plus(NOW, 180 * MIN) }) }),
      t('null-next-c', { due: due({ last_entry_at: plus(NOW, -60 * MIN) }) }),
      t('in-1h-d', { due: due({ next_due_at: plus(NOW, 60 * MIN) }) }),
      t('tomorrow-e', { due: due({ next_due_at: '2026-10-21T07:00:00Z' }) }),
      t('in-2h-f', { due: due({ next_due_at: plus(NOW, 120 * MIN) }) }),
    ],
  },
  {
    name: 'upcoming ties keep input order (stable), fractional seconds compare equal',
    now: NOW,
    topics: [
      t('tie-1', { due: due({ next_due_at: '2026-10-20T15:00:00Z' }) }),
      t('null-1'),
      t('early', { due: due({ next_due_at: '2026-10-20T14:00:00Z' }) }),
      t('tie-2', { due: due({ next_due_at: '2026-10-20T15:00:00.000Z' }) }),
      t('null-2'),
      t('tie-3', { due: due({ next_due_at: '2026-10-20T15:00:00Z' }) }),
      t('null-3', { due: due({}) }),
    ],
  },
  {
    name: 'sub-second next_due_at differences order',
    now: NOW,
    topics: [
      t('later-by-1ms', { due: due({ next_due_at: '2026-10-20T15:00:00.001Z' }) }),
      t('on-the-second', { due: due({ next_due_at: '2026-10-20T15:00:00Z' }) }),
    ],
  },
  {
    name: 'due now and other keep input order',
    now: NOW,
    topics: [
      t('other-z', { scheduled: false }),
      t('due-recent', { due: due({ is_due: true, due_since: plus(NOW, -5 * MIN) }) }),
      t('other-a', { status: 'archived' }),
      t('due-old', { due: due({ is_due: true, due_since: plus(NOW, -600 * MIN) }) }),
      t('due-no-since', { due: due({ is_due: true }) }),
      t('other-m', { scheduled: false }),
      t('due-passed', { due: due({ next_due_at: plus(NOW, -300 * MIN) }) }),
    ],
  },
];

// ---------------------------------------------------------------------------
// Build, serialise, check
// ---------------------------------------------------------------------------

const DUMMY_SCHEDULE: ScheduleOutput = {
  kind: 'daily',
  times: ['08:00'],
  days: [1, 2, 3, 4, 5, 6, 7],
  timezone: TIMEZONE,
  notify: true,
};

type Topic = SplittableTopic & { id: string };

function build(): Record<string, unknown> {
  return {
    meta: {
      generator: 'frontend/src/lib/home.vectors.test.ts',
      version: 1,
      timezone: TIMEZONE,
      fresh_due_ms: FRESH_DUE_MS,
      soon_ms: SOON_MS,
    },
    due_view: DUE_CASES.map((c) => ({ ...c, expected: dueParts(c.due, new Date(c.now)) })),
    split: SPLIT_CASES.map((c) => {
      const topics: Topic[] = c.topics.map((x) => ({
        id: x.id,
        status: x.status,
        schedule: x.scheduled ? DUMMY_SCHEDULE : null,
        due: x.due,
      }));
      const s = splitByDue(topics, new Date(c.now), NO_OPEN_RUNS);
      const ids = (xs: Topic[]) => xs.map((x) => x.id);
      return {
        ...c,
        expected: { due: ids(s.due), upcoming: ids(s.upcoming), other: ids(s.other) },
      };
    }),
  };
}

/** Recursively sort object keys (Python's `sort_keys=True`). */
function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v !== null && typeof v === 'object')
    return Object.fromEntries(
      Object.keys(v)
        .sort()
        .map((k) => [k, sortKeys((v as Record<string, unknown>)[k])]),
    );
  return v;
}

/** Same layout as `dump_cases` in backend/tests/vectors.py: one compact case per line. */
function dumpCases(doc: Record<string, unknown>): string {
  const parts = Object.keys(doc)
    .sort()
    .map((key) => {
      const value = doc[key];
      const rendered =
        Array.isArray(value) && value.length > 0
          ? `[\n${value.map((item) => `    ${JSON.stringify(sortKeys(item))}`).join(',\n')}\n  ]`
          : JSON.stringify(sortKeys(value), null, 2).replaceAll('\n', '\n  ');
      return `  ${JSON.stringify(key)}: ${rendered}`;
    });
  return `{\n${parts.join(',\n')}\n}\n`;
}

describe('home due vectors (shared with iOS)', () => {
  it(`pins the time zone to ${TIMEZONE}`, () => {
    expect(new Date('2026-01-15T12:00:00Z').getTimezoneOffset()).toBe(0);
    expect(new Date('2026-07-15T12:00:00Z').getTimezoneOffset()).toBe(-60);
    expect(new Date('2026-10-20T23:30:00Z').getDate()).toBe(21);
    expect(new Intl.DateTimeFormat().resolvedOptions().timeZone).toBe(TIMEZONE);
  });

  it('covers every kind and tone', () => {
    const parts = DUE_CASES.map((c) => dueParts(c.due, new Date(c.now)));
    expect(new Set(parts.map((p) => p.kind))).toEqual(
      new Set(['none', 'due_now', 'due_since', 'overdue_since', 'due_in', 'next', 'when']),
    );
    expect(new Set(parts.map((p) => p.tone))).toEqual(
      new Set(['none', 'due', 'overdue', 'soon', 'later']),
    );
    expect(new Set(DUE_CASES.map((c) => c.name)).size).toBe(DUE_CASES.length);
    expect(new Set(SPLIT_CASES.map((c) => c.name)).size).toBe(SPLIT_CASES.length);
  });

  it(`${FILE_LABEL} is up to date`, async () => {
    const fsName = 'node:fs';
    const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
    const content = dumpCases(build());
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS === '1') {
      fs.writeFileSync(FILE, content);
      return;
    }
    const stale = `${FILE_LABEL} is stale - run 'make vectors'`;
    expect(fs.existsSync(FILE), stale).toBe(true);
    expect(fs.readFileSync(FILE, 'utf8') === content, stale).toBe(true);
  });
});
