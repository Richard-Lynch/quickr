/**
 * Run instants as integer epoch milliseconds (timers.md §2.3).
 *
 * Every instant in a run is a whole millisecond, so every duration is an exact integer
 * difference and segment sums equal the totals exactly. Wire strings are parsed here by
 * hand, truncating sub-millisecond digits, and never go through `Date` or a float: the
 * port of `parse_instant` / `format_instant` in backend/app/services/run_fold.py.
 */

const MS_PER_DAY = 86_400_000;

// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`: the API's date-time form (sync-protocol.md §1.5).
const INSTANT =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:([Zz])|([+-])(\d{2}):(\d{2}))$/;

/** Days from 1970-01-01 to a proleptic Gregorian date (H. Hinnant's `days_from_civil`). */
function daysFromCivil(y: number, m: number, d: number): number {
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146_097 + doe - 719_468;
}

/** The inverse of {@link daysFromCivil}. */
function civilFromDays(z: number): [number, number, number] {
  const zz = z + 719_468;
  const era = Math.floor(zz / 146_097);
  const doe = zz - era * 146_097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36_524) - Math.floor(doe / 146_096)) / 365,
  );
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  return [yoe + era * 400 + (m <= 2 ? 1 : 0), m, d];
}

function daysInMonth(y: number, m: number): number {
  return daysFromCivil(m === 12 ? y + 1 : y, m === 12 ? 1 : m + 1, 1) - daysFromCivil(y, m, 1);
}

/**
 * A wire date-time as epoch milliseconds, truncated (sub-millisecond digits dropped). It
 * needs an offset (`Z` or `±HH:MM`); throws on anything else.
 */
export function parseInstant(text: string): number {
  const m = INSTANT.exec(text);
  if (!m) throw new RangeError(`not an instant: ${JSON.stringify(text)}`);
  const [year, month, day, hour, minute, second] = m.slice(1, 7).map(Number) as [
    number,
    number,
    number,
    number,
    number,
    number,
  ];
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
    throw new RangeError(`not an instant: ${JSON.stringify(text)}`);
  }
  if (hour > 23 || minute > 59 || second > 59)
    throw new RangeError(`not an instant: ${JSON.stringify(text)}`);
  // The first three fraction digits are the milliseconds; the rest are dropped (truncation).
  const ms = Number(((m[7] ?? '') + '000').slice(0, 3));
  let offsetMinutes = 0;
  if (m[9] !== undefined) {
    const oh = Number(m[10]);
    const om = Number(m[11]);
    if (oh > 23 || om > 59) throw new RangeError(`not an instant: ${JSON.stringify(text)}`);
    offsetMinutes = (m[9] === '-' ? -1 : 1) * (oh * 60 + om);
  }
  const local =
    daysFromCivil(year, month, day) * MS_PER_DAY + ((hour * 60 + minute) * 60 + second) * 1000 + ms;
  return local - offsetMinutes * 60_000;
}

const pad = (n: number, width = 2) => String(n).padStart(width, '0');

/**
 * Epoch milliseconds as the server writes an instant: UTC, `Z`, and six fraction digits
 * only when the millisecond part isn't zero (pydantic's form).
 */
export function formatInstant(ms: number): string {
  if (!Number.isSafeInteger(ms)) throw new RangeError(`not a whole millisecond: ${ms}`);
  const days = Math.floor(ms / MS_PER_DAY);
  let rest = ms - days * MS_PER_DAY;
  const [y, mo, d] = civilFromDays(days);
  const milli = rest % 1000;
  rest = (rest - milli) / 1000;
  const head = `${pad(y, 4)}-${pad(mo)}-${pad(d)}T${pad(Math.floor(rest / 3600))}:${pad(Math.floor(rest / 60) % 60)}:${pad(rest % 60)}`;
  return milli ? `${head}.${pad(milli, 3)}000Z` : `${head}Z`;
}
