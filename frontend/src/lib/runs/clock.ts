/**
 * Run-event time: the server's clock, monotonic per device (timers.md §5.1, rev 5).
 *
 * Pure helpers; the API client feeds them samples and the outbox stamps events with them.
 *
 * - Every `/api/v1` response carries `X-QuickR-Server-Time`, the server's time in integer
 *   epoch milliseconds ({@link parseServerTime}).
 * - The client keeps one offset, from the **latest** response whose round trip took at
 *   most 5 s; 0 before the first sample ({@link nextOffset}).
 * - A run event's `at` is device now + offset, truncated to whole milliseconds, and always
 *   after the latest `at` among that run's events in the local view
 *   ({@link stampRunEvent}).
 */

export const SERVER_TIME_HEADER = 'X-QuickR-Server-Time';

/** Samples with a longer round trip are ignored. */
export const MAX_SAMPLE_RTT_MS = 5000;

/** The offset before the first sample. */
export const INITIAL_OFFSET_MS = 0;

/** `X-QuickR-Server-Time`'s value as epoch milliseconds, or null when it isn't an integer. */
export function parseServerTime(value: string | null | undefined): number | null {
  if (value == null || !/^\d+$/.test(value.trim())) return null;
  const ms = Number(value.trim());
  return Number.isSafeInteger(ms) ? ms : null;
}

/**
 * One response's offset estimate, `server_time − (t_send + t_recv) / 2` (whole ms,
 * floored), or null when it doesn't qualify: a round trip over 5 s, or a negative one
 * (the device clock moved during the request). `tSend` and `tRecv` are device epoch
 * milliseconds, read just before the request and just after its response.
 */
export function offsetSample(serverTime: number, tSend: number, tRecv: number): number | null {
  const rtt = tRecv - tSend;
  if (!(rtt >= 0 && rtt <= MAX_SAMPLE_RTT_MS)) return null;
  return Math.floor(serverTime - (tSend + tRecv) / 2);
}

/** The offset after a response: its sample when it qualifies (the latest wins), else `current`. */
export function nextOffset(
  current: number,
  serverTime: number | null,
  tSend: number,
  tRecv: number,
): number {
  if (serverTime === null) return current;
  return offsetSample(serverTime, tSend, tRecv) ?? current;
}

/** Device now plus the offset, truncated to a whole millisecond (§2.3). */
export function serverNow(deviceNow: number, offset: number): number {
  return Math.floor(deviceNow + offset);
}

/** The latest `at` among a run's events in the local view (server and queued), or null. */
export function latestAt(ats: Iterable<number>): number | null {
  let latest: number | null = null;
  for (const at of ats) if (latest === null || at > latest) latest = at;
  return latest;
}

/**
 * `at`, clamped to at least the run's latest `at` + 1 ms, so a device's own events stay in
 * the order it made them. Strictly after: with an equal `at` the fold's id tie-break (§4.1)
 * could put a later tap first and void the earlier one as stale.
 */
export function clampToRun(at: number, latest: number | null): number {
  return latest === null ? at : Math.max(at, latest + 1);
}

/**
 * The `at` for a new event of a run: device now + offset, truncated, and clamped to just
 * after the latest `at` among `runAts`, the run's events in the local view (its own queued ones and
 * the server's). Offline, `offset` is simply the last one known.
 */
export function stampRunEvent(deviceNow: number, offset: number, runAts: Iterable<number>): number {
  return clampToRun(serverNow(deviceNow, offset), latestAt(runAts));
}
