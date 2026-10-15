import { useQuery } from '@tanstack/react-query';
import {
  NavLink,
  Outlet,
  useLocation,
  useOutletContext,
  useParams,
  useSearchParams,
} from 'react-router';

import { errorMessage } from '../../api/errors';
import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { Button, ButtonLink } from '../../components/ui/Button';
import { Badge, Banner, EmptyState, VersionTag } from '../../components/ui/Card';
import { cn } from '../../components/ui/cn';
import { Icon } from '../../components/ui/Icon';
import { PageSpinner } from '../../components/ui/Spinner';
import { formatRelative } from '../../lib/dates';
import { plural } from '../../lib/format';
import { zProblem } from '../../client/zod.gen';

interface TopicContext {
  topic: TopicDetail;
}

export function useTopic(): TopicDetail {
  return useOutletContext<TopicContext>().topic;
}

export function useTopicRef(): string {
  const { ref } = useParams();
  return ref ?? '';
}

/** Loads the topic for every /t/:ref route and hands it down via outlet context. */
export function TopicLayout() {
  const ref = useTopicRef();
  const query = useQuery(getTopicOptions({ path: { ref } }));

  if (query.isPending && query.fetchStatus === 'paused') {
    return (
      <>
        <TopBar back="/" />
        <Page>
          <EmptyState
            title="You’re offline"
            icon={<Icon name="cloudOff" className="size-9" />}
            action={
              <ButtonLink to="/" variant="primary">
                All topics
              </ButtonLink>
            }
          >
            This topic isn’t saved on this device yet. It will load when you’re back online.
          </EmptyState>
        </Page>
      </>
    );
  }
  if (query.isPending) {
    return (
      <>
        <TopBar back="/" />
        <PageSpinner label="Loading topic" />
      </>
    );
  }
  if (query.isError) {
    const p = zProblem.safeParse(query.error);
    const notFound = p.success && p.data.code === 'not_found';
    return (
      <>
        <TopBar back="/" />
        <Page>
          {notFound ? (
            <EmptyState
              title="Topic not found"
              action={
                <ButtonLink to="/" variant="primary">
                  All topics
                </ButtonLink>
              }
            >
              It may have been renamed or deleted.
            </EmptyState>
          ) : (
            <Banner
              title="Could not load topic"
              action={
                <Button size="sm" onClick={() => void query.refetch()}>
                  Retry
                </Button>
              }
            >
              {errorMessage(query.error)}
            </Banner>
          )}
        </Page>
      </>
    );
  }
  return <Outlet context={{ topic: query.data } satisfies TopicContext} />;
}

const TABS = [
  { to: '', label: 'Overview', icon: 'chart' },
  { to: 'entries', label: 'Entries', icon: 'list' },
  { to: 'versions', label: 'Versions', icon: 'layers' },
] as const;

/** Header + tabs shared by overview / entries / versions. */
export function TopicTabs() {
  const topic = useTopic();
  const [params] = useSearchParams();
  const location = useLocation();
  const range = params.get('range');
  const search = range ? `?range=${range}` : '';
  const archived = topic.status === 'archived';
  const base = `/t/${topic.slug}`;

  return (
    <>
      <TopBar
        back="/"
        title={<span className="sm:hidden">{topic.name}</span>}
        actions={
          <>
            <ButtonLink
              to={`${base}/edit`}
              variant="ghost"
              size="sm"
              icon={<Icon name="edit" className="size-4" />}
            >
              <span className="hidden sm:inline">Edit questions</span>
              <span className="sm:hidden">Edit</span>
            </ButtonLink>
            <ButtonLink
              to={`${base}/settings`}
              variant="ghost"
              size="sm"
              aria-label="Topic settings"
              className="px-2.5"
            >
              <Icon name="settings" className="size-4.5" />
            </ButtonLink>
          </>
        }
      />
      <Page className="gap-4">
        <section className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-2">
            <VersionTag version={topic.current_version} />
            {archived ? (
              <Badge tone="warn">
                <Icon name="archive" className="size-3.5" />
                Archived
              </Badge>
            ) : (
              <Badge tone="ok">Active</Badge>
            )}
            <span className="text-xs text-muted">
              {plural(topic.entry_count, 'entry', 'entries')} · last{' '}
              {formatRelative(topic.last_captured_at)}
            </span>
          </div>
          <div className="flex items-end justify-between gap-4">
            <div className="min-w-0">
              <h1 className="font-display text-3xl leading-[1.05] font-bold tracking-tight text-balance sm:text-5xl">
                {topic.name}
              </h1>
              {topic.description ? (
                <p className="mt-2 max-w-prose text-[0.95rem] text-muted">{topic.description}</p>
              ) : null}
            </div>
            {!archived ? (
              <ButtonLink
                to={`${base}/record`}
                variant="primary"
                size="lg"
                className="shrink-0 max-sm:hidden"
                icon={<Icon name="plus" strokeWidth={2.6} />}
              >
                Log
              </ButtonLink>
            ) : null}
          </div>
          {archived ? (
            <Banner tone="warn" title="This topic is archived">
              New entries are paused. Unarchive it in settings to log again.
            </Banner>
          ) : null}
        </section>

        <nav
          aria-label="Topic sections"
          className="sticky top-[calc(3.5rem+env(safe-area-inset-top))] z-20 -mx-4 border-b border-line bg-paper/90 px-4 backdrop-blur-md select-none sm:top-[calc(4rem+env(safe-area-inset-top))] sm:-mx-6 sm:px-6"
        >
          <ul className="flex gap-1">
            {TABS.map((t) => (
              <li key={t.label}>
                <NavLink
                  to={{ pathname: t.to ? `${base}/${t.to}` : base, search }}
                  end
                  className={({ isActive }) =>
                    cn(
                      'relative flex h-12 items-center gap-2 px-3 text-sm font-semibold transition-colors',
                      isActive
                        ? 'text-ink after:absolute after:inset-x-2 after:-bottom-px after:h-0.5 after:rounded-full after:bg-accent'
                        : 'text-muted hover:text-ink',
                    )
                  }
                >
                  <Icon name={t.icon} className="size-4" />
                  {t.label}
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>

        <div key={location.pathname} className="flex animate-fade flex-col gap-5">
          <Outlet context={{ topic } satisfies TopicContext} />
        </div>
      </Page>

      {!archived ? (
        <ButtonLink
          to={`${base}/record`}
          variant="primary"
          size="lg"
          className="fixed right-4 bottom-[max(1.25rem,calc(env(safe-area-inset-bottom)+0.75rem))] z-20 h-16 px-7 text-lg shadow-float sm:hidden"
          icon={<Icon name="plus" className="size-6" strokeWidth={2.6} />}
        >
          Log
        </ButtonLink>
      ) : null}
    </>
  );
}
