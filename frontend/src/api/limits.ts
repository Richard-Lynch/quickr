/**
 * Server validation ceilings (`GET /api/v1/limits`), so client-side validation mirrors
 * the backend without hard-coding numbers in the forms.
 *
 * The query is cached (and persisted) for a long time; until it has loaded — first
 * launch offline — `FALLBACK_LIMITS` stands in. It is a snapshot of the server defaults,
 * only used for that first moment; the server stays the final word either way.
 */
import { useQuery } from '@tanstack/react-query';

import type { Limits } from '../client';
import { getLimitsOptions } from '../client/@tanstack/react-query.gen';

export const FALLBACK_LIMITS: Limits = {
  key_pattern: '^[a-z][a-z0-9_]{0,62}$',
  slug_pattern: '^[a-z0-9][a-z0-9-]{0,63}$',
  time_pattern: '^([01][0-9]|2[0-3]):[0-5][0-9]$',
  max_questions: 100,
  max_enum_options: 200,
  max_str_length: 10_000,
  max_label_length: 200,
  max_help_text_length: 1_000,
  max_unit_length: 32,
  max_decimals: 10,
  max_topic_name_length: 200,
  max_description_length: 5_000,
  max_change_note_length: 2_000,
  max_source_length: 100,
  max_notes_length: 5_000,
  max_meta_entries: 50,
  max_meta_key_length: 64,
  max_meta_value_length: 500,
  captured_at_min: '2000-01-01T00:00:00Z',
  captured_at_max_future_hours: 24,
  schedule_max_times: 24,
  interval_min_minutes: 15,
  interval_max_minutes: 129_600,
};

const DAY = 24 * 60 * 60 * 1000;

/** The server's limits (or the fallback until they have loaded). Never suspends. */
export function useLimits(): Limits {
  const q = useQuery({ ...getLimitsOptions(), staleTime: DAY, gcTime: 30 * DAY });
  return q.data ?? FALLBACK_LIMITS;
}

/** Compile a server pattern; a broken one falls back to the snapshot's. */
export function patternOf(pattern: string, fallback: string): RegExp {
  try {
    return new RegExp(pattern);
  } catch {
    return new RegExp(fallback);
  }
}
