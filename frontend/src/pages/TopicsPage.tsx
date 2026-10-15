import { useInfiniteQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';

import { errorMessage } from '../api/errors';
import { listTopicsInfiniteOptions } from '../client/@tanstack/react-query.gen';
import type { ListTopicsData, TopicSummary } from '../client';
import { Page, TopBar } from '../components/AppShell';
import { Button, ButtonLink } from '../components/ui/Button';
import { Badge, Banner, Card, EmptyState, VersionTag } from '../components/ui/Card';
import { Select } from '../components/ui/Field';
import { Icon } from '../components/ui/Icon';
import { Segmented } from '../components/ui/Segmented';
import { Skeleton } from '../components/ui/Spinner';
import { formatRelative } from '../lib/dates';
import { useDebounced } from '../lib/hooks';
import { plural } from '../lib/format';

type Query = NonNullable<ListTopicsData['query']>;
type StatusFilter = NonNullable<Query['status']>;
type Sort = NonNullable<Query['sort']>;

const PAGE = 20;

const STATUS: { value: StatusFilter; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'archived', label: 'Archived' },
  { value: 'all', label: 'All' },
];

const SORTS: { value: Sort; label: string }[] = [
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
  return SORTS.find((s) => s.value === v)?.value ?? '-activity';
}

export function TopicsPage() {
  const [params, setParams] = useSearchParams();
  const status = asStatus(params.get('status'));
  const sort = asSort(params.get('sort'));
  const [search, setSearch] = useState(params.get('q') ?? '');
  const q = useDebounced(search.trim(), 250);

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
  });

  const items = query.data?.pages.flatMap((p) => p.items) ?? [];
  const total = query.data?.pages[0]?.total ?? 0;
  const filtered = q !== '' || status !== 'active';

  return (
    <>
      <TopBar
        actions={
          <ButtonLink
            to="/new"
            variant="primary"
            size="sm"
            className="max-sm:hidden"
            icon={<Icon name="plus" className="size-4" />}
          >
            New topic
          </ButtonLink>
        }
      />
      <Page>
        <div className="flex flex-col gap-1 pt-2">
          <h1 className="font-display text-[2rem] leading-none font-bold tracking-tight sm:text-5xl">
            Topics
          </h1>
          <p className="text-sm text-muted">
            {query.isSuccess
              ? plural(total, status === 'archived' ? 'archived topic' : 'topic')
              : ' '}
          </p>
        </div>

        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
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
              className="h-12 w-full rounded-full border border-line-strong bg-surface pr-4 pl-10 outline-none placeholder:text-muted/70 focus:border-accent focus:ring-3 focus:ring-accent/20"
            />
          </label>
          <div className="flex items-center gap-2">
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
                onChange={(e) => setParam('sort', asSort(e.target.value), '-activity')}
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
        </div>

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

        {query.isPending ? (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {Array.from({ length: 4 }, (_, i) => (
              <Skeleton key={i} className="h-40 rounded-card" />
            ))}
          </div>
        ) : query.isSuccess && items.length === 0 ? (
          filtered ? (
            <EmptyState title="No matches">Try another search or status filter.</EmptyState>
          ) : (
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
          )
        ) : (
          <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {items.map((t, i) => (
              <li
                key={t.id}
                className="animate-rise"
                style={{ animationDelay: `${Math.min(i, 8) * 35}ms` }}
              >
                <TopicCard topic={t} />
              </li>
            ))}
          </ul>
        )}

        {query.hasNextPage ? (
          <div className="flex justify-center">
            <Button onClick={() => void query.fetchNextPage()} loading={query.isFetchingNextPage}>
              Load more
            </Button>
          </div>
        ) : null}
      </Page>

      {/* FAB: thumb-reachable on phones */}
      <Link
        to="/new"
        aria-label="New topic"
        className="fixed right-4 bottom-[max(1.25rem,calc(env(safe-area-inset-bottom)+0.75rem))] z-20 grid size-16 place-items-center rounded-full bg-accent text-on-accent shadow-float transition-transform active:scale-95 sm:hidden"
      >
        <Icon name="plus" className="size-7" strokeWidth={2.4} />
      </Link>
    </>
  );
}

function TopicCard({ topic: t }: { topic: TopicSummary }) {
  const archived = t.status === 'archived';
  return (
    <Card className="group relative flex h-full flex-col gap-4 p-4 transition-[border-color,transform] hover:border-line-strong active:scale-[0.99]">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-xl leading-tight font-semibold tracking-tight">
            <Link to={`/t/${t.slug}`} className="after:absolute after:inset-0 after:rounded-card">
              {t.name}
            </Link>
          </h2>
          {t.description ? (
            <p className="mt-1 line-clamp-2 text-sm text-muted">{t.description}</p>
          ) : null}
        </div>
        <VersionTag version={t.current_version} />
      </div>

      <dl className="mt-auto grid grid-cols-3 gap-2 border-t border-dashed border-line pt-3 text-sm">
        <div>
          <dt className="text-xs text-muted">Entries</dt>
          <dd className="font-mono text-lg font-semibold tabular">
            {t.session_count.toLocaleString()}
          </dd>
        </div>
        <div>
          <dt className="text-xs text-muted">Questions</dt>
          <dd className="font-mono text-lg font-semibold tabular">{t.question_count}</dd>
        </div>
        <div>
          <dt className="text-xs text-muted">Last entry</dt>
          <dd className="truncate pt-1 text-[0.8rem] font-medium">
            {formatRelative(t.last_captured_at)}
          </dd>
        </div>
      </dl>

      <div className="relative z-10 flex items-center gap-2">
        {archived ? (
          <Badge tone="warn">
            <Icon name="archive" className="size-3.5" /> Archived
          </Badge>
        ) : (
          <ButtonLink
            to={`/t/${t.slug}/record`}
            variant="primary"
            size="sm"
            icon={<Icon name="plus" className="size-4" strokeWidth={2.6} />}
          >
            Record
          </ButtonLink>
        )}
        <ButtonLink to={`/t/${t.slug}/sessions`} variant="ghost" size="sm">
          Data
        </ButtonLink>
      </div>
    </Card>
  );
}
