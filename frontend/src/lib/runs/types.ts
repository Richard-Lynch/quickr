/**
 * Timed-topic models (timers.md §2, §4.3, §9.2).
 *
 * Two shapes for each thing that carries instants: the wire form (`…Wire`: date-time
 * strings, as the API sends them) and the folded form (epoch milliseconds, integers), which
 * is what the fold and the stats work on. Field names follow the API (snake_case), so the
 * two differ only in their instants. The run endpoints aren't in the generated client yet;
 * these are the shapes the spec gives them.
 */

export type RunEventType =
  'start' | 'next' | 'lap' | 'skip' | 'pause' | 'resume' | 'stop' | 'finish' | 'discard';

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
  | 'not_paused';

/** The void reasons the server decides outside the fold (§4.4), for `Frozen`. */
export type FrozenReason = 'run_edited' | 'entry_deleted' | 'already_closed';

/** A run's status on the server (§2.2). The fold itself never says `finishing` (§3.5). */
export type RunStatus = 'running' | 'paused' | 'finishing' | 'stopped' | 'discarded';
export type FoldStatus = Exclude<RunStatus, 'finishing'>;

export type SegmentKind = 'step' | 'lap';

/** `topic_versions.timer` (§2.1); `null` on an untimed version. */
export interface TimerStep {
  key: string;
  label: string;
}
export interface Timer {
  steps: TimerStep[];
}

/** One stored tap (§3.2). `seg` is set for next, lap and skip, `step` for skip, `pause_id` for resume. */
export interface RunEvent {
  id: string;
  type: RunEventType;
  at: number;
  seg: number | null;
  step: string | null;
  pause_id: string | null;
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

export interface Pause {
  start: number;
  end: number;
}
export interface PauseWire {
  start: string;
  end: string;
}

export interface Segment {
  kind: SegmentKind;
  step: string | null;
  label: string;
  started_at: number;
  ended_at: number;
  active_ms: number;
  paused_ms: number;
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
}
export interface OpenSegmentWire extends Omit<OpenSegment, 'started_at'> {
  started_at: string;
}

/**
 * The fold's output (§4.3), plus the run's start and (when stopped) end. `segments`,
 * `skipped` and `pauses` are the closed ones; an open pause is `paused_since`. `effects`
 * maps each lowercase event id to its effect; `finish` events have none.
 */
export interface RunState {
  status: FoldStatus;
  started_at: number;
  ended_at: number | null;
  open: OpenSegment | null;
  next_step: string | null;
  paused_since: number | null;
  segments: Segment[];
  skipped: string[];
  pauses: Pause[];
  effects: Record<string, Effect>;
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
}

/** `entries.timing` (§2.3). */
export interface Timing {
  started_at: number;
  ended_at: number;
  active_ms: number;
  paused_ms: number;
  complete: boolean;
  edited: boolean;
  segments: Segment[];
  skipped: string[];
  pauses: Pause[];
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
  laps: LapStats;
  paused: PausedStats;
  series: SeriesPoint[];
}
export interface TopicTimingWire extends Omit<TopicTiming, 'series'> {
  series: SeriesPointWire[];
}
