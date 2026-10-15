import { useState } from 'react';

import type { HistogramBin } from '../../client';
import { formatNumber } from '../../lib/format';
import { formatTick, useWidth } from './chartUtils';

/** Vertical histogram; tap/hover a bar for its range + count. */
export function Histogram({
  bins,
  unit,
  label,
}: {
  bins: readonly HistogramBin[];
  unit: string | null;
  label: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [active, setActive] = useState<number | null>(null);
  const height = 120;
  const pad = { top: 6, bottom: 20 };
  const max = Math.max(1, ...bins.map((b) => b.count));
  const n = bins.length;
  const gap = 2;
  const bw = n > 0 ? (width - gap * (n - 1)) / n : 0;
  const plotH = height - pad.top - pad.bottom;
  const shown = active !== null ? bins[active] : undefined;
  const u = unit ? ` ${unit}` : '';

  if (n === 0) return null;
  const first = bins[0];
  const last = bins[n - 1];

  return (
    <div ref={ref} className="relative">
      <p className="mb-1 h-5 text-xs text-muted tabular" aria-live="polite">
        {shown
          ? `${formatNumber(shown.lower)}–${formatNumber(shown.upper)}${u}: ${shown.count.toLocaleString()}`
          : 'Distribution'}
      </p>
      <svg
        width={width}
        height={height}
        role="img"
        aria-label={`Histogram of ${label}`}
        onPointerLeave={() => setActive(null)}
        className="block touch-pan-y overflow-visible"
      >
        <line
          x1={0}
          x2={width}
          y1={height - pad.bottom}
          y2={height - pad.bottom}
          className="stroke-line-strong"
          strokeWidth={1}
        />
        {bins.map((b, i) => {
          const h = (b.count / max) * plotH;
          const x = i * (bw + gap);
          const y = height - pad.bottom - h;
          const r = Math.min(4, bw / 2, h);
          return (
            <g key={i} onPointerEnter={() => setActive(i)} onPointerDown={() => setActive(i)}>
              <rect x={x} y={pad.top} width={bw} height={plotH} fill="transparent" />
              {b.count > 0 ? (
                <path
                  d={`M${x},${y + h} V${y + r} Q${x},${y} ${x + r},${y} H${x + bw - r} Q${x + bw},${y} ${x + bw},${y + r} V${y + h} Z`}
                  className={active === i ? 'fill-accent-strong' : 'fill-accent'}
                />
              ) : null}
              <title>{`${formatNumber(b.lower)}–${formatNumber(b.upper)}${u}: ${b.count}`}</title>
            </g>
          );
        })}
        {first && last ? (
          <>
            <text x={0} y={height - 4} className="fill-muted text-[10px]">
              {formatTick(first.lower)}
            </text>
            <text x={width} y={height - 4} textAnchor="end" className="fill-muted text-[10px]">
              {formatTick(last.upper)}
              {u}
            </text>
          </>
        ) : null}
      </svg>
    </div>
  );
}
