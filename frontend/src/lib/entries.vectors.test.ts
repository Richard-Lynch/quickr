/**
 * Generator + drift check for shared/fixtures/entries-range-vectors.json: the entries
 * page's date-range filter (`captured_from`, from `rangeStart` via `filterQuery`) and
 * the `range` URL param parsing (`parseRange`), for the iOS port. The range start is
 * local midnight, so it depends on the local time zone, which is pinned below.
 *
 * With QUICKR_UPDATE_VECTORS=1 (`make vectors`) this writes the file; otherwise it fails
 * when the committed file differs, like backend/tests/vectors.py.
 */
import { afterAll, describe, expect, it } from 'vitest';

import { RANGE_PRESETS, type RangePreset } from './dates';
import { filterQuery, parseRange } from './filters';

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
const FILE = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/../../../shared/fixtures/entries-range-vectors.json`;
const FILE_LABEL = 'shared/fixtures/entries-range-vectors.json';

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

interface RangeCase {
  name: string;
  now: string;
  range: RangePreset;
}

const NOW = '2026-10-20T12:00:00Z'; // 13:00 BST, Tuesday

// Europe/London DST in 2026: BST starts 2026-03-29 01:00 UTC (01:00 GMT -> 02:00 BST)
// and ends 2026-10-25 01:00 UTC (02:00 BST -> 01:00 GMT).
const CASES: RangeCase[] = [
  // Each range at a normal time (BST).
  { name: '7d at midday (BST)', now: NOW, range: '7d' },
  { name: '30d at midday (BST)', now: NOW, range: '30d' },
  { name: '90d at midday (BST)', now: NOW, range: '90d' },
  { name: 'all at midday (BST): no lower bound', now: NOW, range: 'all' },
  { name: '7d in high summer (BST)', now: '2026-07-15T12:00:00Z', range: '7d' },
  // GMT.
  { name: '7d at midday (GMT)', now: '2026-12-01T12:00:00Z', range: '7d' },
  { name: '30d at midday (GMT)', now: '2026-12-01T12:00:00Z', range: '30d' },
  { name: '90d at midday (GMT), start in BST', now: '2026-12-15T12:00:00Z', range: '90d' },
  { name: 'all in winter (GMT): no lower bound', now: '2026-12-01T12:00:00Z', range: 'all' },
  // Around local midnight.
  { name: '7d exactly at local midnight (BST)', now: '2026-10-19T23:00:00Z', range: '7d' },
  { name: '7d 1 s after local midnight (BST)', now: '2026-10-19T23:00:01Z', range: '7d' },
  {
    name: '7d 1 ms before local midnight (BST, same UTC day)',
    now: '2026-10-19T22:59:59.999Z',
    range: '7d',
  },
  { name: '30d 1 s after local midnight (BST)', now: '2026-10-19T23:00:01Z', range: '30d' },
  { name: '30d 1 s before local midnight (BST)', now: '2026-10-19T22:59:59Z', range: '30d' },
  { name: '7d exactly at local midnight (GMT)', now: '2026-12-01T00:00:00Z', range: '7d' },
  { name: '7d 1 s before local midnight (GMT)', now: '2026-11-30T23:59:59Z', range: '7d' },
  // DST start day (29 Mar) as now.
  {
    name: 'DST start day: 7d at 00:30 GMT, before the change',
    now: '2026-03-29T00:30:00Z',
    range: '7d',
  },
  {
    name: 'DST start day: 7d at 02:00 BST, just after the change',
    now: '2026-03-29T01:00:00Z',
    range: '7d',
  },
  {
    name: 'DST start day: 7d at 13:00 BST, start in GMT',
    now: '2026-03-29T12:00:00Z',
    range: '7d',
  },
  { name: 'DST start day: 90d at 13:00 BST', now: '2026-03-29T12:00:00Z', range: '90d' },
  // Range start around the DST start day.
  {
    name: 'DST start: 7d start lands the day before (Sat 28 Mar, GMT)',
    now: '2026-04-03T11:00:00Z',
    range: '7d',
  },
  {
    name: 'DST start: 7d start lands on the day (midnight still GMT)',
    now: '2026-04-04T11:00:00Z',
    range: '7d',
  },
  {
    name: 'DST start: 7d start lands the day after (Mon 30 Mar, BST)',
    now: '2026-04-05T11:00:00Z',
    range: '7d',
  },
  {
    name: 'DST start: 30d from mid April, start in GMT',
    now: '2026-04-15T11:00:00Z',
    range: '30d',
  },
  // DST end day (25 Oct) as now.
  {
    name: 'DST end day: 7d at 01:30 BST, first pass',
    now: '2026-10-25T00:30:00Z',
    range: '7d',
  },
  {
    name: 'DST end day: 7d at 01:30 GMT, second pass',
    now: '2026-10-25T01:30:00Z',
    range: '7d',
  },
  {
    name: 'DST end day: 7d at 12:00 GMT, start in BST',
    now: '2026-10-25T12:00:00Z',
    range: '7d',
  },
  { name: 'DST end day: 30d at 12:00 GMT', now: '2026-10-25T12:00:00Z', range: '30d' },
  {
    name: 'DST end day: 1 s before local midnight (GMT)',
    now: '2026-10-25T23:59:59Z',
    range: '7d',
  },
  // Range start around the DST end day.
  {
    name: 'DST end: 7d start lands the day before (Sat 24 Oct, BST)',
    now: '2026-10-30T12:00:00Z',
    range: '7d',
  },
  {
    name: 'DST end: 7d start lands on the day (midnight still BST)',
    now: '2026-10-31T12:00:00Z',
    range: '7d',
  },
  {
    name: 'DST end: 7d start lands the day after (Mon 26 Oct, GMT)',
    now: '2026-11-01T12:00:00Z',
    range: '7d',
  },
  // Year boundary.
  { name: 'year end: 7d on 31 Dec', now: '2026-12-31T12:00:00Z', range: '7d' },
  {
    name: 'year end: 7d 1 s before New Year',
    now: '2026-12-31T23:59:59Z',
    range: '7d',
  },
  { name: 'new year: 7d at midnight 1 Jan', now: '2027-01-01T00:00:00Z', range: '7d' },
  { name: 'new year: 7d on 3 Jan, start in December', now: '2027-01-03T12:00:00Z', range: '7d' },
  { name: 'new year: 30d on 10 Jan', now: '2027-01-10T12:00:00Z', range: '30d' },
  { name: 'new year: 90d on 10 Jan', now: '2027-01-10T12:00:00Z', range: '90d' },
  // Leap day 2028-02-29.
  { name: 'leap day: 7d on 29 Feb 2028', now: '2028-02-29T12:00:00Z', range: '7d' },
  { name: 'leap day: 7d on 1 Mar 2028', now: '2028-03-01T12:00:00Z', range: '7d' },
  { name: 'leap day: 7d start lands on 29 Feb', now: '2028-03-06T12:00:00Z', range: '7d' },
  { name: 'leap day: 30d on 15 Mar 2028', now: '2028-03-15T12:00:00Z', range: '30d' },
  { name: 'leap day: 30d start lands on 29 Feb', now: '2028-03-29T12:00:00Z', range: '30d' },
  { name: 'non-leap: 30d on 15 Mar 2027', now: '2027-03-15T12:00:00Z', range: '30d' },
  { name: 'leap day: 90d on 29 May 2028', now: '2028-05-29T11:00:00Z', range: '90d' },
];

interface ParseCase {
  raw: string | null;
}

// The `?range=` URL param: a missing or unknown value is the default, '30d'.
const PARSE_CASES: ParseCase[] = [
  { raw: null },
  { raw: '' },
  { raw: '7d' },
  { raw: '30d' },
  { raw: '90d' },
  { raw: 'all' },
  { raw: 'bogus' },
  { raw: '7D' },
  { raw: 'ALL' },
  { raw: ' 7d' },
  { raw: '7d ' },
  { raw: '1d' },
  { raw: '365d' },
  { raw: '7' },
];

// ---------------------------------------------------------------------------
// Build, serialise, check
// ---------------------------------------------------------------------------

/** The `captured_from` the PWA sends for a range at `now`, or null when it sends none. */
function capturedFrom(range: RangePreset, now: string): string | null {
  const q = filterQuery({ range, version: null, source: null }, new Date(now));
  return q.captured_from ?? null;
}

function build(): Record<string, unknown> {
  return {
    meta: {
      generator: 'frontend/src/lib/entries.vectors.test.ts',
      version: 1,
      timezone: TIMEZONE,
    },
    cases: CASES.map((c) => ({ ...c, expected: capturedFrom(c.range, c.now) })),
    parse: PARSE_CASES.map((c) => ({ ...c, expected: parseRange(c.raw) })),
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

describe('entries range vectors (shared with iOS)', () => {
  it(`pins the time zone to ${TIMEZONE}`, () => {
    expect(new Date('2026-01-15T12:00:00Z').getTimezoneOffset()).toBe(0);
    expect(new Date('2026-07-15T12:00:00Z').getTimezoneOffset()).toBe(-60);
    expect(new Date('2026-10-20T23:30:00Z').getDate()).toBe(21);
    expect(new Intl.DateTimeFormat().resolvedOptions().timeZone).toBe(TIMEZONE);
  });

  it('covers every range and both offsets', () => {
    expect(new Set(CASES.map((c) => c.range))).toEqual(new Set(RANGE_PRESETS.map((p) => p.value)));
    expect(new Set(CASES.map((c) => c.name)).size).toBe(CASES.length);
    expect(new Set(PARSE_CASES.map((c) => c.raw)).size).toBe(PARSE_CASES.length);
    const starts = CASES.map((c) => capturedFrom(c.range, c.now));
    expect(starts.some((s) => s?.endsWith('+00:00'))).toBe(true);
    expect(starts.some((s) => s?.endsWith('+01:00'))).toBe(true);
    // Every start is a local midnight.
    for (const s of starts) if (s !== null) expect(s).toMatch(/T00:00:00[+-]\d\d:\d\d$/);
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
