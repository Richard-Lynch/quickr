/**
 * The running bar (timers.md §11.5): a strip above the content listing every open run,
 * each with its timer and primary button, linking to its run panel. The run whose panel
 * is on screen is left out.
 */
import { useQuery } from '@tanstack/react-query';
import { Link, useMatch } from 'react-router';

import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import { fmtDuration } from '../../lib/runs/format';
import { isOpen, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { activeMs } from './model';
import { useServerNow } from './RunClock';
import { useRunPrimary } from './RunTile';

export function RunningBar() {
  const { runs } = useRuns();
  const onRecord = useMatch('/t/:ref/record')?.params.ref;
  // The record page's topic (by slug or id), as its layout loaded it.
  const shownTopic = useQuery({
    ...getTopicOptions({ path: { ref: onRecord ?? '' } }),
    enabled: onRecord !== undefined,
  }).data?.id;
  const open = runs.filter(
    (r) =>
      isOpen(r) &&
      !(onRecord && [r.topic_id, r.topic?.slug].includes(onRecord)) &&
      r.topic_id !== shownTopic,
  );
  if (open.length === 0) return null;
  return (
    <section
      aria-label="Running"
      className="border-b border-accent/25 bg-accent-soft/70 px-2 py-1.5 sm:px-4"
    >
      <ul className="flex flex-col gap-1">
        {open.map((r) => (
          <RunningItem key={r.id} run={r} />
        ))}
      </ul>
    </section>
  );
}

function RunningItem({ run }: { run: LocalRun }) {
  // A run known only from the server names its topic by id.
  const detail = useQuery({
    ...getTopicOptions({ path: { ref: run.topic_id } }),
    staleTime: 5 * 60_000,
    enabled: run.topic === null,
  });
  const topic =
    run.topic ??
    (detail.data ? { id: detail.data.id, slug: detail.data.slug, name: detail.data.name } : null);
  const now = useServerNow(run.status === 'running');
  const primary = useRunPrimary(topic ?? { id: run.topic_id, slug: run.topic_id, name: '' }, run);
  if (!topic) return null;
  const paused = run.status === 'paused';
  return (
    <li className="flex items-center gap-2">
      <Link
        to={`/t/${topic.slug}/record`}
        className="flex min-h-10 min-w-0 flex-1 items-center gap-2 rounded-full px-2 text-sm"
      >
        <Icon
          name={paused ? 'pause' : 'timer'}
          className={cn('size-4', paused ? 'text-warn' : 'text-accent-strong')}
          strokeWidth={2.4}
        />
        <span className="min-w-0 truncate">
          <strong className="font-semibold">{topic.name}</strong>
          {run.state.open ? <span className="text-ink-soft"> · {run.state.open.label}</span> : null}
        </span>
        <span className="ml-auto font-mono font-semibold tabular">
          {fmtDuration(activeMs(run.state, now))}
        </span>
      </Link>
      {primary ? (
        <button
          type="button"
          aria-label={`${primary.label} · ${topic.name}`}
          disabled={primary.disabled}
          onClick={primary.onTap}
          className="inline-flex h-9 shrink-0 items-center gap-1 rounded-full bg-accent px-3.5 text-sm font-semibold text-on-accent transition-transform active:scale-95 disabled:opacity-50"
        >
          <Icon
            name={primary.type === 'next' ? 'chevronRight' : 'stop'}
            className="size-4"
            strokeWidth={2.6}
          />
          {primary.type === 'next' ? 'Next' : 'Stop'}
        </button>
      ) : null}
    </li>
  );
}
