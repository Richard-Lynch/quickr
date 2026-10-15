import { useSearchParams } from 'react-router';

import { isRangePreset, rangeStart, type RangePreset } from './dates';

export interface EntryFilterState {
  range: RangePreset;
  version: number | null;
  source: string | null;
}

/** Entry filters live in the URL so they survive tab switches and reloads. */
export function useEntryFilters(): [EntryFilterState, (patch: Partial<EntryFilterState>) => void] {
  const [params, setParams] = useSearchParams();
  const rawRange = params.get('range');
  const rawVersion = Number(params.get('version'));
  const state: EntryFilterState = {
    range: isRangePreset(rawRange) ? rawRange : '30d',
    version: Number.isInteger(rawVersion) && rawVersion > 0 ? rawVersion : null,
    source: params.get('source') || null,
  };
  const update = (patch: Partial<EntryFilterState>) => {
    setParams(
      (p) => {
        const next = new URLSearchParams(p);
        const merged = { ...state, ...patch };
        if (merged.range === '30d') next.delete('range');
        else next.set('range', merged.range);
        if (merged.version === null) next.delete('version');
        else next.set('version', String(merged.version));
        if (merged.source === null) next.delete('source');
        else next.set('source', merged.source);
        return next;
      },
      { replace: true },
    );
  };
  return [state, update];
}

/** API query params for the filters (shared by entries, stats, series, CSV). */
export function filterQuery(f: EntryFilterState, now?: Date) {
  const from = rangeStart(f.range, now);
  return {
    ...(from ? { captured_from: from } : {}),
    ...(f.version !== null ? { version: f.version } : {}),
    ...(f.source !== null ? { source: f.source } : {}),
  };
}

export function csvHref(slug: string, f: EntryFilterState): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(filterQuery(f))) q.set(k, String(v));
  const qs = q.toString();
  return `/api/v1/topics/${encodeURIComponent(slug)}/entries.csv${qs ? `?${qs}` : ''}`;
}
