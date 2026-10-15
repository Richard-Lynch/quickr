import type { EnumOptionCount } from '../../client';
import { formatPercent } from '../../lib/format';
import { OTHER_COLOR, SERIES } from './chartUtils';

/**
 * Horizontal bars, one per option, labelled directly with count + share.
 * Colour follows the option's position in the question config.
 */
export function EnumBars({
  options,
  colorFor,
}: {
  options: readonly EnumOptionCount[];
  colorFor: (value: string) => string;
}) {
  const max = Math.max(1, ...options.map((o) => o.count));
  return (
    <ul className="flex flex-col gap-2.5">
      {options.map((o) => (
        <li key={o.value} className="flex flex-col gap-1">
          <div className="flex items-baseline justify-between gap-3 text-sm">
            <span className="flex min-w-0 items-center gap-2">
              <span
                className="size-2.5 shrink-0 rounded-full"
                style={{ background: colorFor(o.value) }}
              />
              <span
                className={
                  o.archived
                    ? 'truncate text-muted line-through decoration-1'
                    : 'truncate font-medium'
                }
              >
                {o.label}
              </span>
            </span>
            <span className="shrink-0 font-mono text-xs text-ink-soft tabular">
              <strong className="text-sm text-ink">{o.count.toLocaleString()}</strong> ·{' '}
              {formatPercent(o.share)}
            </span>
          </div>
          <div
            className="h-2.5 overflow-hidden rounded-full bg-sunken"
            title={`${o.label}: ${o.count} (${formatPercent(o.share)})`}
          >
            <div
              className="h-full rounded-full transition-[width] duration-500"
              style={{ width: `${(o.count / max) * 100}%`, background: colorFor(o.value) }}
            />
          </div>
        </li>
      ))}
    </ul>
  );
}

/** Stable colour per option value: config order, first 6 slots, rest "other". */
export function optionColors(values: readonly string[]): (value: string) => string {
  const map = new Map(values.map((v, i) => [v, SERIES[i] ?? OTHER_COLOR]));
  return (v) => map.get(v) ?? OTHER_COLOR;
}
