/**
 * The entry summary line (docs/specs/content-display.md §1): one line of at most
 * `MAX_SUMMARY_LENGTH` grapheme clusters describing an entry, timing first, then
 * `label: value` per answered question, joined by `" · "`. A port of
 * `backend/app/services/summary.py`, pinned to the same text by
 * `shared/fixtures/entry-summary-vectors.json` (`entrySummary.vectors.test.ts`).
 */
import type { EntryOut, TimerOutput as Timer, Timing, TimingSegment } from '../client';
import type { Question } from './questions';
import { fmtDuration } from './runs/format';

export type StoredAnswer = EntryOut['answers'][number];

export const MAX_SUMMARY_LENGTH = 80;
export const SEPARATOR = ' · ';
export const ELLIPSIS = '…';
export const DEFAULT_DECIMALS = 3;

/**
 * A run of whitespace in a text answer: exactly Unicode `White_Space` (the vectors'
 * `meta.whitespace`). Not JS `\s`, which also has U+FEFF.
 */
const WHITE_SPACE = /\p{White_Space}+/gu;

const segmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });

/**
 * §1.2: the timing part (if timed), then `label: text` for each of the entry's version's
 * `questions` in their order (a key without a question is skipped, and so is an answer
 * without text), joined by `SEPARATOR` and truncated. `''` means "nothing to say"; callers
 * show their own fallback.
 */
export function entrySummary(
  answers: readonly StoredAnswer[],
  timing: Timing | null,
  questions: readonly Question[],
  timer: Timer | null,
): string {
  const parts: string[] = [];
  if (timing) parts.push(timingSummary(timing, timer));
  const byKey = new Map(answers.map((a) => [a.key, a]));
  for (const q of questions) {
    const a = byKey.get(q.key);
    if (!a) continue;
    const text = answerText(q, a);
    if (text) parts.push(`${q.label}: ${text}`);
  }
  return truncate(parts.join(SEPARATOR));
}

/**
 * `"12:40"`, `"12:40 · 3 laps"` or, with typed laps, `"12:40 · Run 3 · Rest 3"`: the active
 * duration, then the lap segments counted by type in the timer's declared order (then first
 * seen), the untyped remainder last. Pauses, steps and skips are not shown.
 */
export function timingSummary(timing: Timing, timer: Timer | null): string {
  const laps = timing.segments.filter((s) => s.kind === 'lap');
  return timingLine(timing.active_ms, laps.map(lapType), declaredLapTypes(timer));
}

/**
 * The timing part from the active time, each lap's type (null when untyped) and the timer's
 * `[key, label]` lap types in declared order.
 */
export function timingLine(
  activeMs: number,
  lapTypes: readonly (string | null)[],
  declared: readonly (readonly [key: string, label: string])[],
): string {
  let text = fmtDuration(activeMs);
  if (lapTypes.length === 0) return text;
  const typed = lapTypes.filter((t): t is string => Boolean(t));
  if (typed.length === 0) return `${text}${SEPARATOR}${lapCount(lapTypes.length)}`;
  // A key declared twice takes its last label, as the reference's `dict(...)` does.
  const labels = new Map(declared);
  const keys = new Set([...labels.keys(), ...typed].filter((k) => typed.includes(k)));
  for (const k of keys) {
    text += `${SEPARATOR}${labels.get(k) ?? k} ${typed.filter((t) => t === k).length}`;
  }
  const untyped = lapTypes.length - typed.length;
  if (untyped) text += `${SEPARATOR}${lapCount(untyped)}`;
  return text;
}

/**
 * One answer as display text, or null when there is nothing to show for it (an empty
 * selection, a blank string, or an answer whose shape doesn't fit the question).
 */
export function answerText(q: Question, a: StoredAnswer): string | null {
  switch (q.type) {
    case 'int':
      if (a.type !== 'int' && a.type !== 'double') return null;
      return withUnit(formatDecimal(a.value, 0), q.unit);
    case 'double':
      if (a.type !== 'int' && a.type !== 'double') return null;
      return withUnit(formatDecimal(a.value, q.decimals ?? DEFAULT_DECIMALS), q.unit);
    case 'enum':
      if (a.type === 'enum') return optionLabel(q, a.value);
      // A single-select that became multi-select keeps its old answers and the other way
      // round, so an enum question takes both shapes.
      if (a.type === 'enum_list') return a.value.map((v) => optionLabel(q, v)).join(', ') || null;
      return null;
    case 'str':
      if (a.type !== 'str') return null;
      return collapseWhitespace(a.value) || null;
  }
}

/** The extended grapheme clusters of `text` (UAX #29), the unit every client counts in. */
export function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), (s) => s.segment);
}

/**
 * Keep the first `MAX_SUMMARY_LENGTH - 1` clusters and append `…` when the line has more
 * than `MAX_SUMMARY_LENGTH`; no word boundary, and never inside a cluster (a flag, a keycap,
 * a ZWJ sequence or a base with combining marks stays whole).
 */
export function truncate(line: string): string {
  const clusters = graphemes(line);
  if (clusters.length <= MAX_SUMMARY_LENGTH) return line;
  return clusters.slice(0, MAX_SUMMARY_LENGTH - 1).join('') + ELLIPSIS;
}

const decimalFormats = new Map<number, Intl.NumberFormat>();

/**
 * `value` with at most `decimals` fraction digits, rounded half away from zero from its
 * shortest round-trip decimal (`Intl.NumberFormat` rounds the decimal `String(x)` prints, so
 * `1.005` is `1.01`), trailing zeros dropped, `.` as the point, no grouping. A negative value
 * that rounds to zero keeps its sign (`"-0"`), as the reference's `Decimal` does.
 */
export function formatDecimal(value: number, decimals: number): string {
  let format = decimalFormats.get(decimals);
  if (!format) {
    format = new Intl.NumberFormat('en-US', {
      maximumFractionDigits: decimals,
      useGrouping: false,
      roundingMode: 'halfExpand',
    });
    decimalFormats.set(decimals, format);
  }
  return format.format(value);
}

/** Runs of Unicode `White_Space` collapsed to one space, then trimmed of that space. */
export function collapseWhitespace(text: string): string {
  const collapsed = text.replace(WHITE_SPACE, ' ');
  return collapsed.slice(
    collapsed.startsWith(' ') ? 1 : 0,
    collapsed.endsWith(' ') ? -1 : undefined,
  );
}

function withUnit(text: string, unit: string | null | undefined): string {
  return unit ? `${text} ${unit}` : text;
}

/** Option label for a value (the raw value for an unknown or removed option). */
function optionLabel(q: Extract<Question, { type: 'enum' }>, value: string): string {
  return q.options.find((o) => o.value === value)?.label ?? value;
}

function lapCount(n: number): string {
  return n === 1 ? `${n} lap` : `${n} laps`;
}

// Lap types are M1's (timers2.md: `TimingSegment.lap_type`, `Timer.laps`), not in the
// generated client yet, so they are read as optional fields, as the reference reads them
// with `getattr`; until M1 lands every lap reads as untyped. M4-STATS turns these into plain
// field access when it adds the typed vectors; until then `timingLine`'s tests carry the rule.
function lapType(segment: TimingSegment): string | null {
  return (segment as { lap_type?: string | null }).lap_type ?? null;
}

function declaredLapTypes(timer: Timer | null): [string, string][] {
  const laps = (timer as { laps?: readonly { key: string; label: string }[] } | null)?.laps;
  return laps?.map((lt) => [lt.key, lt.label]) ?? [];
}
