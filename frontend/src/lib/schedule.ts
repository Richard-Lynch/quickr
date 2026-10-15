/**
 * Topic schedules: editable draft <-> API `schedule`, client-side validation mirroring
 * `DailySchedule` / `IntervalSchedule` in `backend/app/schemas/api.py`, and the human
 * text for schedules and due status.
 */
import type { DailyScheduleInput, IntervalScheduleInput, Limits, TopicSummary } from '../client';
import { patternOf } from '../api/limits';
import { browserTimeZone } from './dates';

export type ScheduleKind = 'none' | 'daily' | 'interval';
export type IntervalUnit = 'minutes' | 'hours' | 'days';
export type ScheduleInput = DailyScheduleInput | IntervalScheduleInput;
export type ScheduleOutput = NonNullable<TopicSummary['schedule']>;
export type DueStatus = NonNullable<TopicSummary['due']>;

export interface ScheduleDraft {
  kind: ScheduleKind;
  /** Objects (not strings) so react-hook-form's field array can key them. */
  times: { value: string }[];
  /** ISO weekdays, 1 = Monday … 7 = Sunday. */
  days: number[];
  timezone: string;
  every: string;
  unit: IntervalUnit;
  notify: boolean;
}

export const ALL_DAYS = [1, 2, 3, 4, 5, 6, 7] as const;
export const UNIT_MINUTES: Record<IntervalUnit, number> = { minutes: 1, hours: 60, days: 1440 };

export function emptyScheduleDraft(timezone: string = browserTimeZone()): ScheduleDraft {
  return {
    kind: 'none',
    times: [{ value: '08:00' }],
    days: [...ALL_DAYS],
    timezone,
    every: '1',
    unit: 'days',
    notify: true,
  };
}

/** Largest unit that represents `minutes` exactly ("every 2 days" rather than 2880 min). */
export function splitInterval(minutes: number): { every: string; unit: IntervalUnit } {
  if (minutes % 1440 === 0) return { every: String(minutes / 1440), unit: 'days' };
  if (minutes % 60 === 0) return { every: String(minutes / 60), unit: 'hours' };
  return { every: String(minutes), unit: 'minutes' };
}

export function draftFromSchedule(s: ScheduleOutput | null | undefined): ScheduleDraft {
  const base = emptyScheduleDraft();
  if (!s) return base;
  if (s.kind === 'daily') {
    return {
      ...base,
      kind: 'daily',
      times: s.times.map((value) => ({ value })),
      days: [...s.days],
      timezone: s.timezone,
      notify: s.notify,
    };
  }
  return {
    ...base,
    kind: 'interval',
    ...splitInterval(s.every_minutes),
    timezone: s.timezone,
    notify: s.notify,
  };
}

/** Whether `tz` is an IANA zone this browser knows (the server checks its own list). */
export function isValidTimeZone(tz: string): boolean {
  if (!tz.trim()) return false;
  try {
    new Intl.DateTimeFormat('en', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** IANA zones for the picker (always including `current`). */
export function timeZoneOptions(current: string): string[] {
  let zones: string[];
  try {
    zones = Intl.supportedValuesOf('timeZone');
  } catch {
    zones = [];
  }
  const all = new Set(['UTC', ...zones, current, browserTimeZone()].filter(Boolean));
  return [...all].sort((a, b) => a.localeCompare(b));
}

export interface ScheduleIssue {
  /** Path relative to the schedule draft, e.g. `['times', 1, 'value']`. */
  path: (string | number)[];
  message: string;
}

export type ScheduleResult =
  { ok: true; schedule: ScheduleInput | null } | { ok: false; issues: ScheduleIssue[] };

function formatMinutes(n: number): string {
  const { every, unit } = splitInterval(n);
  const v = Number(every);
  return `${every} ${v === 1 ? unit.slice(0, -1) : unit}`;
}

/** Validate a draft and convert it to the API shape (`null` = no schedule). */
export function scheduleFromDraft(d: ScheduleDraft, limits: Limits): ScheduleResult {
  if (d.kind === 'none') return { ok: true, schedule: null };
  const issues: ScheduleIssue[] = [];
  const timezone = d.timezone.trim();
  if (!timezone) issues.push({ path: ['timezone'], message: 'Pick a time zone' });
  else if (timezone.length > 64 || !isValidTimeZone(timezone))
    issues.push({ path: ['timezone'], message: 'Unknown time zone (e.g. Europe/London, UTC)' });

  if (d.kind === 'daily') {
    const timeRe = patternOf(limits.time_pattern, '^([01][0-9]|2[0-3]):[0-5][0-9]$');
    const seen = new Set<string>();
    d.times.forEach((t, i) => {
      const v = t.value.trim();
      if (!v) issues.push({ path: ['times', i, 'value'], message: 'Enter a time' });
      else if (!timeRe.test(v))
        issues.push({ path: ['times', i, 'value'], message: 'Use a 24-hour time like 08:00' });
      else if (seen.has(v))
        issues.push({ path: ['times', i, 'value'], message: `${v} is already in the list` });
      seen.add(v);
    });
    if (d.times.length === 0) issues.push({ path: ['times'], message: 'Add at least one time' });
    else if (d.times.length > limits.schedule_max_times)
      issues.push({
        path: ['times'],
        message: `At most ${String(limits.schedule_max_times)} times a day`,
      });
    const days = [...new Set(d.days)].filter((x) => Number.isInteger(x) && x >= 1 && x <= 7);
    if (days.length === 0) issues.push({ path: ['days'], message: 'Pick at least one day' });
    if (issues.length > 0) return { ok: false, issues };
    return {
      ok: true,
      schedule: {
        kind: 'daily',
        times: d.times.map((t) => t.value.trim()),
        days: days.sort((a, b) => a - b),
        timezone,
        notify: d.notify,
      },
    };
  }

  const raw = d.every.trim();
  const n = Number(raw);
  let minutes: number | null = null;
  if (!raw) issues.push({ path: ['every'], message: 'Enter how often' });
  else if (!/^\d+$/.test(raw) || n < 1)
    issues.push({ path: ['every'], message: 'Enter a whole number' });
  else {
    minutes = n * UNIT_MINUTES[d.unit];
    if (minutes < limits.interval_min_minutes)
      issues.push({
        path: ['every'],
        message: `At least every ${formatMinutes(limits.interval_min_minutes)}`,
      });
    else if (minutes > limits.interval_max_minutes)
      issues.push({
        path: ['every'],
        message: `At most every ${formatMinutes(limits.interval_max_minutes)}`,
      });
  }
  if (issues.length > 0 || minutes === null) return { ok: false, issues };
  return {
    ok: true,
    schedule: { kind: 'interval', every_minutes: minutes, timezone, notify: d.notify },
  };
}

/**
 * Server path (relative to the request body) -> schedule draft field, e.g.
 * `schedule.times.0` -> `schedule.times.0.value`, `schedule.every_minutes` ->
 * `schedule.every`. Null when it isn't a schedule path.
 */
export function scheduleFieldFor(path: string): string | null {
  if (path === 'schedule' || path === 'schedule.kind') return 'schedule.kind';
  const m = /^schedule\.(.+)$/.exec(path);
  if (!m?.[1]) return null;
  const rest = m[1];
  const t = /^times\.(\d+)$/.exec(rest);
  if (t) return `schedule.times.${t[1] ?? '0'}.value`;
  if (rest === 'times') return 'schedule.times';
  if (rest === 'days' || rest.startsWith('days.')) return 'schedule.days';
  if (rest === 'every_minutes') return 'schedule.every';
  if (rest === 'timezone') return 'schedule.timezone';
  if (rest === 'notify') return 'schedule.notify';
  return 'schedule.kind';
}

// ---------------------------------------------------------------------------
// Human text
// ---------------------------------------------------------------------------

const DAY_SHORT = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;
export const DAY_LABELS = DAY_SHORT.map((short, i) => ({ value: i + 1, short }));

function dayRange(days: readonly number[]): string {
  const set = [...new Set(days)].sort((a, b) => a - b);
  if (set.length === 7) return 'every day';
  if (set.join() === '1,2,3,4,5') return 'weekdays';
  if (set.join() === '6,7') return 'weekends';
  return set.map((d) => DAY_SHORT[d - 1] ?? '?').join(', ');
}

/** "Daily 08:00, 21:00 · weekdays", "Every 3 hours". */
export function describeSchedule(s: ScheduleOutput | ScheduleInput | null | undefined): string {
  if (!s) return 'No schedule';
  if ('every_minutes' in s) return `Every ${formatMinutes(s.every_minutes)}`;
  const days = dayRange(s.days ?? ALL_DAYS);
  return `Daily ${s.times.join(', ')}${days === 'every day' ? '' : ` · ${days}`}`;
}

export type DueTone = 'due' | 'overdue' | 'soon' | 'later' | 'none';

export interface DueView {
  tone: DueTone;
  /** Short label for tiles, e.g. "Overdue · since 08:00" or "Due in 25 min". */
  label: string;
}

/** A due topic counts as merely "due" (not "overdue") this long after its slot started. */
export const FRESH_DUE_MS = 30 * 60_000;
/** "Due in 25 min" shows for slots this close; further away it's "Next 21:00". */
export const SOON_MS = 60 * 60_000;

const timeFmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short' });
const dateFmt = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });

function startOfDay(d: Date): number {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x.getTime();
}

/** "08:00", "yesterday 21:00", "Mon 08:00", "12 Oct" — relative to `now`, local time. */
export function formatWhen(iso: string, now: Date = new Date()): string {
  const d = new Date(iso);
  const days = Math.round((startOfDay(d) - startOfDay(now)) / 86_400_000);
  const time = timeFmt.format(d);
  if (days === 0) return time;
  if (days === -1) return `yesterday ${time}`;
  if (days === 1) return `tomorrow ${time}`;
  if (Math.abs(days) < 7) return `${weekdayFmt.format(d)} ${time}`;
  return dateFmt.format(d);
}

function minutesText(ms: number): string {
  const m = Math.max(1, Math.round(ms / 60_000));
  return m >= 60 ? `${String(Math.round(m / 60))} h` : `${String(m)} min`;
}

/**
 * Due right now: the server says so, or the next slot has passed since it last looked
 * (the list is only refetched every minute, and not at all offline).
 */
export function isDueNow(due: DueStatus | null | undefined, now: Date = new Date()): boolean {
  if (!due) return false;
  if (due.is_due) return true;
  return due.next_due_at !== null && Date.parse(due.next_due_at) <= now.getTime();
}

/** How a topic's due status reads on a tile. */
export function dueView(due: DueStatus | null | undefined, now: Date = new Date()): DueView {
  if (!due) return { tone: 'none', label: '' };
  if (isDueNow(due, now)) {
    const since = due.is_due ? due.due_since : due.next_due_at;
    if (!since) return { tone: 'due', label: 'Due now' };
    const age = now.getTime() - Date.parse(since);
    return age < FRESH_DUE_MS
      ? { tone: 'due', label: `Due now · since ${formatWhen(since, now)}` }
      : { tone: 'overdue', label: `Overdue · since ${formatWhen(since, now)}` };
  }
  if (!due.next_due_at) return { tone: 'none', label: '' };
  const wait = Date.parse(due.next_due_at) - now.getTime();
  if (wait <= SOON_MS) return { tone: 'soon', label: `Due in ${minutesText(wait)}` };
  const when = formatWhen(due.next_due_at, now);
  // "Next 9:00 PM" today; "Tomorrow 8:00 AM" / "Mon 8:00 AM" / "12 Oct" further out.
  const today = /^\d/.test(when);
  return {
    tone: 'later',
    label: today ? `Next ${when}` : when.charAt(0).toUpperCase() + when.slice(1),
  };
}

/**
 * Optimistic due status right after logging (the server recomputes it on refetch): the
 * open slot is satisfied, so the topic stops being due.
 */
export function dueAfterLogging(due: DueStatus | null, at: string): DueStatus | null {
  if (!due) return due;
  return {
    ...due,
    is_due: false,
    due_since: null,
    // An overdue slot's next_due_at is the slot itself; it's satisfied now.
    next_due_at:
      due.next_due_at && Date.parse(due.next_due_at) > Date.parse(at) ? due.next_due_at : null,
    last_entry_at:
      due.last_entry_at && Date.parse(due.last_entry_at) > Date.parse(at) ? due.last_entry_at : at,
  };
}
