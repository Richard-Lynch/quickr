import { useInfiniteQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router';

import { errorMessage } from '../api/errors';
import { listTopicsInfiniteOptions } from '../client/@tanstack/react-query.gen';
import type { ListTopicsData, TopicSummary } from '../client';
import { Page, TopBar } from '../components/AppShell';
import { InstallHint } from '../components/pwa/InstallHint';
import { TopicTile } from '../components/topics/TopicTile';
import { Button, ButtonLink } from '../components/ui/Button';
import { Banner, EmptyState } from '../components/ui/Card';
import { cn } from '../components/ui/cn';
import { Select } from '../components/ui/Field';
import { Icon } from '../components/ui/Icon';
import { Segmented } from '../components/ui/Segmented';
import { Skeleton } from '../components/ui/Spinner';
import { useDebounced, useNow } from '../lib/hooks';
import { plural } from '../lib/format';
import { NO_OPEN_RUNS, dueCount as countDue, splitByDue } from '../lib/home';

type Query = NonNullable<ListTopicsData['query']>;
type StatusFilter = NonNullable<Query['status']>;
type Sort = NonNullable<Query['sort']>;

const PAGE = 50;
/** Due state changes with the clock: refetch the list this often while it's on screen. */
const REFRESH_MS = 60_000;

const STATUS: { value: StatusFilter; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'archived', label: 'Archived' },
  { value: 'all', label: 'All' },
];

const SORTS: { value: Sort; label: string }[] = [
  { value: 'due', label: 'Due first' },
  { value: '-activity', label: 'Recent activity' },
  { value: '-updated', label: 'Recently edited' },
  { value: 'name', label: 'Name A–Z' },
  { value: '-name', label: 'Name Z–A' },
  { value: '-created', label: 'Newest' },
  { value: 'created', label: 'Oldest' },
];

function asStatus(v: string | null): StatusFilter {
  return v === 'archived' || v === 'all' ? v : 'active';
}
function asSort(v: string | null): Sort {
  return SORTS.find((s) => s.value === v)?.value ?? 'due';
}

export function TopicsPage() {
  const [params, setParams] = useSearchParams();
  const status = asStatus(params.get('status'));
  const sort = asSort(params.get('sort'));
  const [search, setSearch] = useState(params.get('q') ?? '');
  const [filtersOpen, setFiltersOpen] = useState(status !== 'active' || sort !== 'due');
  const q = useDebounced(search.trim(), 250);
  const now = useNow();

  const setParam = (key: string, value: string, fallback: string) => {
    setParams(
      (p) => {
        const next = new URLSearchParams(p);
        if (value === fallback) next.delete(key);
        else next.set(key, value);
        return next;
      },
      { replace: true },
    );
  };

  const query = useInfiniteQuery({
    ...listTopicsInfiniteOptions({
      query: { status, sort, limit: PAGE, ...(q ? { q } : {}) },
    }),
    initialPageParam: 0,
    getNextPageParam: (last) =>
      last.offset + last.items.length < last.total ? last.offset + last.items.length : undefined,
    refetchInterval: REFRESH_MS,
  });

  const items = useMemo(() => query.data?.pages.flatMap((p) => p.items) ?? [], [query.data]);
  const total = query.data?.pages[0]?.total ?? 0;
  const filtered = q !== '' || status !== 'active';
  const sectioned = sort === 'due' && !filtered;
  // No run data in the PWA yet: no topic has an open run.
  const sections = useMemo(() => splitByDue(items, now, NO_OPEN_RUNS), [items, now]);
  const dueCount = countDue(items, now, NO_OPEN_RUNS);

  return (
    <>
      <TopBar
        actions={
          <>
            <ButtonLink
              to="/new"
              variant="secondary"
              size="sm"
              icon={<Icon name="plus" className="size-4" />}
              aria-label="New topic"
              className="max-sm:size-10 max-sm:px-0"
            >
              <span className="max-sm:hidden">New topic</span>
            </ButtonLink>
            <ButtonLink
              to="/settings"
              variant="ghost"
              size="sm"
              aria-label="Settings"
              title="Settings"
              className="px-2.5"
            >
              <Icon name="settings" className="size-5" />
            </ButtonLink>
          </>
        }
      />
      <Page className="gap-4">
        <InstallHint />

        {query.isError ? (
          <Banner
            title="Could not load topics"
            action={
              <Button size="sm" onClick={() => void query.refetch()}>
                Retry
              </Button>
            }
          >
            {errorMessage(query.error)}
          </Banner>
        ) : null}

        {query.isPending && query.fetchStatus === 'paused' ? (
          <EmptyState title="You’re offline" icon={<Icon name="cloudOff" className="size-9" />}>
            Topics will appear here once you’re back online. Next time they’ll be saved on this
            device.
          </EmptyState>
        ) : query.isPending ? (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {Array.from({ length: 4 }, (_, i) => (
              <Skeleton key={i} className="h-32 rounded-card" />
            ))}
          </div>
        ) : query.isSuccess && items.length === 0 && !filtered ? (
          <EmptyState
            title="Track anything"
            icon={<Icon name="layers" className="size-9" />}
            action={
              <ButtonLink to="/new" variant="primary" size="lg" icon={<Icon name="plus" />}>
                Create your first topic
              </ButtonLink>
            }
          >
            A topic is a little form you fill in over and over — sleep, workouts, moods, plants.
            Every entry becomes data you can chart.
          </EmptyState>
        ) : (
          <>
            {sectioned ? (
              <Section
                title="Due now"
                count={dueCount}
                tone="accent"
                empty={
                  <p className="flex items-center gap-2 rounded-card border border-dashed border-line-strong px-4 py-3 text-sm text-muted">
                    <Icon name="check" className="size-4 text-ok" strokeWidth={2.6} />
                    Nothing due — you’re all caught up.
                  </p>
                }
              >
                <TileList topics={sections.due} now={now} />
              </Section>
            ) : null}

            <div className="flex flex-col gap-3 pt-1">
              <div className="flex items-center gap-2">
                <h1 className="font-display text-[1.6rem] leading-none font-bold tracking-tight sm:text-4xl">
                  {sectioned ? 'Topics' : 'All topics'}
                </h1>
                <span className="pt-1 text-sm text-muted">
                  {query.isSuccess
                    ? plural(total, status === 'archived' ? 'archived topic' : 'topic')
                    : ''}
                </span>
              </div>
              <div className="flex items-center gap-2">
                <label className="relative flex-1">
                  <span className="sr-only">Search topics</span>
                  <Icon
                    name="search"
                    className="pointer-events-none absolute top-1/2 left-3.5 size-4.5 -translate-y-1/2 text-muted"
                  />
                  <input
                    type="search"
                    value={search}
                    onChange={(e) => {
                      setSearch(e.target.value);
                      setParam('q', e.target.value.trim(), '');
                    }}
                    placeholder="Search topics and questions"
                    className="h-11 w-full rounded-full border border-line-strong bg-surface pr-4 pl-10 outline-none placeholder:text-muted/70 focus:border-accent focus:ring-3 focus:ring-accent/20"
                  />
                </label>
                <button
                  type="button"
                  aria-expanded={filtersOpen}
                  aria-controls="topic-filters"
                  aria-label="Filter and sort"
                  onClick={() => setFiltersOpen((o) => !o)}
                  className={cn(
                    'grid size-11 shrink-0 place-items-center rounded-full border transition-colors',
                    filtersOpen || status !== 'active' || sort !== 'due'
                      ? 'border-ink bg-ink text-paper'
                      : 'border-line-strong bg-surface text-ink-soft',
                  )}
                >
                  <Icon name="list" className="size-5" />
                </button>
              </div>
              {filtersOpen ? (
                <div id="topic-filters" className="flex animate-fade items-center gap-2">
                  <Segmented
                    label="Status"
                    value={status}
                    onChange={(v) => setParam('status', v, 'active')}
                    options={STATUS}
                  />
                  <div className="w-40 shrink-0 sm:w-48">
                    <Select
                      aria-label="Sort"
                      value={sort}
                      onChange={(e) => setParam('sort', asSort(e.target.value), 'due')}
                      className="h-10 rounded-full text-sm"
                    >
                      {SORTS.map((s) => (
                        <option key={s.value} value={s.value}>
                          {s.label}
                        </option>
                      ))}
                    </Select>
                  </div>
                </div>
              ) : null}
            </div>

            {items.length === 0 ? (
              <EmptyState title="No matches">Try another search or status filter.</EmptyState>
            ) : sectioned ? (
              <>
                {sections.upcoming.length > 0 ? (
                  <Section title="Coming up" count={sections.upcoming.length}>
                    <TileList topics={sections.upcoming} now={now} />
                  </Section>
                ) : null}
                {sections.other.length > 0 ? (
                  <Section
                    title={sections.upcoming.length > 0 ? 'Unscheduled' : 'All'}
                    count={sections.other.length}
                  >
                    <TileList topics={sections.other} now={now} />
                  </Section>
                ) : null}
              </>
            ) : (
              <TileList topics={items} now={now} />
            )}
          </>
        )}

        {query.hasNextPage ? (
          <div className="flex justify-center">
            <Button onClick={() => void query.fetchNextPage()} loading={query.isFetchingNextPage}>
              Load more
            </Button>
          </div>
        ) : null}
      </Page>
    </>
  );
}

function Section({
  title,
  count,
  tone,
  empty,
  children,
}: {
  title: string;
  count: number;
  tone?: 'accent';
  empty?: React.ReactNode;
  children: React.ReactNode;
}) {
  const id = `section-${title.toLowerCase().replace(/\W+/g, '-')}`;
  return (
    <section aria-labelledby={id} className="flex flex-col gap-2.5">
      <h2
        id={id}
        className={cn(
          'flex items-center gap-2 text-xs font-bold tracking-[0.12em] uppercase',
          tone === 'accent' ? 'text-accent-strong' : 'text-muted',
        )}
      >
        {tone === 'accent' && count > 0 ? (
          <span className="relative flex size-2">
            <span className="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60 motion-reduce:hidden" />
            <span className="relative inline-flex size-2 rounded-full bg-accent" />
          </span>
        ) : null}
        {title}
        <span className="font-mono font-semibold tabular">{count}</span>
      </h2>
      {count === 0 ? empty : children}
    </section>
  );
}

function TileList({ topics, now }: { topics: readonly TopicSummary[]; now: Date }) {
  return (
    <ul className="grid gap-2.5 sm:grid-cols-2 lg:grid-cols-3">
      {topics.map((t, i) => (
        <li
          key={t.id}
          className="animate-rise"
          style={{ animationDelay: `${Math.min(i, 8) * 30}ms` }}
        >
          <TopicTile topic={t} now={now} />
        </li>
      ))}
    </ul>
  );
}
