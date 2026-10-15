/**
 * Validation of an entry's metadata (captured_at / source / notes), mirroring
 * `EntryCreate` / `EntryUpdate` on the server with the ceilings from `GET /limits`.
 */
import { z } from 'zod';

import type { Limits } from '../client';
import { zEntryCreate } from '../client/zod.gen';
import { localInputToIso } from './dates';

/** Why a capture time would be rejected by the server, or null when it's fine. */
export function capturedAtIssue(
  iso: string,
  limits: Limits,
  now: Date = new Date(),
): string | null {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return 'Pick a date and time';
  if (t < Date.parse(limits.captured_at_min)) {
    return `Can’t be before ${new Date(limits.captured_at_min).getFullYear().toString()}`;
  }
  const maxH = limits.captured_at_max_future_hours;
  if (t > now.getTime() + maxH * 3_600_000) {
    return `Can’t be more than ${String(maxH)} hours in the future`;
  }
  return null;
}

/** `datetime-local` value -> timezone-aware ISO string, validated. */
export function capturedAtSchema(limits: Limits, now: () => Date = () => new Date()) {
  return z
    .string()
    .transform((v, ctx) => {
      const iso = localInputToIso(v);
      const problem = iso === null ? 'Pick a date and time' : capturedAtIssue(iso, limits, now());
      if (iso === null || problem) {
        ctx.addIssue({ code: 'custom', message: problem ?? 'Pick a date and time' });
        return z.NEVER;
      }
      return iso;
    })
    .pipe(zEntryCreate.shape.captured_at.unwrap().unwrap());
}

export function sourceSchema(limits: Limits) {
  return z
    .string()
    .trim()
    .min(1, 'Where did this come from? (e.g. phone)')
    .max(limits.max_source_length, `At most ${String(limits.max_source_length)} characters`);
}

export function notesSchema(limits: Limits) {
  return z
    .string()
    .trim()
    .max(limits.max_notes_length, `At most ${String(limits.max_notes_length)} characters`);
}
