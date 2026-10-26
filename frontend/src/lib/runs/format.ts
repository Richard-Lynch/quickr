/**
 * The duration format of every client (timers.md §11.1): `m:ss` below one hour, `h:mm:ss`
 * from one hour (hours unbounded). Truncated to whole seconds, so a running timer and the
 * saved value agree; negative input reads `0:00`. Pinned by
 * `shared/fixtures/duration-format-vectors.json` (`run_fold.fmt_duration`).
 */
export function fmtDuration(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = String(seconds % 60).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${secs}` : `${minutes}:${secs}`;
}
