import { useState } from 'react';

import type { SeriesPoint } from '../../client';
import { formatNumber } from '../../lib/format';
import { LINE_LAYOUT, lineModel } from './chartModels';
import { formatBucket, formatTick, useWidth, type Bucket } from './chartUtils';

interface Props {
  points: readonly SeriesPoint[];
  bucket: Bucket;
  unit: string | null;
  label: string;
}

/**
 * Mean per bucket as a 2px line with a soft min–max band, plus a crosshair
 * tooltip that follows the pointer (or finger).
 */
export function LineChart({ points, bucket, unit, label }: Props) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [active, setActive] = useState<number | null>(null);
  const { height, pad } = LINE_LAYOUT;
  const model = lineModel(points, width);

  if (model === null) {
    return <p className="py-8 text-center text-sm text-muted">No answers in this range.</p>;
  }

  const { data, ticks, y, xs, labelled } = model;

  const line = data
    .map((p, i) => `${i === 0 ? 'M' : 'L'}${xs[i] ?? 0},${y(p.mean ?? 0)}`)
    .join(' ');
  const band =
    data.map((p, i) => `${i === 0 ? 'M' : 'L'}${xs[i] ?? 0},${y(p.max ?? p.mean ?? 0)}`).join(' ') +
    [...data]
      .reverse()
      .map((p, i) => `L${xs[data.length - 1 - i] ?? 0},${y(p.min ?? p.mean ?? 0)}`)
      .join(' ') +
    'Z';

  const nearest = (px: number) => {
    let best = 0;
    let dist = Infinity;
    xs.forEach((v, i) => {
      const d = Math.abs(v - px);
      if (d < dist) {
        dist = d;
        best = i;
      }
    });
    return best;
  };

  const shown = active !== null ? data[active] : undefined;
  const ax = active !== null ? xs[active] : undefined;
  const u = unit ? ` ${unit}` : '';

  return (
    <div ref={ref} className="relative select-none">
      <svg
        width={width}
        height={height}
        role="img"
        aria-label={`${label}: average per ${bucket}`}
        className="block touch-pan-y overflow-visible"
        onPointerMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          setActive(nearest(e.clientX - r.left));
        }}
        onPointerDown={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          setActive(nearest(e.clientX - r.left));
        }}
        onPointerLeave={() => setActive(null)}
      >
        {ticks.map((t) => (
          <g key={t}>
            <line
              x1={pad.left}
              x2={width - pad.right}
              y1={y(t)}
              y2={y(t)}
              className="stroke-line"
              strokeDasharray="2 4"
            />
            <text
              x={pad.left - 6}
              y={y(t)}
              dy="0.32em"
              textAnchor="end"
              className="fill-muted font-mono text-[10px]"
            >
              {formatTick(t)}
            </text>
          </g>
        ))}
        {data.length > 1 ? <path d={band} className="fill-accent/15" /> : null}
        {data.length > 1 ? (
          <path
            d={line}
            fill="none"
            className="stroke-accent"
            strokeWidth={2}
            strokeLinejoin="round"
            strokeLinecap="round"
          />
        ) : null}
        {data.map((p, i) =>
          labelled.has(i) ? (
            <text
              key={p.start}
              x={xs[i]}
              y={height - 4}
              textAnchor={
                i === 0 && data.length > 1
                  ? 'start'
                  : i === data.length - 1 && data.length > 1
                    ? 'end'
                    : 'middle'
              }
              className="fill-muted text-[10px]"
            >
              {formatBucket(p.start, bucket)}
            </text>
          ) : null,
        )}
        {data.length <= 40
          ? data.map((p, i) => (
              <circle
                key={p.start}
                cx={xs[i]}
                cy={y(p.mean ?? 0)}
                r={active === i ? 5 : 3.5}
                className="fill-accent stroke-surface"
                strokeWidth={2}
              />
            ))
          : null}
        {ax !== undefined && shown ? (
          <line
            x1={ax}
            x2={ax}
            y1={pad.top}
            y2={height - pad.bottom}
            className="stroke-ink/40"
            strokeWidth={1}
          />
        ) : null}
      </svg>
      {ax !== undefined && shown ? (
        <div
          className="pointer-events-none absolute top-0 z-10 rounded-xl border border-line bg-surface px-3 py-2 text-xs shadow-float"
          style={{ left: Math.min(Math.max(ax - 70, 0), width - 150), width: 150 }}
        >
          <p className="font-semibold">{formatBucket(shown.start, bucket, 'long')}</p>
          <p className="mt-0.5 font-mono tabular">
            avg <strong>{formatNumber(shown.mean)}</strong>
            {u}
          </p>
          <p className="font-mono text-muted tabular">
            {formatNumber(shown.min)}–{formatNumber(shown.max)} · n={shown.count}
          </p>
        </div>
      ) : null}
    </div>
  );
}
