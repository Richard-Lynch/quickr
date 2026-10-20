import { useState } from 'react';

import type { SeriesPoint } from '../../client';
import { BARS_LAYOUT, stackSegments, stackedModel } from './chartModels';
import { formatBucket, useWidth, type Bucket } from './chartUtils';

interface Props {
  points: readonly SeriesPoint[];
  bucket: Bucket;
  /** Options in config order (colour follows the option). */
  options: readonly { value: string; label: string }[];
  colorFor: (value: string) => string;
  label: string;
}

/** Counts per option per bucket, stacked, with a legend and per-column tooltip. */
export function StackedBars({ points, bucket, options, colorFor, label }: Props) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [active, setActive] = useState<number | null>(null);
  const { height, pad, gap } = BARS_LAYOUT;
  const model = stackedModel(points, options, width);

  if (model === null) {
    return <p className="py-8 text-center text-sm text-muted">No answers in this range.</p>;
  }

  const { data, max, bw, offset, legend, labelled } = model;
  const plotH = height - pad.top - pad.bottom;
  const shown = active !== null ? data[active] : undefined;

  return (
    <div ref={ref} className="relative select-none">
      <svg
        width={width}
        height={height}
        role="img"
        aria-label={`${label}: answers per ${bucket}`}
        className="block touch-pan-y"
        onPointerLeave={() => setActive(null)}
      >
        <line
          x1={0}
          x2={width}
          y1={height - pad.bottom}
          y2={height - pad.bottom}
          className="stroke-line-strong"
        />
        {data.map((p, i) => {
          const x = offset + i * (bw + gap);
          let yCursor = height - pad.bottom;
          const segs = stackSegments(p, legend);
          return (
            <g
              key={p.start}
              onPointerEnter={() => setActive(i)}
              onPointerDown={() => setActive(i)}
              opacity={active === null || active === i ? 1 : 0.55}
            >
              <rect
                x={x - gap / 2}
                y={pad.top}
                width={bw + gap}
                height={plotH}
                fill="transparent"
              />
              {segs.map((s, si) => {
                const h = (s.n / max) * plotH;
                const yTop = yCursor - h;
                // 2px surface gap between stacked segments
                const drawH = Math.max(0, h - (si < segs.length - 1 ? 2 : 0));
                yCursor = yTop;
                return (
                  <rect
                    key={s.value}
                    x={x}
                    y={yTop + (h - drawH)}
                    width={bw}
                    height={drawH}
                    rx={si === segs.length - 1 ? Math.min(4, bw / 2) : 0}
                    fill={colorFor(s.value)}
                  />
                );
              })}
              {labelled.has(i) ? (
                <text
                  x={x + bw / 2}
                  y={height - 4}
                  textAnchor="middle"
                  className="fill-muted text-[10px]"
                >
                  {formatBucket(p.start, bucket)}
                </text>
              ) : null}
            </g>
          );
        })}
      </svg>
      {shown && active !== null ? (
        <div
          className="pointer-events-none absolute top-0 z-10 rounded-xl border border-line bg-surface px-3 py-2 text-xs shadow-float"
          style={{
            left: Math.min(Math.max(offset + active * (bw + gap) - 70, 0), width - 160),
            width: 160,
          }}
        >
          <p className="mb-1 font-semibold">{formatBucket(shown.start, bucket, 'long')}</p>
          {legend
            .filter((o) => (shown.option_counts[o.value] ?? 0) > 0)
            .map((o) => (
              <p key={o.value} className="flex items-center gap-1.5">
                <span className="size-2 rounded-full" style={{ background: colorFor(o.value) }} />
                <span className="flex-1 truncate">{o.label}</span>
                <span className="font-mono tabular">{shown.option_counts[o.value]}</span>
              </p>
            ))}
        </div>
      ) : null}
      {legend.length > 1 ? (
        <ul className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-ink-soft">
          {legend.map((o) => (
            <li key={o.value} className="flex items-center gap-1.5">
              <span className="size-2.5 rounded-full" style={{ background: colorFor(o.value) }} />
              {o.label}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
