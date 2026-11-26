import { useMemo } from 'react';

import type { TopicTiming } from '../../client';
import { fmtDuration } from '../../lib/runs/format';
import { plural } from '../../lib/format';
import { optionColors } from '../charts/EnumBars';
import { LineChart } from '../charts/LineChart';
import { StackedBars } from '../charts/StackedBars';
import type { Bucket } from '../charts/chartUtils';
import {
  durationTicks,
  lapTypeCards,
  lapTypesByBucket,
  stepBars,
  stepsByBucket,
  totalsByBucket,
} from '../charts/timingModels';
import { Badge, Card } from '../ui/Card';

const dur = (ms: number | null): string => (ms === null ? '—' : fmtDuration(ms));

/**
 * The Overview's Timing section for a timed topic (timers.md §9, §11.5), from
 * `getTopicTiming`: best, median and mean run time over complete runs only (OPEN 2), the run
 * total over time, each step's median and best with a stacked time-per-step chart, and laps
 * and paused time. Built from the same chart components as the question cards. A topic with
 * lap types (content-display.md §4.1) gets one card per type and a stacked time-per-type chart
 * in place of the v1 lap tiles, which stay for untyped laps.
 */
export function TimingOverview({ timing, bucket }: { timing: TopicTiming; bucket: Bucket }) {
  const totals = useMemo(() => totalsByBucket(timing.series, bucket), [timing.series, bucket]);
  const perStep = useMemo(() => stepsByBucket(timing.series, bucket), [timing.series, bucket]);
  const bars = stepBars(timing.steps);
  const colorFor = useMemo(() => optionColors(timing.steps.map((s) => s.key)), [timing.steps]);
  const options = timing.steps.map((s) => ({ value: s.key, label: s.label }));
  const lapCards = lapTypeCards(timing.lap_types);
  const perLapType = useMemo(
    () => lapTypesByBucket(timing.series, bucket),
    [timing.series, bucket],
  );
  const lapColorFor = useMemo(
    () => optionColors(timing.lap_types.map((t) => t.key)),
    [timing.lap_types],
  );
  const lapOptions = timing.lap_types.map((t) => ({ value: t.key, label: t.label }));

  return (
    <section aria-label="Timing" className="flex flex-col gap-3">
      <Card className="flex flex-col gap-4 p-4 sm:p-5">
        <header className="flex items-start gap-2">
          <div className="min-w-0 flex-1">
            <h3 className="font-display text-lg leading-tight font-semibold">Run time</h3>
            <p className="mt-0.5 text-xs text-muted" data-testid="complete-note">
              Best, median and mean over complete runs: {timing.complete_runs.toLocaleString()} of{' '}
              {plural(timing.runs, 'run')}
            </p>
          </div>
        </header>
        <div className="flex items-baseline gap-2">
          <span
            className="font-mono text-4xl leading-none font-bold tabular"
            data-testid="timing-median"
          >
            {dur(timing.total.median_ms)}
          </span>
          <span className="text-sm text-muted">median</span>
        </div>
        <dl className="grid grid-cols-3 gap-x-3 gap-y-2 rounded-xl bg-sunken/60 p-3 text-sm">
          {(
            [
              ['Best', timing.total.best_ms],
              ['Mean', timing.total.mean_ms],
              ['Runs', null],
            ] as const
          ).map(([k, v]) => (
            <div key={k} className="min-w-0">
              <dt className="text-[0.7rem] tracking-wide text-muted uppercase">{k}</dt>
              <dd
                className="truncate font-mono font-semibold tabular"
                data-testid={`timing-${k.toLowerCase()}`}
              >
                {k === 'Runs' ? timing.runs.toLocaleString() : dur(v)}
              </dd>
            </div>
          ))}
        </dl>
        <div>
          <p className="mb-1 text-xs font-semibold text-ink-soft">
            Average run per {bucket} (all runs)
          </p>
          <LineChart
            points={totals}
            bucket={bucket}
            unit={null}
            label="Run time"
            format={fmtDuration}
            ticker={durationTicks}
          />
        </div>
      </Card>

      {bars.length > 0 ? (
        <Card className="flex flex-col gap-4 p-4 sm:p-5">
          <h3 className="font-display text-lg leading-tight font-semibold">Steps</h3>
          <ul className="flex flex-col gap-2.5" aria-label="Steps">
            {bars.map((b) => (
              <li key={b.key} className="flex flex-col gap-1" data-testid={`step-${b.key}`}>
                <div className="flex items-baseline justify-between gap-3 text-sm">
                  <span className="flex min-w-0 items-center gap-2">
                    <span
                      className="size-2.5 shrink-0 rounded-full"
                      style={{ background: colorFor(b.key) }}
                    />
                    <span className={b.current ? 'truncate font-medium' : 'truncate text-muted'}>
                      {b.label}
                    </span>
                    {b.current ? null : <Badge tone="warn">retired</Badge>}
                  </span>
                  <span className="shrink-0 font-mono text-xs text-ink-soft tabular">
                    median <strong className="text-sm text-ink">{dur(b.median_ms)}</strong> · best{' '}
                    {dur(b.best_ms)}
                  </span>
                </div>
                <div
                  className="h-2.5 overflow-hidden rounded-full bg-sunken"
                  title={`${b.label}: median ${dur(b.median_ms)}`}
                >
                  <div
                    className="h-full rounded-full transition-[width] duration-500"
                    style={{ width: `${String(b.share * 100)}%`, background: colorFor(b.key) }}
                  />
                </div>
                <p className="text-xs text-muted">
                  {plural(b.done, 'run')}
                  {b.skipped > 0 ? ` · skipped ${b.skipped.toLocaleString()}×` : ''}
                </p>
              </li>
            ))}
          </ul>
          <div>
            <p className="mb-1 text-xs font-semibold text-ink-soft">Time per step, per {bucket}</p>
            <StackedBars
              points={perStep}
              bucket={bucket}
              options={options}
              colorFor={colorFor}
              label="Steps"
              format={fmtDuration}
              measure="time"
            />
          </div>
        </Card>
      ) : null}

      {lapCards.length > 0 ? (
        <Card className="flex flex-col gap-4 p-4 sm:p-5">
          <h3 className="font-display text-lg leading-tight font-semibold">Lap types</h3>
          <ul className="grid grid-cols-2 gap-3 sm:grid-cols-3" aria-label="Lap types">
            {lapCards.map((c) => (
              <li
                key={c.key}
                className="flex min-w-0 flex-col gap-1 rounded-xl bg-sunken/60 p-3"
                data-testid={`laptype-${c.key}`}
              >
                <span className="flex min-w-0 items-center gap-2 text-sm">
                  <span
                    className="size-2.5 shrink-0 rounded-full"
                    style={{ background: lapColorFor(c.key) }}
                  />
                  <span className="truncate font-medium">{c.label}</span>
                </span>
                <span className="text-xs text-muted">{c.laps}</span>
                <span className="flex items-baseline gap-1.5 pt-1">
                  <span
                    className="font-mono text-2xl leading-none font-bold tabular"
                    data-testid="laptype-median"
                  >
                    {c.median}
                  </span>
                  <span className="text-xs text-muted">median</span>
                </span>
                <span className="font-mono text-xs text-ink-soft tabular">
                  best <span data-testid="laptype-best">{c.best}</span> · mean{' '}
                  <span data-testid="laptype-mean">{c.mean}</span>
                </span>
              </li>
            ))}
          </ul>
          <div>
            <p className="mb-1 text-xs font-semibold text-ink-soft">
              Time per lap type, per {bucket}
            </p>
            <StackedBars
              points={perLapType}
              bucket={bucket}
              options={lapOptions}
              colorFor={lapColorFor}
              label="Lap types"
              format={fmtDuration}
              measure="time"
            />
          </div>
        </Card>
      ) : null}

      <Card className="grid grid-cols-2 gap-4 p-4 sm:grid-cols-4 sm:p-5">
        {lapCards.length > 0 ? null : (
          <>
            <Tile label="Runs with laps" value={timing.laps.runs_with_laps.toLocaleString()} />
            <Tile label="Lap time (median)" value={dur(timing.laps.median_ms)} />
          </>
        )}
        <Tile label="Runs with pauses" value={timing.paused.runs_with_pauses.toLocaleString()} />
        <Tile label="Paused (median)" value={dur(timing.paused.median_ms)} />
      </Card>
    </section>
  );
}

function Tile({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5">
      <span className="text-xs text-muted">{label}</span>
      <span className="truncate pt-1 font-mono text-[0.95rem] font-semibold tabular">{value}</span>
    </div>
  );
}
