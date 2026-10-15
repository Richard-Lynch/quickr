import type { ReactNode } from 'react';

import { RANGE_PRESETS } from '../lib/dates';
import type { EntryFilterState } from '../lib/filters';
import { Select } from './ui/Field';
import { Segmented } from './ui/Segmented';

interface FilterBarProps {
  filters: EntryFilterState;
  onChange: (patch: Partial<EntryFilterState>) => void;
  versions?: readonly number[];
  sources?: readonly string[];
  children?: ReactNode;
}

export function FilterBar({ filters, onChange, versions, sources, children }: FilterBarProps) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Segmented
        label="Date range"
        value={filters.range}
        onChange={(range) => onChange({ range })}
        options={RANGE_PRESETS}
      />
      {versions && versions.length > 1 ? (
        <div className="w-36">
          <Select
            aria-label="Version"
            value={filters.version ?? ''}
            onChange={(e) => onChange({ version: e.target.value ? Number(e.target.value) : null })}
            className="h-10 rounded-full text-sm"
          >
            <option value="">All versions</option>
            {versions.map((v) => (
              <option key={v} value={v}>
                v{v}
              </option>
            ))}
          </Select>
        </div>
      ) : null}
      {sources && (sources.length > 1 || filters.source !== null) ? (
        <div className="w-36">
          <Select
            aria-label="Source"
            value={filters.source ?? ''}
            onChange={(e) => onChange({ source: e.target.value || null })}
            className="h-10 rounded-full text-sm"
          >
            <option value="">All sources</option>
            {[...new Set([...(filters.source ? [filters.source] : []), ...sources])].map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </Select>
        </div>
      ) : null}
      {children}
    </div>
  );
}
