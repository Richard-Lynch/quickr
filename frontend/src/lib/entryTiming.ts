/**
 * What an entry's timing shows (docs/specs/content-display.md §3.1, §3.2): the list row's
 * timing chip and the detail's rows, segments and pauses in one list in time order. The twin
 * of iOS `QuickrCore/Entries/EntryTimingModel.swift`.
 */
import type { TimerOutput as Timer, Timing, TimingPause, TimingSegment } from '../client';
import { timingSummary } from './entrySummary';
import { parseInstant } from './runs/instant';

/**
 * One row of the detail's timing list. `index` is the item's 0-based position in
 * `timing.segments` or `timing.pauses`, so the ids `entry.timing.segment.<i>` and
 * `entry.timing.pause.<i>` don't move when pauses join the list.
 */
export type TimingRow =
  | { kind: 'segment'; index: number; segment: TimingSegment }
  | { kind: 'pause'; index: number; pause: TimingPause; ms: number };

/** The list row's chip: the summary line's timing part, and what a screen reader says. */
export interface TimingChip {
  /** "12:40 · 3 laps" */
  text: string;
  /** "12 minutes 40 seconds, 3 laps" */
  label: string;
}

/**
 * The segments and pauses in time order: a pause sits after the segment it starts in, so it
 * reads "between the segments it falls in" (a pause stays whole, so it can run past that
 * segment's end). A pause starting exactly when a segment starts falls in that segment and
 * comes after it; one starting before the first segment comes first.
 */
export function timingRows(timing: Timing): TimingRow[] {
  const pauses = timing.pauses
    .map((pause, index) => ({ pause, index, start: parseInstant(pause.start) }))
    .sort((a, b) => a.start - b.start || a.index - b.index);
  const rows: TimingRow[] = [];
  let next = 0;
  /** Adds the pauses that start before `before`, in order. */
  const takePauses = (before: number) => {
    for (let p = pauses[next]; p && p.start < before; p = pauses[++next]) {
      rows.push({
        kind: 'pause',
        index: p.index,
        pause: p.pause,
        ms: parseInstant(p.pause.end) - p.start,
      });
    }
  };
  timing.segments.forEach((segment, index) => {
    takePauses(parseInstant(segment.started_at));
    rows.push({ kind: 'segment', index, segment });
  });
  takePauses(Infinity);
  return rows;
}

/** The chip for a timed entry; null for an untimed one (timers.md §11.1). */
export function timingChip(timing: Timing | null, timer: Timer | null): TimingChip | null {
  if (!timing) return null;
  return { text: timingSummary(timing, timer), label: spokenChip(timing) };
}

/**
 * The duration spoken, then the segments counted: "12 minutes 40 seconds, 3 laps", or with
 * steps "4 minutes, 2 steps, 1 lap". No segments: the duration alone.
 */
export function spokenChip(timing: Timing): string {
  const steps = timing.segments.filter((s) => s.kind === 'step').length;
  const laps = timing.segments.filter((s) => s.kind === 'lap').length;
  const parts = [spokenDuration(timing.active_ms)];
  if (steps) parts.push(unit(steps, 'step'));
  if (laps) parts.push(unit(laps, 'lap'));
  return parts.join(', ');
}

/**
 * A duration for a screen reader, in whole seconds: "1 hour 2 minutes", "12 minutes 40
 * seconds", "0 seconds" (iOS `RunPresentation.spoken`).
 */
export function spokenDuration(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  const parts: string[] = [];
  if (hours) parts.push(unit(hours, 'hour'));
  if (minutes) parts.push(unit(minutes, 'minute'));
  if (secs || parts.length === 0) parts.push(unit(secs, 'second'));
  return parts.join(' ');
}

function unit(n: number, one: string): string {
  return `${n} ${one}${n === 1 ? '' : 's'}`;
}

/**
 * How long the entry detail offers Resume run: 7 days from the run's start (timers2.md
 * glossary "Resumable", OQ-1's detail rule; tiles and toasts use 15 minutes from the stop).
 */
export const RESUME_FROM_DETAIL_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Whether the entry detail offers Resume run for this timing (content-display.md §3.2): an
 * unedited timing (timers2.md §3.6: an edited run can't be reopened) whose run started
 * within {@link RESUME_FROM_DETAIL_MS}. The page also hides it while the entry has a queued
 * remove and while the topic has a locally open or finishing run (A15).
 */
export function resumableFromDetail(timing: Timing | null, now: number): boolean {
  if (!timing || timing.edited) return false;
  return now - parseInstant(timing.started_at) <= RESUME_FROM_DETAIL_MS;
}

/**
 * A detail row's one-tap Remove (content-display.md §3.2): `none` on a step, the first
 * segment, an edited timing and a row whose id is null (a pre-v2 timing, A12); `disabled` on
 * a lap row a `next` opened (the lap after the last step: removing a `next` is `no_target`,
 * timers2.md §3.4); else `remove` with the event id to send as the `remove`'s target.
 */
export type RemoveControl =
  { kind: 'none' } | { kind: 'disabled' } | { kind: 'remove'; target: string };

export function removeControl(row: TimingRow, timing: Timing): RemoveControl {
  if (timing.edited) return { kind: 'none' };
  if (row.kind === 'pause') {
    return row.pause.id === null ? { kind: 'none' } : { kind: 'remove', target: row.pause.id };
  }
  const { segment, index } = row;
  if (segment.kind !== 'lap' || index === 0 || segment.event_id === null) return { kind: 'none' };
  // Only a lap event's boundary can go: a `next` (or the reserved `skip`) is a step's.
  return segment.opened_by === 'lap'
    ? { kind: 'remove', target: segment.event_id }
    : { kind: 'disabled' };
}
