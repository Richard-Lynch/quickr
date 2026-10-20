/**
 * Generator + drift check for shared/fixtures/schedule-vectors.json: the schedule editor's
 * rules in `schedule.ts` (draft validation and its messages, the API shape it sends, the
 * draft a saved schedule opens as, the human description, server error paths, the "+ Time"
 * default), for the iOS port (TOPIC).
 *
 * With QUICKR_UPDATE_VECTORS=1 (`make vectors`) this writes the file; otherwise it fails
 * when the committed file differs, like backend/tests/vectors.py.
 */
import { afterAll, describe, expect, it } from 'vitest';

import { FALLBACK_LIMITS } from '../api/limits';
import {
  describeSchedule,
  draftFromSchedule,
  nextScheduleTime,
  scheduleFieldFor,
  scheduleFromDraft,
  splitInterval,
  type ScheduleDraft,
  type ScheduleInput,
  type ScheduleOutput,
} from './schedule';

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

// A saved schedule opens with the device zone for the fields it doesn't set; pin it. Vitest
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
const FILE = `${decodeURIComponent(new URL(import.meta.url).pathname).replace(/\/[^/]*$/, '')}/../../../shared/fixtures/schedule-vectors.json`;
const FILE_LABEL = 'shared/fixtures/schedule-vectors.json';

const LIMITS = FALLBACK_LIMITS;

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/** A draft with the empty draft's values for everything not given. */
function draft(over: Partial<Omit<ScheduleDraft, 'times'>> & { times?: string[] }): ScheduleDraft {
  const { times, ...rest } = over;
  return {
    kind: 'daily',
    times: (times ?? ['08:00']).map((value) => ({ value })),
    days: [1, 2, 3, 4, 5, 6, 7],
    timezone: 'Europe/London',
    every: '1',
    unit: 'days',
    notify: true,
    ...rest,
  };
}

const VALIDATE: { name: string; draft: ScheduleDraft }[] = [
  // None.
  { name: 'none: no schedule', draft: draft({ kind: 'none' }) },
  { name: 'none ignores broken fields', draft: draft({ kind: 'none', timezone: '', times: [] }) },
  // Daily: accepted.
  { name: 'daily: one time, every day', draft: draft({}) },
  { name: 'daily: notify off', draft: draft({ notify: false }) },
  { name: 'daily: times keep their order', draft: draft({ times: ['21:00', '08:00', '12:30'] }) },
  { name: 'daily: times are trimmed', draft: draft({ times: [' 08:00', '21:00\t'] }) },
  { name: 'daily: days deduplicated and sorted', draft: draft({ days: [5, 1, 3, 1] }) },
  { name: 'daily: out-of-range days dropped', draft: draft({ days: [0, 2, 8, 9] }) },
  { name: 'daily: midnight and 23:59', draft: draft({ times: ['00:00', '23:59'] }) },
  { name: 'daily: 24 times (the limit)', draft: draft({ times: hourly(24) }) },
  { name: 'daily: zone trimmed', draft: draft({ timezone: '  America/New_York ' }) },
  { name: 'daily: UTC', draft: draft({ timezone: 'UTC' }) },
  // Daily: rejected times.
  { name: 'daily: empty time', draft: draft({ times: [''] }) },
  { name: 'daily: blank time', draft: draft({ times: ['   '] }) },
  { name: 'daily: 12-hour time', draft: draft({ times: ['8:00'] }) },
  { name: 'daily: 24:00', draft: draft({ times: ['24:00'] }) },
  { name: 'daily: 12:60', draft: draft({ times: ['12:60'] }) },
  { name: 'daily: seconds', draft: draft({ times: ['08:00:00'] }) },
  { name: 'daily: am/pm', draft: draft({ times: ['8:00 AM'] }) },
  { name: 'daily: full-width digits', draft: draft({ times: ['０８:００'] }) },
  { name: 'daily: duplicate time', draft: draft({ times: ['08:00', '21:00', '08:00'] }) },
  { name: 'daily: duplicate after trim', draft: draft({ times: ['08:00', ' 08:00'] }) },
  {
    name: 'daily: duplicate and invalid mixed',
    draft: draft({ times: ['x', '08:00', 'x', '08:00'] }),
  },
  { name: 'daily: no times', draft: draft({ times: [] }) },
  { name: 'daily: 25 times (over the limit)', draft: draft({ times: hourly(24).concat('23:30') }) },
  { name: 'daily: no days', draft: draft({ days: [] }) },
  { name: 'daily: only invalid days', draft: draft({ days: [0, 8] }) },
  // Zones.
  { name: 'zone: empty', draft: draft({ timezone: '' }) },
  { name: 'zone: blank', draft: draft({ timezone: '   ' }) },
  { name: 'zone: unknown', draft: draft({ timezone: 'Mars/Olympus_Mons' }) },
  { name: 'zone: too long', draft: draft({ timezone: `Europe/${'x'.repeat(60)}` }) },
  { name: 'zone and times both wrong', draft: draft({ timezone: '', times: ['x'], days: [] }) },
  // Interval: accepted.
  { name: 'interval: every 1 day', draft: draft({ kind: 'interval', every: '1', unit: 'days' }) },
  {
    name: 'interval: every 3 hours',
    draft: draft({ kind: 'interval', every: '3', unit: 'hours' }),
  },
  {
    name: 'interval: 15 minutes (the minimum)',
    draft: draft({ kind: 'interval', every: '15', unit: 'minutes' }),
  },
  {
    name: 'interval: 90 days (the maximum)',
    draft: draft({ kind: 'interval', every: '90', unit: 'days' }),
  },
  {
    name: 'interval: leading zeros',
    draft: draft({ kind: 'interval', every: '007', unit: 'hours' }),
  },
  { name: 'interval: trimmed', draft: draft({ kind: 'interval', every: ' 2 ', unit: 'hours' }) },
  {
    name: 'interval: notify off, other zone',
    draft: draft({
      kind: 'interval',
      every: '45',
      unit: 'minutes',
      notify: false,
      timezone: 'Asia/Kolkata',
    }),
  },
  // Interval: rejected.
  { name: 'interval: empty', draft: draft({ kind: 'interval', every: '' }) },
  { name: 'interval: blank', draft: draft({ kind: 'interval', every: '  ' }) },
  { name: 'interval: zero', draft: draft({ kind: 'interval', every: '0' }) },
  { name: 'interval: negative', draft: draft({ kind: 'interval', every: '-2' }) },
  { name: 'interval: decimal', draft: draft({ kind: 'interval', every: '1.5' }) },
  { name: 'interval: plus sign', draft: draft({ kind: 'interval', every: '+3' }) },
  { name: 'interval: exponent', draft: draft({ kind: 'interval', every: '1e2' }) },
  { name: 'interval: words', draft: draft({ kind: 'interval', every: 'three' }) },
  { name: 'interval: full-width digits', draft: draft({ kind: 'interval', every: '３' }) },
  {
    name: 'interval: under the minimum',
    draft: draft({ kind: 'interval', every: '14', unit: 'minutes' }),
  },
  {
    name: 'interval: over the maximum',
    draft: draft({ kind: 'interval', every: '91', unit: 'days' }),
  },
  {
    name: 'interval: over the maximum in minutes',
    draft: draft({ kind: 'interval', every: '129601', unit: 'minutes' }),
  },
  {
    name: 'interval: huge number',
    draft: draft({ kind: 'interval', every: '99999999999999999999999', unit: 'minutes' }),
  },
  {
    name: 'interval: bad number and unknown zone',
    draft: draft({ kind: 'interval', every: 'x', timezone: 'Nowhere/Place' }),
  },
];

function hourly(n: number): string[] {
  return Array.from({ length: n }, (_, h) => `${String(h).padStart(2, '0')}:00`);
}

const SCHEDULES: (ScheduleOutput | ScheduleInput | null)[] = [
  null,
  { kind: 'daily', times: ['08:00'], days: [1, 2, 3, 4, 5, 6, 7], timezone: 'UTC', notify: true },
  {
    kind: 'daily',
    times: ['08:00', '21:00'],
    days: [1, 2, 3, 4, 5],
    timezone: 'UTC',
    notify: true,
  },
  { kind: 'daily', times: ['09:30'], days: [6, 7], timezone: 'UTC', notify: false },
  { kind: 'daily', times: ['07:15'], days: [1, 3, 5], timezone: 'Europe/London', notify: true },
  { kind: 'daily', times: ['07:15'], days: [5, 1, 1], timezone: 'Europe/London', notify: true },
  { kind: 'daily', times: ['12:00'], days: [7], timezone: 'Asia/Tokyo', notify: true },
  { kind: 'daily', times: ['12:00'], days: [1, 2, 3, 4, 5, 6], timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 15, timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 60, timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 90, timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 1440, timezone: 'UTC', notify: false },
  { kind: 'interval', every_minutes: 2880, timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 1500, timezone: 'UTC', notify: true },
  { kind: 'interval', every_minutes: 129_600, timezone: 'America/New_York', notify: true },
];

const SPLIT = [1, 15, 59, 60, 61, 90, 120, 1439, 1440, 1441, 2880, 4320, 10_080, 129_600];

const FIELD_PATHS = [
  'schedule',
  'schedule.kind',
  'schedule.times',
  'schedule.times.0',
  'schedule.times.12',
  'schedule.days',
  'schedule.days.3',
  'schedule.every_minutes',
  'schedule.timezone',
  'schedule.notify',
  'schedule.something_else',
  'schedule.times.x',
  'name',
  'questions.0.key',
  'schedules',
  '',
];

const NEXT_TIME: string[][] = [
  [],
  ['08:00'],
  ['21:00'],
  ['08:00', '20:00'],
  ['20:00', '08:00'],
  ['00:30'],
  ['12:00', '00:00'],
  ['00:00', '12:00'],
  ['x'],
  ['8:00'],
  ['99:99'],
  [''],
];

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

function plainDraft(d: ScheduleDraft) {
  return { ...d, times: d.times.map((t) => t.value) };
}

function generate() {
  return {
    meta: {
      generator: 'frontend/src/lib/schedule.vectors.test.ts',
      version: 1,
      timezone: TIMEZONE,
      limits: {
        time_pattern: LIMITS.time_pattern,
        schedule_max_times: LIMITS.schedule_max_times,
        interval_min_minutes: LIMITS.interval_min_minutes,
        interval_max_minutes: LIMITS.interval_max_minutes,
      },
    },
    validate: VALIDATE.map(({ name, draft: d }) => ({
      name,
      draft: plainDraft(d),
      expected: scheduleFromDraft(d, LIMITS),
    })),
    describe: SCHEDULES.map((schedule) => ({ schedule, expected: describeSchedule(schedule) })),
    split: SPLIT.map((minutes) => ({ minutes, ...splitInterval(minutes) })),
    from_schedule: SCHEDULES.map((schedule) => ({
      schedule,
      expected: plainDraft(draftFromSchedule(schedule as ScheduleOutput | null)),
    })),
    field_for: FIELD_PATHS.map((path) => {
      const field = scheduleFieldFor(path);
      return { path, expected: field === null ? null : field.replace(/^schedule\./, '') };
    }),
    next_time: NEXT_TIME.map((times) => ({
      times,
      expected: nextScheduleTime(times.map((value) => ({ value }))),
    })),
  };
}

// One case per line, like the other vector files.
function serialise(data: ReturnType<typeof generate>): string {
  const section = (items: unknown[]) =>
    `[\n${items.map((x) => `    ${JSON.stringify(x)}`).join(',\n')}\n  ]`;
  return `{\n  "meta": ${JSON.stringify(data.meta)},\n${(
    ['validate', 'describe', 'split', 'from_schedule', 'field_for', 'next_time'] as const
  )
    .map((k) => `  "${k}": ${section(data[k])}`)
    .join(',\n')}\n}\n`;
}

describe('schedule vectors', () => {
  it(`${FILE_LABEL} matches schedule.ts`, async () => {
    const fsName = 'node:fs';
    const fs = (await import(/* @vite-ignore */ fsName)) as NodeFs;
    const text = serialise(generate());
    if (nodeProcess.env.QUICKR_UPDATE_VECTORS) {
      fs.writeFileSync(FILE, text);
      return;
    }
    expect(fs.existsSync(FILE), `${FILE_LABEL} is missing: run make vectors`).toBe(true);
    expect(fs.readFileSync(FILE, 'utf8'), `${FILE_LABEL} is stale: run make vectors`).toBe(text);
  });

  it('every validate case runs under the pinned zone', () => {
    expect(Intl.DateTimeFormat().resolvedOptions().timeZone).toBe(TIMEZONE);
  });
});
