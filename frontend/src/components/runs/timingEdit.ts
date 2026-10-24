/**
 * The Edit times form's model (timers.md §3.8): a stopped run's times as editable text, the
 * `TimingEdit` a save sends, and the client-side checks that mirror the server's (T2–T5, the
 * run's steps, the 7-day limit). The server stays the final word: its 422 field paths
 * (`timing.segments.1.ended_at`…) land on the same fields as these checks.
 *
 * Times are edited as local wall time to the second (`datetime-local` with seconds). An
 * instant left as it was keeps its exact original millisecond; an edited one is that second.
 */
import type { Step as TimerStep, Timing, TimingEdit } from '../../client';
import { MAX_RUN_MS } from '../../lib/runs/fold';
import { formatInstant, parseInstant } from '../../lib/runs/instant';

export interface DraftSegment {
  uid: string;
  kind: 'step' | 'lap';
  /** The step's key; null for a lap. */
  step: string | null;
  ended_at: string;
}

export interface DraftPause {
  uid: string;
  start: string;
  end: string;
}

export interface TimingDraft {
  started_at: string;
  segments: DraftSegment[];
  /** Skipped step keys (any order; a save sends them in step order). */
  skipped: string[];
  pauses: DraftPause[];
}

/** A field's path relative to `timing`, as the server reports it: `segments.0.ended_at`. */
export type FieldPath = string;
export type FieldErrors = Record<FieldPath, string>;

let counter = 0;
const nextUid = (p: string): string => `${p}${String((counter += 1))}`;

const pad = (n: number, w = 2): string => String(n).padStart(w, '0');

/** Epoch ms → `datetime-local` value with seconds, in the browser's zone. */
export function toLocalSeconds(ms: number): string {
  const d = new Date(ms);
  return (
    `${String(d.getFullYear())}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
  );
}

/** A `datetime-local` value (seconds optional) → epoch ms, or null when it isn't one. */
export function fromLocalInput(value: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!m) return null;
  const [y = 0, mo = 1, d = 1, h = 0, mi = 0, s = 0] = m
    .slice(1)
    .map((x: string | undefined) => Number(x ?? 0));
  const t = new Date(y, mo - 1, d, h, mi, s).getTime();
  return Number.isNaN(t) ? null : t;
}

/** The draft a stopped run's timing opens as. */
export function draftFromTiming(timing: Timing): TimingDraft {
  const local = (iso: string) => toLocalSeconds(parseInstant(iso));
  return {
    started_at: local(timing.started_at),
    segments: timing.segments.map((s) => ({
      uid: nextUid('g'),
      kind: s.kind,
      step: s.step,
      ended_at: local(s.ended_at),
    })),
    skipped: [...timing.skipped],
    pauses: timing.pauses.map((p) => ({
      uid: nextUid('p'),
      start: local(p.start),
      end: local(p.end),
    })),
  };
}

/**
 * Each original instant by its displayed text, so an untouched field sends its exact
 * millisecond rather than the whole second it shows.
 */
export function originalInstants(timing: Timing): Map<string, number> {
  const out = new Map<string, number>();
  const add = (iso: string) => {
    const ms = parseInstant(iso);
    const key = toLocalSeconds(ms);
    if (!out.has(key)) out.set(key, ms);
  };
  add(timing.started_at);
  for (const s of timing.segments) add(s.ended_at);
  for (const p of timing.pauses) {
    add(p.start);
    add(p.end);
  }
  return out;
}

function instantOf(value: string, originals: ReadonlyMap<string, number>): number | null {
  return originals.get(value) ?? fromLocalInput(value);
}

/** A segment added at the end: the first step not used yet, else a lap; zero length. */
export function newSegment(draft: TimingDraft, steps: readonly TimerStep[]): DraftSegment {
  const used = new Set(draft.segments.map((s) => s.step).filter((k) => k !== null));
  const free = steps.find((s) => !used.has(s.key));
  const last = draft.segments[draft.segments.length - 1];
  return {
    uid: nextUid('g'),
    kind: free ? 'step' : 'lap',
    step: free?.key ?? null,
    ended_at: last?.ended_at ?? draft.started_at,
  };
}

/** A zero-length pause at the run's end, to be moved. */
export function newPause(draft: TimingDraft): DraftPause {
  const last = draft.segments[draft.segments.length - 1];
  const at = last?.ended_at ?? draft.started_at;
  return { uid: nextUid('p'), start: at, end: at };
}

/** Pick what a segment times: a step's key, or `null` for a lap. Drops it from `skipped`. */
export function withSegmentStep(
  draft: TimingDraft,
  index: number,
  step: string | null,
): TimingDraft {
  return {
    ...draft,
    segments: draft.segments.map((s, i) =>
      i === index ? { ...s, kind: step === null ? 'lap' : 'step', step } : s,
    ),
    skipped: step === null ? draft.skipped : draft.skipped.filter((k) => k !== step),
  };
}

export interface Checked {
  errors: FieldErrors;
  /** The request body's `timing`, when there are no errors. */
  edit: TimingEdit | null;
  /** Per segment: its label ("Lap n" numbered in this order), active and paused ms. */
  segments: { label: string; active_ms: number | null; paused_ms: number | null }[];
  active_ms: number | null;
  paused_ms: number | null;
}

/**
 * Check a draft against the run's `steps` (its version's) and build the `TimingEdit`. The
 * rules are the server's (backend `edited_timing`), with its messages: the first problem in
 * each field is reported.
 */
export function checkTimingDraft(
  draft: TimingDraft,
  steps: readonly TimerStep[],
  originals: ReadonlyMap<string, number> = new Map(),
): Checked {
  const errors: FieldErrors = {};
  const fail = (path: FieldPath, message: string) => {
    errors[path] ??= message;
  };
  const byKey = new Map(steps.map((s) => [s.key, s]));
  const claimed = new Set<string>();
  const claim = (key: string, path: FieldPath) => {
    if (!byKey.has(key)) fail(path, `'${key}' is not a step of the run's version`);
    else if (claimed.has(key))
      fail(path, `Step '${byKey.get(key)?.label ?? key}' appears more than once`);
    claimed.add(key);
  };

  const start = instantOf(draft.started_at, originals);
  if (start === null) fail('started_at', 'Enter a date and time');
  if (draft.segments.length === 0) fail('segments', 'Keep at least one segment');

  const ends: (number | null)[] = [];
  let previous = start;
  draft.segments.forEach((seg, i) => {
    if (seg.kind === 'step') {
      if (seg.step === null) fail(`segments.${String(i)}.step`, 'Pick a step');
      else claim(seg.step, `segments.${String(i)}.step`);
    }
    const end = instantOf(seg.ended_at, originals);
    if (end === null) fail(`segments.${String(i)}.ended_at`, 'Enter a date and time');
    else if (previous !== null && end < previous)
      fail(`segments.${String(i)}.ended_at`, 'Before the segment’s start');
    ends.push(end);
    previous = end ?? previous;
  });
  draft.skipped.forEach((key, i) => claim(key, `skipped.${String(i)}`));

  const runEnd =
    ends.length > 0 && ends.every((e) => e !== null) ? (ends[ends.length - 1] ?? null) : null;
  if (start !== null && runEnd !== null && runEnd - start > MAX_RUN_MS)
    fail(
      `segments.${String(draft.segments.length - 1)}.ended_at`,
      'More than 7 days after the start',
    );

  const pauses: { start: number; end: number }[] = [];
  let floor = start;
  draft.pauses.forEach((p, i) => {
    const ps = instantOf(p.start, originals);
    const pe = instantOf(p.end, originals);
    if (ps === null) fail(`pauses.${String(i)}.start`, 'Enter a date and time');
    else if (floor !== null && ps < floor)
      fail(`pauses.${String(i)}.start`, 'Before the run’s start or the previous pause’s end');
    if (pe === null) fail(`pauses.${String(i)}.end`, 'Enter a date and time');
    else if (ps !== null && pe < ps) fail(`pauses.${String(i)}.end`, 'Before the pause’s start');
    else if (runEnd !== null && pe > runEnd) fail(`pauses.${String(i)}.end`, 'After the run’s end');
    if (ps !== null && pe !== null) pauses.push({ start: ps, end: pe });
    floor = pe ?? floor;
  });

  // The live durations (shown while editing, valid or not).
  const overlap = (a: number, b: number) =>
    pauses.reduce((sum, p) => sum + Math.max(0, Math.min(b, p.end) - Math.max(a, p.start)), 0);
  let laps = 0;
  let from = start;
  const segments = draft.segments.map((seg, i) => {
    const label =
      seg.kind === 'lap'
        ? `Lap ${String((laps += 1))}`
        : (byKey.get(seg.step ?? '')?.label ?? seg.step ?? 'Step');
    const end = ends[i] ?? null;
    let out: { label: string; active_ms: number | null; paused_ms: number | null } = {
      label,
      active_ms: null,
      paused_ms: null,
    };
    if (from !== null && end !== null && end >= from) {
      const paused = overlap(from, end);
      out = { label, active_ms: end - from - paused, paused_ms: paused };
    }
    from = end ?? from;
    return out;
  });
  const total = (k: 'active_ms' | 'paused_ms') =>
    segments.every((s) => s[k] !== null) ? segments.reduce((sum, s) => sum + (s[k] ?? 0), 0) : null;

  const valid = Object.keys(errors).length === 0 && start !== null;
  const order = steps.map((s) => s.key);
  const edit: TimingEdit | null = valid
    ? {
        started_at: formatInstant(start),
        segments: draft.segments.map((seg, i) => ({
          kind: seg.kind,
          step: seg.kind === 'step' ? seg.step : null,
          ended_at: formatInstant(ends[i] ?? 0),
        })),
        skipped: [...draft.skipped].sort((a, b) => order.indexOf(a) - order.indexOf(b)),
        pauses: pauses.map((p) => ({ start: formatInstant(p.start), end: formatInstant(p.end) })),
      }
    : null;
  return { errors, edit, segments, active_ms: total('active_ms'), paused_ms: total('paused_ms') };
}

/** A server field path (`timing.segments.0.ended_at`) as the form's, or null when it isn't one. */
export function timingFieldOf(path: string): FieldPath | null {
  if (path === 'timing') return '';
  return path.startsWith('timing.') ? path.slice('timing.'.length) : null;
}
