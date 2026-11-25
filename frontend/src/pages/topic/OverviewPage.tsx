import { useQuery } from '@tanstack/react-query';
import { useEffect, useMemo, useState, type RefObject } from 'react';

import { errorMessage } from '../../api/errors';
import {
  getQuestionSeriesOptions,
  getTopicStatsOptions,
  getTopicTimingOptions,
  listEntriesOptions,
  listTopicVersionsOptions,
} from '../../client/@tanstack/react-query.gen';
import type { EnumStats, NumericStats, StrStats, TopicStats } from '../../client';
import { defaultBucket, enumView } from '../../components/charts/chartModels';
import { useWidth, type Bucket } from '../../components/charts/chartUtils';
import { EnumBars, optionColors } from '../../components/charts/EnumBars';
import { Histogram } from '../../components/charts/Histogram';
import { LineChart } from '../../components/charts/LineChart';
import { StackedBars } from '../../components/charts/StackedBars';
import {
  ACTIVITY_WEEKS,
  activityLevel,
  activityStrip,
  localDay,
  localMidnight,
  SPARK_LAYOUT,
  sparkline,
} from '../../components/charts/timingModels';
import { FilterBar } from '../../components/FilterBar';
import { TimingOverview } from '../../components/runs/TimingOverview';
import { ButtonLink } from '../../components/ui/Button';
import { Badge, Banner, Card, EmptyState } from '../../components/ui/Card';
import { Icon } from '../../components/ui/Icon';
import { Segmented } from '../../components/ui/Segmented';
import { Skeleton } from '../../components/ui/Spinner';
import { browserTimeZone, formatDate, formatRelative, type RangePreset } from '../../lib/dates';
import { filterQuery, useEntryFilters, type EntryFilterState } from '../../lib/filters';
import { formatNumber, formatPercent, plural } from '../../lib/format';
import { useNow } from '../../lib/hooks';
import type { Question } from '../../lib/questions';
import { useTopic } from './TopicLayout';

const BUCKETS: { value: Bucket; label: string }[] = [
  { value: 'day', label: 'Day' },
  { value: 'week', label: 'Week' },
  { value: 'month', label: 'Month' },
];

export function OverviewPage() {
  const topic = useTopic();
  const [filters, setFilters] = useEntryFilters();
  const [bucketChoice, setBucket] = useState<{ range: RangePreset; bucket: Bucket } | null>(null);
  const bucket =
    bucketChoice?.range === filters.range ? bucketChoice.bucket : defaultBucket(filters.range);
  const stats = useQuery(
    getTopicStatsOptions({ path: { ref: topic.slug }, query: filterQuery(filters) }),
  );
  const allStats = useQuery(getTopicStatsOptions({ path: { ref: topic.slug } }));
  // Timed topics: the Timing section (an untimed topic answers with zero runs).
  const timing = useQuery(
    getTopicTimingOptions({ path: { ref: topic.slug }, query: filterQuery(filters) }),
  );
  // Timed now: the section keeps its place while loading and says when the range has no runs.
  const versions = useQuery(listTopicVersionsOptions({ path: { ref: topic.slug } }));
  const timed = versions.data?.find((v) => v.version === topic.current_version)?.timer != null;
  const byKey = useMemo(() => new Map(topic.questions.map((q) => [q.key, q])), [topic.questions]);

  return (
    <>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <FilterBar
          filters={filters}
          onChange={setFilters}
          sources={allStats.data?.sources.map((s) => s.value) ?? []}
        />
        <Segmented
          label="Chart bucket"
          value={bucket}
          onChange={(b) => setBucket({ range: filters.range, bucket: b })}
          options={BUCKETS}
        />
      </div>

      {stats.isError ? (
        <Banner title="Could not load stats">{errorMessage(stats.error)}</Banner>
      ) : stats.isPending ? (
        <div className="grid gap-3 md:grid-cols-2">
          <Skeleton className="h-24 rounded-card md:col-span-2" />
          <Skeleton className="h-72 rounded-card" />
          <Skeleton className="h-72 rounded-card" />
        </div>
      ) : stats.data.entry_count === 0 ? (
        <>
          {/* The strip ignores the range and filters: an empty range still has a last 12 weeks. */}
          {topic.entry_count > 0 ? <Activity slug={topic.slug} /> : null}
          <EmptyState
            title={topic.entry_count === 0 ? 'No data yet' : 'Nothing in this range'}
            icon={<Icon name="chart" className="size-9" />}
            action={
              topic.entry_count === 0 && topic.status === 'active' ? (
                <ButtonLink
                  to={`/t/${topic.slug}/record`}
                  variant="primary"
                  icon={<Icon name="plus" />}
                >
                  Log the first entry
                </ButtonLink>
              ) : null
            }
          >
            {topic.entry_count === 0
              ? 'Charts and stats appear as soon as you log an entry.'
              : 'Try a wider date range.'}
          </EmptyState>
        </>
      ) : (
        <>
          <Summary stats={stats.data} />
          <Activity slug={topic.slug} />
          {timing.isError ? (
            <Banner title="Could not load timing">{errorMessage(timing.error)}</Banner>
          ) : timing.data && timing.data.runs > 0 ? (
            <TimingOverview timing={timing.data} bucket={bucket} />
          ) : !timed ? null : timing.isPending ? (
            <Skeleton className="h-72 rounded-card" />
          ) : (
            <Card className="p-4 sm:p-5" role="region" aria-label="Timing">
              <h3 className="font-display text-lg leading-tight font-semibold">Run time</h3>
              <p className="mt-1 text-sm text-muted">
                No runs in this range. Start one from the topic, or try a wider range.
              </p>
            </Card>
          )}
          <div className="grid gap-3 md:grid-cols-2">
            {stats.data.questions.map((qs, i) => (
              <div
                key={qs.key}
                className="animate-rise"
                style={{ animationDelay: `${Math.min(i, 8) * 40}ms` }}
              >
                <QuestionCard
                  stats={qs}
                  question={byKey.get(qs.key)}
                  slug={topic.slug}
                  filters={filters}
                  bucket={bucket}
                />
              </div>
            ))}
          </div>
        </>
      )}
    </>
  );
}

function Summary({ stats }: { stats: TopicStats }) {
  return (
    <Card className="grid grid-cols-2 gap-4 p-4 sm:grid-cols-4 sm:p-5">
      <Tile label="Entries" value={stats.entry_count.toLocaleString()} big />
      <Tile label="Latest" value={formatRelative(stats.last_captured_at)} />
      <Tile
        label="First"
        value={stats.first_captured_at ? formatDate(stats.first_captured_at) : '—'}
      />
      <div className="flex flex-col gap-1">
        <span className="text-xs text-muted">Sources</span>
        <div className="flex flex-wrap gap-1">
          {stats.sources.slice(0, 4).map((s) => (
            <Badge key={s.value}>
              {s.value} <span className="font-mono opacity-70">{s.count}</span>
            </Badge>
          ))}
        </div>
      </div>
    </Card>
  );
}

function Tile({ label, value, big }: { label: string; value: string; big?: boolean }) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5">
      <span className="text-xs text-muted">{label}</span>
      <span
        className={
          big
            ? 'font-mono text-3xl leading-none font-bold tabular'
            : 'truncate pt-1 text-[0.95rem] font-semibold'
        }
      >
        {value}
      </span>
    </div>
  );
}

interface CardProps {
  stats: TopicStats['questions'][number];
  question: Question | undefined;
  slug: string;
  filters: EntryFilterState;
  bucket: Bucket;
}

function QuestionCard({ stats, question, slug, filters, bucket }: CardProps) {
  const answered = stats.count;
  const totalN = stats.count + stats.missing;
  return (
    <Card className="flex h-full flex-col gap-4 p-4 sm:p-5">
      <header className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <h3 className="font-display text-lg leading-tight font-semibold">{stats.label}</h3>
          <p className="mt-0.5 font-mono text-xs text-muted">{stats.key}</p>
        </div>
        {!question ? <Badge tone="warn">retired</Badge> : null}
        <Badge tone="neutral" className="font-mono">
          {answered}/{totalN}
        </Badge>
      </header>
      {stats.type === 'enum' ? (
        <EnumCard stats={stats} slug={slug} filters={filters} bucket={bucket} />
      ) : stats.type === 'str' ? (
        <StrCard stats={stats} />
      ) : (
        <NumericCard
          stats={stats}
          unit={
            question && (question.type === 'int' || question.type === 'double')
              ? question.unit
              : null
          }
          slug={slug}
          filters={filters}
          bucket={bucket}
        />
      )}
    </Card>
  );
}

function useSeries(slug: string, key: string, filters: EntryFilterState, bucket: Bucket) {
  return useQuery(
    getQuestionSeriesOptions({
      path: { ref: slug, key },
      query: { ...filterQuery(filters), bucket, tz: browserTimeZone() },
    }),
  );
}

function NumericCard({
  stats,
  unit,
  slug,
  filters,
  bucket,
}: {
  stats: NumericStats;
  unit: string | null;
  slug: string;
  filters: EntryFilterState;
  bucket: Bucket;
}) {
  const series = useSeries(slug, stats.key, filters, bucket);
  const dec = stats.type === 'int' ? 1 : 2;
  const u = unit ? ` ${unit}` : '';
  return (
    <>
      <div className="flex items-center gap-3">
        <div className="flex shrink-0 items-baseline gap-2">
          <span className="font-mono text-4xl leading-none font-bold tabular">
            {formatNumber(stats.mean, dec)}
          </span>
          <span className="text-sm text-muted">avg{u}</span>
        </div>
        <Sparkline slug={slug} questionKey={stats.key} label={stats.label} filters={filters} />
      </div>
      <dl className="grid grid-cols-3 gap-x-3 gap-y-2 rounded-xl bg-sunken/60 p-3 text-sm sm:grid-cols-5">
        {(
          [
            ['Median', stats.median],
            ['Min', stats.min],
            ['Max', stats.max],
            ['Std dev', stats.stddev],
            ['Sum', stats.sum],
          ] as const
        ).map(([k, v]) => (
          <div key={k} className="min-w-0">
            <dt className="text-[0.7rem] tracking-wide text-muted uppercase">{k}</dt>
            <dd className="truncate font-mono font-semibold tabular">{formatNumber(v, dec)}</dd>
          </div>
        ))}
      </dl>
      {stats.histogram.length > 0 ? (
        <Histogram bins={stats.histogram} unit={unit} label={stats.label} />
      ) : null}
      <div>
        <p className="mb-1 text-xs font-semibold text-ink-soft">Average per {bucket}</p>
        {series.isPending ? (
          <Skeleton className="h-40" />
        ) : series.isError ? (
          <p className="text-sm text-danger">{errorMessage(series.error)}</p>
        ) : (
          <LineChart points={series.data.points} bucket={bucket} unit={unit} label={stats.label} />
        )}
      </div>
    </>
  );
}

/** True once `ref` has been on screen (always true without `IntersectionObserver`). */
function useSeen(ref: RefObject<Element | null>): boolean {
  const [seen, setSeen] = useState(() => typeof IntersectionObserver === 'undefined');
  useEffect(() => {
    const el = ref.current;
    if (seen || !el) return;
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) setSeen(true);
    });
    io.observe(el);
    return () => io.disconnect();
  }, [ref, seen]);
  return seen;
}

/**
 * A numeric card's trend (content-display.md §4.3): the means per default bucket of the range,
 * the last point marked, max and min as end labels. Its query waits until the card is on
 * screen.
 */
function Sparkline({
  slug,
  questionKey,
  label,
  filters,
}: {
  slug: string;
  questionKey: string;
  label: string;
  filters: EntryFilterState;
}) {
  const [ref, width] = useWidth<HTMLDivElement>(160);
  const seen = useSeen(ref);
  const series = useQuery({
    ...getQuestionSeriesOptions({
      path: { ref: slug, key: questionKey },
      query: {
        ...filterQuery(filters),
        bucket: defaultBucket(filters.range),
        tz: browserTimeZone(),
      },
    }),
    staleTime: 5 * 60_000,
    enabled: seen,
  });
  const model = series.data ? sparkline(series.data.points, width) : null;
  const { height, pad } = SPARK_LAYOUT;
  return (
    <div className="flex min-w-0 flex-1 items-stretch gap-1.5">
      <div ref={ref} className="min-w-0 flex-1" data-testid={`sparkline-${questionKey}`}>
        {model ? (
          <svg
            width={width}
            height={height}
            role="img"
            aria-label={`${label}: trend, last ${formatNumber(model.last.value)}`}
            className="block overflow-visible"
          >
            <polyline
              points={model.path.map(([x, y]) => `${x},${y}`).join(' ')}
              fill="none"
              className="stroke-accent"
              strokeWidth={1.5}
              strokeLinejoin="round"
              strokeLinecap="round"
            />
            <circle
              cx={model.last.x}
              cy={model.last.y}
              r={pad - 1}
              className="fill-accent stroke-surface"
              strokeWidth={1.5}
            />
          </svg>
        ) : series.isError ? (
          <p
            className="flex items-center text-xs text-danger"
            style={{ height }}
            title={errorMessage(series.error)}
          >
            Trend unavailable
          </p>
        ) : series.isPending && seen ? (
          <Skeleton className="h-12" />
        ) : (
          <div style={{ height }} />
        )}
      </div>
      {model ? (
        <div className="flex shrink-0 flex-col justify-between py-0.5 text-right font-mono text-[0.65rem] leading-none text-muted tabular">
          <span data-testid="sparkline-max">{formatNumber(model.max)}</span>
          <span data-testid="sparkline-min">{formatNumber(model.min)}</span>
        </div>
      ) : null}
    </div>
  );
}

const ACTIVITY_LIMIT = 500;
const LEVEL_CLASS = ['bg-sunken', 'bg-accent/35', 'bg-accent/65', 'bg-accent'] as const;
const cellDate = new Intl.DateTimeFormat(undefined, {
  weekday: 'short',
  day: 'numeric',
  month: 'short',
  timeZone: 'UTC',
});

/**
 * Entries per local day over the last 12 Monday-started weeks (content-display.md §4.2), from
 * the entries themselves: one `listEntries` from the first cell's local midnight. Not
 * filtered by the range or the filters.
 */
function Activity({ slug }: { slug: string }) {
  const tz = browserTimeZone();
  // Ticks each minute, so the strip moves on at midnight.
  const today = localDay(useNow(60_000).getTime(), tz);
  // Only the cells' shape matters for the query bound: it changes once a day.
  const firstDay = activityStrip([], today, tz).firstDay;
  const entries = useQuery(
    listEntriesOptions({
      path: { ref: slug },
      query: {
        captured_from: new Date(localMidnight(firstDay, tz)).toISOString(),
        limit: ACTIVITY_LIMIT,
        order: '-captured_at',
      },
    }),
  );
  const strip = useMemo(
    () =>
      entries.data
        ? activityStrip(
            entries.data.items.map((e) => new Date(e.captured_at).getTime()),
            today,
            tz,
          )
        : null,
    [entries.data, today, tz],
  );
  const caption = !strip
    ? null
    : (entries.data?.total ?? 0) > ACTIVITY_LIMIT
      ? `Showing the last ${String(ACTIVITY_LIMIT)} entries`
      : `${plural(strip.total, 'entry', 'entries')} in the last ${String(ACTIVITY_WEEKS)} weeks`;
  return (
    <Card className="p-4 sm:p-5" role="region" aria-label="Activity">
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="font-display text-lg leading-tight font-semibold">Activity</h3>
        {caption ? (
          <p className="text-xs text-muted" data-testid="activity-caption">
            {caption}
          </p>
        ) : null}
      </div>
      {entries.isError ? (
        <p className="mt-2 text-sm text-danger">{errorMessage(entries.error)}</p>
      ) : !strip ? (
        <Skeleton className="mt-3 h-28 max-w-md" />
      ) : (
        <div
          role="img"
          aria-label={caption ?? 'Activity'}
          className="mt-3 grid max-w-md grid-flow-col grid-cols-12 grid-rows-7 gap-1"
        >
          {Array.from({ length: ACTIVITY_WEEKS * 7 }, (_, i) => {
            const cell = strip.cells[i];
            if (!cell) return <span key={i} className="aspect-square" />;
            return (
              <span
                key={cell.day}
                data-testid="activity-cell"
                data-day={cell.day}
                data-count={cell.count}
                title={`${cellDate.format(new Date(`${cell.day}T00:00:00Z`))}: ${plural(cell.count, 'entry', 'entries')}`}
                className={`aspect-square rounded-[3px] ${LEVEL_CLASS[activityLevel(cell.count)]} ${
                  cell.day === today ? 'outline-2 outline-offset-1 outline-ink' : ''
                }`}
              />
            );
          })}
        </div>
      )}
    </Card>
  );
}

function EnumCard({
  stats,
  slug,
  filters,
  bucket,
}: {
  stats: EnumStats;
  slug: string;
  filters: EntryFilterState;
  bucket: Bucket;
}) {
  const series = useSeries(slug, stats.key, filters, bucket);
  const colorFor = useMemo(() => optionColors(stats.options.map((o) => o.value)), [stats.options]);
  const { visible, top } = enumView(stats);
  return (
    <>
      {top ? (
        <p className="text-sm text-muted">
          Most often <strong className="text-ink">{top.label}</strong> ({formatPercent(top.share)}
          {stats.multiple ? ' of entries' : ''})
        </p>
      ) : null}
      {stats.multiple ? (
        <p className="-mt-2 flex items-center gap-1.5 text-xs text-muted">
          <Badge tone="info">multi-select</Badge>
          Share of entries that picked each option — can add up to more than 100%.
        </p>
      ) : null}
      <EnumBars options={visible} colorFor={colorFor} />
      <div>
        <p className="mb-1 text-xs font-semibold text-ink-soft">
          {stats.multiple ? 'Selections' : 'Answers'} per {bucket}
        </p>
        {series.isPending ? (
          <Skeleton className="h-40" />
        ) : series.isError ? (
          <p className="text-sm text-danger">{errorMessage(series.error)}</p>
        ) : (
          <StackedBars
            points={series.data.points}
            bucket={bucket}
            options={stats.options}
            colorFor={colorFor}
            label={stats.label}
          />
        )}
      </div>
    </>
  );
}

function StrCard({ stats }: { stats: StrStats }) {
  const maxTop = Math.max(1, ...stats.top.map((t) => t.count));
  return (
    <>
      <p className="text-sm text-muted">{plural(stats.distinct, 'distinct answer')}</p>
      {stats.top.some((t) => t.count > 1) ? (
        <div>
          <p className="mb-2 text-xs font-semibold text-ink-soft">Most common</p>
          <ul className="flex flex-col gap-1.5">
            {stats.top.slice(0, 5).map((t) => (
              <li
                key={t.value}
                className="relative overflow-hidden rounded-lg bg-sunken/60 px-3 py-1.5 text-sm"
              >
                <span
                  className="absolute inset-y-0 left-0 bg-accent/12"
                  style={{ width: `${(t.count / maxTop) * 100}%` }}
                />
                <span className="relative flex justify-between gap-3">
                  <span className="truncate">{t.value}</span>
                  <span className="font-mono text-xs text-ink-soft tabular">{t.count}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      <div>
        <p className="mb-2 text-xs font-semibold text-ink-soft">Recent</p>
        {stats.recent.length === 0 ? (
          <p className="text-sm text-muted">No answers in this range.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-dashed divide-line">
            {stats.recent.slice(0, 5).map((r) => (
              <li key={r.entry_id + r.captured_at} className="py-2">
                <p className="line-clamp-3 text-sm whitespace-pre-line">{r.value}</p>
                <p className="mt-0.5 text-xs text-muted">{formatRelative(r.captured_at)}</p>
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  );
}
