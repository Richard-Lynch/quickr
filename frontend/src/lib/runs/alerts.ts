/**
 * Run alerts in the PWA (timers2.md §9.2): the pure planner. The maths is iOS's
 * `RunAlertPlan` (§9.1): for the **open segment** only, each alert of its step or lap type
 * fires at `seg_started_at + paused_in_segment_so_far + at_ms`, on the server's clock; none
 * while paused (`paused_since` set) or once the run is closed, none for an alert the
 * server hasn't evaluated (`at_ms` missing), and none at the segment's start (`at_ms <= 0`).
 *
 * The PWA fires only while the page is open: a background tab's timers are frozen or late,
 * so `RunAlerts.tsx` recomputes on return and fires what is at most {@link LATE_DROP_MS}
 * late; an older one is dropped (a missed alert, not a late one).
 */
import type { LapType, RunState, TimerAlert, TimerStep } from './types';

/** An alert later than this when the page can fire it is dropped (§9.2). */
export const LATE_DROP_MS = 30_000;

/** What the planner reads of a timer: its steps' and lap types' alerts. */
export interface AlertTimer {
  readonly steps: readonly TimerStep[];
  readonly laps?: readonly LapType[];
}

/** What the planner reads of a run (a `LocalRun` is one). */
export interface AlertRun {
  id: string;
  /** Other ids of the run (a merged run's), so an alert fired under one isn't refired. */
  aliases?: readonly string[] | undefined;
  state: Pick<RunState, 'open' | 'paused_since' | 'pauses'>;
}

export interface PlannedAlert {
  /** `{run_id}.{seg}.{alert.key}` (lowercase run id), as iOS's identifier after its prefix. */
  id: string;
  run_id: string;
  seg: number;
  key: string;
  /** The alert's label. */
  label: string;
  /** The open segment's label ("Rest 1"). */
  segment: string;
  /** When it fires, epoch ms on the server's clock. */
  at: number;
  /** The open segment's start: a moved start (an edit, a removed lap) re-arms the alert. */
  seg_started_at: number;
  /** The run's other ids (aliases), for {@link alertKeys}. */
  aliases: readonly string[];
}

/** The alerts of the open segment's step or lap type (an untyped lap has none). */
function segmentAlerts(
  timer: AlertTimer,
  open: NonNullable<RunState['open']>,
): readonly TimerAlert[] {
  if (open.kind === 'step') {
    return timer.steps.find((s) => s.key === open.step)?.alerts ?? [];
  }
  if (open.lap_type === null) return [];
  return timer.laps?.find((l) => l.key === open.lap_type)?.alerts ?? [];
}

/**
 * The open segment's alerts whose instant is after `now − graceMs` (`now` on the server's
 * clock), earliest first, then in the timer's order. With the default grace 0, only future
 * ones, as iOS plans them.
 */
export function planAlerts(
  run: AlertRun,
  timer: AlertTimer | null | undefined,
  now: number,
  graceMs = 0,
): PlannedAlert[] {
  const { open, paused_since, pauses } = run.state;
  if (!timer || !open || paused_since !== null) return [];
  // The segment's closed pauses so far: none can start after now, so this is stable.
  const to = Math.max(now, open.started_at);
  const paused = pauses.reduce(
    (sum, p) => sum + Math.max(0, Math.min(p.end, to) - Math.max(p.start, open.started_at)),
    0,
  );
  const runId = run.id.toLowerCase();
  const aliases = (run.aliases ?? []).map((a) => a.toLowerCase());
  return segmentAlerts(timer, open)
    .flatMap((alert, index) => {
      // An alert at the segment's start (`at_ms` 0, e.g. `0s` or `t-t`) never fires, as iOS
      // never schedules it (only future instants): the clients agree (M1 review P3-8).
      if (alert.at_ms === undefined || alert.at_ms <= 0) return [];
      const at = open.started_at + paused + alert.at_ms;
      return at > now - graceMs ? [{ alert, index, at }] : [];
    })
    .sort((a, b) => a.at - b.at || a.index - b.index)
    .map(({ alert, at }) => ({
      id: `${runId}.${String(open.index)}.${alert.key}`,
      run_id: runId,
      seg: open.index,
      key: alert.key,
      label: alert.label,
      segment: open.label,
      at,
      seg_started_at: open.started_at,
      aliases,
    }));
}

/** The run's next alert after `now` (server clock), or null (§9.2 `nextAlert`). */
export function nextAlert(
  run: AlertRun,
  timer: AlertTimer | null | undefined,
  now: number,
): PlannedAlert | null {
  return planAlerts(run, timer, now)[0] ?? null;
}

/**
 * The keys an alert is remembered by once fired: one per id of its run (aliases too), each
 * with its segment's start.
 */
export function alertKeys(alert: PlannedAlert): string[] {
  const rest = alert.id.slice(alert.run_id.length);
  return [alert.run_id, ...alert.aliases].map(
    (id) => `${id}${rest}@${String(alert.seg_started_at)}`,
  );
}

export interface AlertSchedule {
  /** To fire now: instants in `(now − LATE_DROP_MS, now]` not fired yet, earliest first. */
  due: PlannedAlert[];
  /** The earliest unfired alert after `now`, over every run: the one timeout's target. */
  next: PlannedAlert | null;
}

/**
 * What to fire now and what to wait for, over every run. `fired` holds {@link alertKeys}
 * of the alerts fired already. An alert exactly {@link LATE_DROP_MS} late still fires.
 */
export function alertSchedule(
  sources: readonly { run: AlertRun; timer: AlertTimer | null | undefined }[],
  now: number,
  fired: ReadonlySet<string>,
): AlertSchedule {
  const due: PlannedAlert[] = [];
  let next: PlannedAlert | null = null;
  for (const { run, timer } of sources) {
    for (const alert of planAlerts(run, timer, now, LATE_DROP_MS + 1)) {
      if (alertKeys(alert).some((k) => fired.has(k))) continue;
      if (alert.at <= now) due.push(alert);
      else if (next === null || alert.at < next.at) next = alert;
    }
  }
  due.sort((a, b) => a.at - b.at);
  return { due, next };
}
