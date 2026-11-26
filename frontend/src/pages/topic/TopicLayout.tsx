import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect } from 'react';
import {
  Link,
  NavLink,
  Outlet,
  useLocation,
  useNavigate,
  useOutletContext,
  useParams,
  useSearchParams,
} from 'react-router';

import { errorMessage } from '../../api/errors';
import { getTopicOptions, getTopicQueryKey } from '../../client/@tanstack/react-query.gen';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { Button, ButtonLink } from '../../components/ui/Button';
import { Badge, Banner, EmptyState, VersionTag } from '../../components/ui/Card';
import { cn } from '../../components/ui/cn';
import { Icon } from '../../components/ui/Icon';
import { PageSpinner } from '../../components/ui/Spinner';
import { TopicGlyph } from '../../components/ui/TopicGlyph';
import { topicStyle } from '../../lib/appearance';
import { keepsPageState } from '../../lib/unsavedChanges';
import { formatRelative } from '../../lib/dates';
import { plural } from '../../lib/format';
import { describeSchedule, dueView } from '../../lib/schedule';
import { DueBadge } from '../../components/topics/TopicTile';
import { zProblem } from '../../client/zod.gen';
import { appearanceOf } from '../../lib/topicAppearanceSeam';

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

const isNotFound = (error: unknown) => {
  const p = zProblem.safeParse(error);
  return p.success && p.data.code === 'not_found';
};

/**
 * A slug changed elsewhere makes a refetch of `/t/<old slug>` 404 while the query still holds the
 * topic. Look it up by its id and move the route to the new slug (seeding its cache, so the page
 * stays mounted); meanwhile, and while the lookup fails, return the topic last loaded. `null` when
 * there's nothing to follow, or the topic is gone by id too (deleted): the caller shows the error.
 */
function useFollowRename(
  ref: string,
  query: { isError: boolean; error: unknown; data: TopicDetail | undefined },
): TopicDetail | null {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const location = useLocation();
  const last = query.data;
  const lost = query.isError && isNotFound(query.error) && last !== undefined && last.id !== ref;
  const byId = useQuery({
    ...getTopicOptions({ path: { ref: last?.id ?? '' } }),
    enabled: lost,
    staleTime: 0,
  });
  const found = lost && byId.data && byId.data.slug !== ref ? byId.data : null;
  useEffect(() => {
    if (!found) return;
    qc.setQueryData(getTopicQueryKey({ path: { ref: found.slug } }), found);
    const rest = location.pathname.slice(`/t/${ref}`.length);
    void navigate(`/t/${found.slug}${rest}${location.search}`, {
      replace: true,
      state: keepsPageState(),
    });
  }, [found, qc, navigate, location.pathname, location.search, ref]);
  // Only a 404 by id too means it's gone; a failed lookup keeps the page as it was.
  if (!lost || (byId.isError && isNotFound(byId.error))) return null;
  return found ?? last;
}

/** Loads the topic for every /t/:ref route and hands it down via outlet context. */
export function TopicLayout() {
  const ref = useTopicRef();
  const query = useQuery(getTopicOptions({ path: { ref } }));
  const moved = useFollowRename(ref, query);
  // Keep the page (and any unsaved form in it) while a rename elsewhere is being followed.
  if (moved) return <Outlet context={{ topic: moved } satisfies TopicContext} />;

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
  // appearance.md §6.3, §4.3: no colour leaves the header exactly as it was (no style, accent
  // chrome); a colour themes the header and the active-tab rule. The glyph shows for an emoji, or
  // the initial when there's a colour; the chips are neutral badges (§5).
  const appearance = appearanceOf(topic);
  const tinted = appearance?.color != null;
  const theme = topicStyle(appearance);
  const showGlyph = tinted || appearance?.icon != null;
  const tags = appearance?.tags ?? [];

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
        <section className="flex flex-col gap-3" style={theme}>
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
          {tags.length > 0 ? (
            <ul aria-label="Tags" className="flex flex-wrap gap-1.5">
              {tags.map((tag) => (
                <li key={tag}>
                  <Badge>{tag}</Badge>
                </li>
              ))}
            </ul>
          ) : null}
          {topic.schedule && !archived ? (
            <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
              <DueBadge view={dueView(topic.due)} />
              <Link to={`${base}/settings`} className="underline-offset-2 hover:underline">
                {describeSchedule(topic.schedule)}
                {topic.schedule.notify ? ' · notifies' : ''}
              </Link>
            </div>
          ) : null}
          <div className="flex items-end justify-between gap-4">
            <div className="min-w-0">
              <h1 className="font-display text-3xl leading-[1.05] font-bold tracking-tight text-balance sm:text-5xl">
                {showGlyph ? (
                  // The name follows, so the glyph's own label would only repeat it.
                  <span
                    aria-hidden="true"
                    data-testid="topic-glyph"
                    className="mr-2 align-[-0.12em]"
                  >
                    <TopicGlyph appearance={appearance} name={topic.name} size={32} />
                  </span>
                ) : null}
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
          style={theme}
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
                        ? cn(
                            'text-ink after:absolute after:inset-x-2 after:-bottom-px after:h-0.5 after:rounded-full',
                            tinted ? 'after:bg-topic-tint' : 'after:bg-accent',
                          )
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
