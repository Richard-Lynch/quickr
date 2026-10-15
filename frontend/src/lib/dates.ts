export type RangePreset = '7d' | '30d' | '90d' | 'all';

export const RANGE_PRESETS: { value: RangePreset; label: string }[] = [
  { value: '7d', label: '7 days' },
  { value: '30d', label: '30 days' },
  { value: '90d', label: '90 days' },
  { value: 'all', label: 'All' },
];

const DAYS: Record<Exclude<RangePreset, 'all'>, number> = { '7d': 7, '30d': 30, '90d': 90 };

export function isRangePreset(v: string | null): v is RangePreset {
  return v === '7d' || v === '30d' || v === '90d' || v === 'all';
}

/**
 * Inclusive lower bound for a preset, as a timezone-aware ISO string, or
 * undefined for "all". Anchored to local midnight so "7 days" means today + 6.
 */
export function rangeStart(preset: RangePreset, now: Date = new Date()): string | undefined {
  if (preset === 'all') return undefined;
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - (DAYS[preset] - 1));
  return toOffsetIso(d);
}

const pad = (n: number, w = 2): string => String(Math.trunc(Math.abs(n))).padStart(w, '0');

/** ISO 8601 with the local UTC offset, e.g. 2026-10-15T08:30:00+02:00. */
export function toOffsetIso(d: Date): string {
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(off / 60)}:${pad(off % 60)}`
  );
}

/** Value for an `<input type="datetime-local">` (local wall time, minute precision). */
export function toLocalInputValue(d: Date): string {
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}`
  );
}

/** `datetime-local` value -> timezone-aware ISO string, or null if unparsable. */
export function localInputToIso(value: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!m) return null;
  const [, y, mo, da, h, mi, se] = m;
  const d = new Date(Number(y), Number(mo) - 1, Number(da), Number(h), Number(mi), Number(se ?? 0));
  return Number.isNaN(d.getTime()) ? null : toOffsetIso(d);
}

export function browserTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ['year', 365 * 24 * 3600],
  ['month', 30 * 24 * 3600],
  ['week', 7 * 24 * 3600],
  ['day', 24 * 3600],
  ['hour', 3600],
  ['minute', 60],
];

export function formatRelative(iso: string | null, now: Date = new Date()): string {
  if (!iso) return 'never';
  const secs = (new Date(iso).getTime() - now.getTime()) / 1000;
  for (const [unit, size] of UNITS) {
    if (Math.abs(secs) >= size) return rtf.format(Math.round(secs / size), unit);
  }
  return 'just now';
}

const dtf = new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium',
  timeStyle: 'short',
});
const df = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });

export function formatDateTime(iso: string): string {
  return dtf.format(new Date(iso));
}

export function formatDate(iso: string): string {
  return df.format(new Date(iso));
}
