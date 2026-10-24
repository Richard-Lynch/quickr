/**
 * The Edit times form's model (timers.md §3.8): a stopped run's times as editable text, the
 * `TimingEdit` a save sends, and the client-side checks that mirror the server's (T2–T5, the
 * run's steps, the 7-day limit). The server stays the final word: its 422 field paths
 * (`timing.segments.1.ended_at`…) land on the same fields as these checks.
 *
 * Times are edited as local wall time to the second (`datetime-local` with seconds). Each
 * field remembers its original text and millisecond: while its text is unchanged it sends that
 * exact millisecond; once edited, it sends the second it shows.
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

/** A field's original value: the text it opened with and the exact instant behind it. */
export interface Original {
  text: string;
  ms: number;
}

export interface TimingDraft {
  started_at: string;
  segments: DraftSegment[];
  /** Skipped step keys (any order; a save sends them in step order). */
  skipped: string[];
  pauses: DraftPause[];
  /**
   * Originals by field id: `started_at`, `{segment uid}.ended_at`, `{pause uid}.start` and
   * `{pause uid}.end`. A field whose text still equals its original's sends the original ms.
   */
  originals: Record<string, Original>;
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
  const originals: Record<string, Original> = {};
  const field = (id: string, iso: string): string => {
    const ms = parseInstant(iso);
    const text = toLocalSeconds(ms);
    originals[id] = { text, ms };
    return text;
  };
  const started_at = field('started_at', timing.started_at);
  const segments = timing.segments.map((s) => {
    const uid = nextUid('g');
    return { uid, kind: s.kind, step: s.step, ended_at: field(`${uid}.ended_at`, s.ended_at) };
  });
  const pauses = timing.pauses.map((p) => {
    const uid = nextUid('p');
    return { uid, start: field(`${uid}.start`, p.start), end: field(`${uid}.end`, p.end) };
  });
  return { started_at, segments, skipped: [...timing.skipped], pauses, originals };
}

/** The instant a field's text means: its original ms while unchanged, else the local time. */
function instantOf(draft: TimingDraft, id: string, text: string): number | null {
  const o = draft.originals[id];
  return o?.text === text ? o.ms : fromLocalInput(text);
}

/** The run's last end, as text and its original (so a copy of it keeps the exact ms). */
function lastEnd(draft: TimingDraft): { text: string; original: Original | undefined } {
  const last = draft.segments[draft.segments.length - 1];
  return last
    ? { text: last.ended_at, original: draft.originals[`${last.uid}.ended_at`] }
    : { text: draft.started_at, original: draft.originals.started_at };
}

/** Add a segment at the end, timing the first step not used yet, else a lap; zero length. */
export function withNewSegment(draft: TimingDraft, steps: readonly TimerStep[]): TimingDraft {
  const used = new Set(draft.segments.map((s) => s.step).filter((k) => k !== null));
  const free = steps.find((s) => !used.has(s.key));
  const { text, original } = lastEnd(draft);
  const uid = nextUid('g');
  return {
    ...draft,
    segments: [
      ...draft.segments,
      { uid, kind: free ? 'step' : 'lap', step: free?.key ?? null, ended_at: text },
    ],
    skipped: free ? draft.skipped.filter((k) => k !== free.key) : draft.skipped,
    originals: original ? { ...draft.originals, [`${uid}.ended_at`]: original } : draft.originals,
  };
}

/** Add a zero-length pause at the run's end, to be moved. */
export function withNewPause(draft: TimingDraft): TimingDraft {
  const { text, original } = lastEnd(draft);
  const uid = nextUid('p');
  return {
    ...draft,
    pauses: [...draft.pauses, { uid, start: text, end: text }],
    originals: original
      ? { ...draft.originals, [`${uid}.start`]: original, [`${uid}.end`]: original }
      : draft.originals,
  };
}

const MIN_INSTANT = Date.UTC(2000, 0, 1);
const MAX_AHEAD_MS = 24 * 60 * 60 * 1000;

/**
 * A note for a local time a clock change makes ambiguous (it happens twice: the earlier is
 * used) or skips (it doesn't exist: it reads as the time after the gap); null otherwise.
 */
export function localTimeNote(text: string): string | null {
  const ms = fromLocalInput(text);
  if (ms === null) return null;
  const wanted = text.length === 16 ? `${text}:00` : text;
  const shown = toLocalSeconds(ms);
  if (shown !== wanted)
    return `There is no ${wanted.slice(11)} that day (the clocks went forward): it reads as ${shown.slice(11)}.`;
  if (toLocalSeconds(ms + 3_600_000) === wanted || toLocalSeconds(ms - 3_600_000) === wanted)
    return `${wanted.slice(11)} happens twice that day (the clocks went back): the earlier one is used.`;
  return null;
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
 * rules are the server's (backend `edited_timing`, and the captured_at bounds at `now`), in
 * the client's own words: the first problem in each field is reported.
 */
export function checkTimingDraft(
  draft: TimingDraft,
  steps: readonly TimerStep[],
  now: number = Date.now(),
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

  // Every instant: a date and time within the captured_at bounds (sync-protocol.md §10).
  const read = (id: string, text: string, path: FieldPath): number | null => {
    const ms = instantOf(draft, id, text);
    if (ms === null) fail(path, 'Enter a date and time');
    else if (ms < MIN_INSTANT) fail(path, 'Must not be before 2000-01-01');
    else if (ms > now + MAX_AHEAD_MS) fail(path, 'Must not be more than 24 hours in the future');
    return ms;
  };

  const start = read('started_at', draft.started_at, 'started_at');
  if (draft.segments.length === 0) fail('segments', 'Keep at least one segment');

  const ends: (number | null)[] = [];
  let previous = start;
  draft.segments.forEach((seg, i) => {
    if (seg.kind === 'step') {
      if (seg.step === null) fail(`segments.${String(i)}.step`, 'Pick a step');
      else claim(seg.step, `segments.${String(i)}.step`);
    }
    const end = read(`${seg.uid}.ended_at`, seg.ended_at, `segments.${String(i)}.ended_at`);
    if (end !== null && previous !== null && end < previous)
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
    const ps = read(`${p.uid}.start`, p.start, `pauses.${String(i)}.start`);
    const pe = read(`${p.uid}.end`, p.end, `pauses.${String(i)}.end`);
    if (ps !== null && floor !== null && ps < floor)
      fail(`pauses.${String(i)}.start`, 'Before the run’s start or the previous pause’s end');
    if (pe !== null && ps !== null && pe < ps)
      fail(`pauses.${String(i)}.end`, 'Before the pause’s start');
    else if (pe !== null && runEnd !== null && pe > runEnd)
      fail(`pauses.${String(i)}.end`, 'After the run’s end');
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
