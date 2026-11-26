/**
 * Timed-topic models (timers.md §2, §4.3, §9.2; timers2.md §1, §3.3, §7.4).
 *
 * Two shapes for each thing that carries instants: the wire form (`…Wire`: date-time
 * strings, as the API sends them) and the folded form (epoch milliseconds, integers), which
 * is what the fold and the stats work on. Field names follow the API (snake_case), so the
 * two differ only in their instants. The run endpoints aren't in the generated client yet;
 * these are the shapes the spec gives them.
 */

export type RunEventType =
  | 'start'
  | 'next'
  | 'lap'
  | 'skip'
  | 'pause'
  | 'resume'
  | 'stop'
  | 'finish'
  | 'discard'
  | 'reopen'
  | 'remove';

export const RUN_EVENT_TYPES: readonly RunEventType[] = [
  'start',
  'next',
  'lap',
  'skip',
  'pause',
  'resume',
  'stop',
  'finish',
  'discard',
  'reopen',
  'remove',
];

export type VoidReason =
  | 'merged'
  | 'already_closed'
  | 'run_edited'
  | 'entry_deleted'
  | 'before_start'
  | 'after_stop'
  | 'too_long'
  | 'stale'
  | 'no_step'
  | 'already_paused'
  | 'not_paused'
  | 'reverted'
  | 'not_stopped'
  | 'deleted'
  | 'no_target';

/** The void reasons the server decides outside the fold (§4.4), for `Frozen`. */
export type FrozenReason = 'run_edited' | 'entry_deleted' | 'already_closed';

/** A run's status on the server (§2.2). The fold itself never says `finishing` (§3.5). */
export type RunStatus = 'running' | 'paused' | 'finishing' | 'stopped' | 'discarded';
export type FoldStatus = Exclude<RunStatus, 'finishing'>;

export type SegmentKind = 'step' | 'lap';

/**
 * `topic_versions.timer` (timers.md §2.1, timers2.md §1.1 Timer v2); `null` on an untimed
 * version. Tolerant of the v1 shape the API still accepts (§1.4): `laps`, `variables` and
 * every `alerts` list may be missing and then mean `[]`. Output from a v2 server always
 * carries them.
 */
export interface TimerAlert {
  key: string;
  label: string;
  /** An expression (timers2.md §2) over the timer's variables. */
  at: string;
  /**
   * `at` evaluated by the server, in milliseconds: output only, so an input timer may
   * leave it out (the server ignores a sent value and fills its own).
   */
  at_ms?: number;
}
export interface TimerStep {
  key: string;
  label: string;
  alerts?: TimerAlert[];
}
/** A lap type (§1.1): laps cycle through a timer's lap types, "Run 1, Rest 1, Run 2". */
export interface LapType {
  key: string;
  label: string;
  alerts?: TimerAlert[];
}
export interface TimerVariable {
  name: string;
  ms: number;
}
export interface Timer {
  steps: TimerStep[];
  laps?: LapType[];
  variables?: TimerVariable[];
}
/** What the fold reads of a timer (timers2.md §3.1): its steps and lap types. */
export interface FoldTimer {
  readonly steps: readonly TimerStep[];
  readonly laps?: readonly LapType[];
}

/**
 * One stored tap (§3.2). `seg` is set for next, lap and skip, `step` for skip, `pause_id`
 * for resume, `target` for reopen (a stop's id) and remove (a pause's, lap's or reopened
 * stop's id) (timers2.md §3.4). `target` may be left out on the other types.
 */
export interface RunEvent {
  id: string;
  type: RunEventType;
  at: number;
  seg: number | null;
  step: string | null;
  pause_id: string | null;
  target?: string | null;
}
export interface RunEventWire extends Omit<RunEvent, 'at'> {
  at: string;
}

/** Events from arrival index `after` on are void with `reason` and not folded (§4.4). */
export interface Frozen {
  after: number;
  reason: FrozenReason;
}

export interface Effect {
  effect: 'applied' | 'void';
  reason: VoidReason | null;
}

/**
 * `id` is the `pause` event's id (a gap pause carries its stop's id); null on a pre-v2
 * stored timing and after an edit (timers2.md §3.3).
 */
export interface Pause {
  start: number;
  end: number;
  id: string | null;
}
export interface PauseWire {
  start: string;
  end: string;
  id: string | null;
}

/** The type of the event that opened a segment (timers2.md §3.3); `skip` is reserved. */
export type OpenedBy = 'start' | 'next' | 'lap' | 'skip';

/**
 * A closed segment. `lap_type` is the lap type's key (null for a step or an untyped lap);
 * `event_id` and `opened_by` name the event that opened it (null and `start` for the first
 * segment; both null on a pre-v2 stored timing and after an edit) (timers2.md §3.2, §3.3).
 */
export interface Segment {
  kind: SegmentKind;
  step: string | null;
  label: string;
  started_at: number;
  ended_at: number;
  active_ms: number;
  paused_ms: number;
  lap_type: string | null;
  event_id: string | null;
  opened_by: OpenedBy | null;
}
export interface SegmentWire extends Omit<Segment, 'started_at' | 'ended_at'> {
  started_at: string;
  ended_at: string;
}

export interface OpenSegment {
  index: number;
  kind: SegmentKind;
  step: string | null;
  label: string;
  started_at: number;
  lap_type: string | null;
}
export interface OpenSegmentWire extends Omit<OpenSegment, 'started_at'> {
  started_at: string;
}

/**
 * The fold's output (§4.3, timers2.md §3.3), plus the run's start and (when stopped) end.
 * `segments`, `skipped` and `pauses` are the closed ones; an open pause is `paused_since`.
 * `effects` maps each lowercase event id to its effect; `finish` events have none.
 * `terminal_id` is the applied stop that closed the run (null while open, after a reopen
 * and for a discarded run); `next_lap_type` the type of the lap a `lap` tap would open now
 * (null when untyped or not open); `lap_count` the closed lap segments.
 */
export interface RunState {
  status: FoldStatus;
  started_at: number;
  ended_at: number | null;
  open: OpenSegment | null;
  next_step: string | null;
  paused_since: number | null;
  readonly segments: readonly Segment[];
  readonly skipped: readonly string[];
  readonly pauses: readonly Pause[];
  readonly effects: Readonly<Record<string, Effect>>;
  terminal_id: string | null;
  next_lap_type: string | null;
  lap_count: number;
}
export interface RunStateWire {
  status: RunStatus;
  started_at: string;
  ended_at: string | null;
  open: OpenSegmentWire | null;
  next_step: string | null;
  paused_since: string | null;
  segments: SegmentWire[];
  skipped: string[];
  pauses: PauseWire[];
  effects: Record<string, Effect>;
  terminal_id: string | null;
  next_lap_type: string | null;
  lap_count: number;
}

/** `entries.timing` (§2.3). `terminal_id` is the applied stop (an edit keeps it). */
export interface Timing {
  started_at: number;
  ended_at: number;
  active_ms: number;
  paused_ms: number;
  complete: boolean;
  edited: boolean;
  readonly segments: readonly Segment[];
  readonly skipped: readonly string[];
  readonly pauses: readonly Pause[];
  terminal_id: string | null;
}
export interface TimingWire extends Omit<
  Timing,
  'started_at' | 'ended_at' | 'segments' | 'pauses'
> {
  started_at: string;
  ended_at: string;
  segments: SegmentWire[];
  pauses: PauseWire[];
}

/**
 * A stored `entries.timing` as clients decode it: a pre-v2 timing has no `terminal_id`,
 * `lap_type`, `event_id`, `opened_by` or pause `id`, and they read null (timers2.md §3.3).
 */
export type StoredSegmentWire = Omit<SegmentWire, 'lap_type' | 'event_id' | 'opened_by'> &
  Partial<Pick<SegmentWire, 'lap_type' | 'event_id' | 'opened_by'>>;
export type StoredPauseWire = Omit<PauseWire, 'id'> & Partial<Pick<PauseWire, 'id'>>;
export interface StoredTimingWire extends Omit<TimingWire, 'segments' | 'pauses' | 'terminal_id'> {
  segments: StoredSegmentWire[];
  pauses: StoredPauseWire[];
  terminal_id?: string | null;
}

/** `getTopicTiming`'s answer (§9.2), in integer milliseconds. */
export interface Summary {
  best_ms: number | null;
  median_ms: number | null;
  mean_ms: number | null;
}
export interface StepStats extends Summary {
  key: string;
  label: string;
  current: boolean;
  done: number;
  skipped: number;
}
/** One lap-type key seen in range (timers2.md §7.4). */
export interface LapTypeStats extends Summary {
  key: string;
  label: string;
  /** Its lap segments over every timed run. */
  laps: number;
}
export interface LapStats {
  runs_with_laps: number;
  median_ms: number | null;
  mean_ms: number | null;
}
export interface PausedStats {
  runs_with_pauses: number;
  median_ms: number | null;
}
export interface SeriesPoint {
  entry_id: string;
  captured_at: number;
  started_at: number;
  active_ms: number;
  paused_ms: number;
  complete: boolean;
  steps: Record<string, number>;
  /** `active_ms` per lap type in that run; untyped laps are left out. */
  lap_types: Record<string, number>;
}
export interface SeriesPointWire extends Omit<SeriesPoint, 'captured_at' | 'started_at'> {
  captured_at: string;
  started_at: string;
}
export interface TopicTiming {
  runs: number;
  complete_runs: number;
  total: Summary;
  steps: StepStats[];
  lap_types: LapTypeStats[];
  laps: LapStats;
  paused: PausedStats;
  series: SeriesPoint[];
}
export interface TopicTimingWire extends Omit<TopicTiming, 'series'> {
  series: SeriesPointWire[];
}
