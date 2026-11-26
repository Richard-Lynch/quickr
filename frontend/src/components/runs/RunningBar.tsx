/**
 * The running bar (timers.md §11.5, active-surfaces.md §6.3): a strip above the content listing
 * every open run, each with its timer and the run panel's primary (Lap or Next, never Stop),
 * linking to its run panel for the rest. A run whose primary is already on screen is left out,
 * so no control shows twice: the run whose panel is open, and a run the topics page shows as a
 * card (`onScreen.ts`).
 */
import { useQuery } from '@tanstack/react-query';
import { Link, useMatch, useSearchParams } from 'react-router';

import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import { fmtDuration } from '../../lib/runs/format';
import { isOpen, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { activeMs } from './model';
import { useTopicsWithControlsOnScreen } from './onScreen';
import { useServerNow } from './RunClock';
import { actionIcon, actionLabel, actionTitle } from './RunControls';
import { useOpenRunPrimary } from './RunTile';

export function RunningBar() {
  const { runs } = useRuns();
  const [params] = useSearchParams();
  // On a run's own panel the bar leaves it out; the untimed form isn't its panel.
  const recordRef = useMatch('/t/:ref/record')?.params.ref;
  const onRecord = params.has('untimed') ? undefined : recordRef;
  // The record page's topic (by slug or id), as its layout loaded it.
  const shownTopic = useQuery({
    ...getTopicOptions({ path: { ref: onRecord ?? '' } }),
    enabled: onRecord !== undefined,
  }).data?.id;
  const onScreen = useTopicsWithControlsOnScreen();
  const open = runs.filter(
    (r) =>
      isOpen(r) &&
      !(onRecord && [r.topic_id, r.topic?.slug].includes(onRecord)) &&
      r.topic_id !== shownTopic &&
      !onScreen.has(r.topic_id.toLowerCase()),
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
  const primary = useOpenRunPrimary(
    topic ?? { id: run.topic_id, slug: run.topic_id, name: '' },
    run,
  );
  if (!topic) return null;
  const paused = run.status === 'paused';
  return (
    <li className="flex items-center gap-2">
      <Link
        to={`/t/${topic.slug}/record`}
        className="flex min-h-11 min-w-0 flex-1 items-center gap-2 rounded-full px-2 text-sm"
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
        // The topic in the name: the bar may list several runs. The title truncates rather
        // than squeezing the topic's name and clock out at 390 px.
        <button
          type="button"
          aria-label={`${actionLabel(primary.action.kind, topic.name)} · ${topic.name}`}
          disabled={primary.disabled}
          onClick={primary.onTap}
          data-testid="bar-primary"
          className="inline-flex h-11 max-w-[45%] shrink-0 items-center gap-1 rounded-full bg-accent px-3.5 text-sm font-semibold text-on-accent transition-transform active:scale-95 disabled:opacity-50 motion-reduce:transform-none"
        >
          <Icon
            name={actionIcon(primary.action.kind)}
            className="size-4 shrink-0"
            strokeWidth={2.6}
          />
          <span className="truncate">{actionTitle(primary.action.kind)}</span>
        </button>
      ) : null}
    </li>
  );
}
