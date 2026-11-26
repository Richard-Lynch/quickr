/**
 * The running bar (timers.md §11.5, active-surfaces.md §6.3): a strip above the content listing
 * every open run, each with its timer and the run panel's primary (Lap or Next, never Stop),
 * linking to its run panel for the rest. A run whose primary is already on screen is left out,
 * so no control shows twice: the run whose panel is open, and a run the topics page shows as a
 * card (`onScreen.ts`).
 */
import { useQuery } from '@tanstack/react-query';
import { Link, useMatch, useNavigate, useSearchParams } from 'react-router';

import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import type { RunContext } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { isOpen, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { runTimer, timerOf, useRunContext, useTopicVersions } from './context';
import { controlsLayout } from './controlsLayout';
import { actions as runActions, activeMs, expectOf, type RunAction } from './model';
import { useTopicsWithControlsOnScreen } from './onScreen';
import { useServerNow } from './RunClock';
import { actionIcon, actionLabel, actionTitle } from './RunControls';
import { useRunActions, useRunCooldown } from './useRunActions';

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
    // Wraps rather than truncating the primary: when its title doesn't fit beside the topic
    // (a long step name, a narrow or zoomed screen), the button moves to a line of its own.
    <li className="flex flex-wrap items-center gap-x-2 gap-y-1">
      <Link
        to={`/t/${topic.slug}/record`}
        className="flex min-h-11 min-w-0 flex-[1_1_12rem] items-center gap-2 rounded-full px-2 text-sm"
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
        // The topic in the name: the bar may list several runs.
        <button
          type="button"
          aria-label={`${actionLabel(primary.action.kind, topic.name)} · ${topic.name}`}
          disabled={primary.disabled}
          onClick={primary.onTap}
          data-testid="bar-primary"
          className="ml-auto inline-flex min-h-11 max-w-full shrink-0 items-center gap-1 rounded-full bg-accent px-3.5 py-1.5 text-left text-sm leading-tight font-semibold text-on-accent transition-transform active:scale-95 disabled:opacity-50 motion-reduce:transform-none"
        >
          <Icon
            name={actionIcon(primary.action.kind)}
            className="size-4 shrink-0"
            strokeWidth={2.6}
          />
          <span className="min-w-0 break-words">{actionTitle(primary.action.kind)}</span>
        </button>
      ) : null}
    </li>
  );
}

/**
 * An open run's primary (active-surfaces.md §1.2, §6.3): the layout model's, as on the run
 * panel, so Lap (with the next lap type) or Next, never Stop; the bar links to the panel for
 * Stop. Off as the panel's is: while the run's context isn't known, a tap is being enqueued,
 * the topic's tap cooldown runs, or the action itself is off. Null when the run isn't open.
 */
function useOpenRunPrimary(
  topic: RunContext['topic'],
  run: LocalRun | undefined,
): { action: RunAction; disabled: boolean; onTap: () => void } | null {
  const taps = useRunActions();
  const navigate = useNavigate();
  const versions = useTopicVersions(run?.topic_id ?? '', Boolean(run));
  const runCtx = useRunContext(run, topic);
  const cooling = useRunCooldown(run?.topic_id ?? '');
  const now = useServerNow(run?.status === 'running');
  // None for a queued reopen before its ack (§1.2 row 11, M1's `resuming` projection): it has
  // no controls anywhere, and `actions` can't say so itself (model.ts).
  if (!run || !isOpen(run) || run.resuming) return null;
  const steps = runCtx ? runCtx.steps : run.steps;
  const timer = runTimer(timerOf(versions.data, run.version), steps);
  const action = controlsLayout(runActions(run.state, run.status, timer, now)).primary;
  if (!action) return null;
  // Captured at render: a second tap before the bar catches up targets what it showed.
  const expect = expectOf(run, steps);
  const kind = action.kind;
  return {
    action,
    disabled: runCtx === null || taps.busy || cooling || !action.enabled,
    onTap: () => {
      // An open run's primary is Next or Lap (§1.2). Placement is by role, so a primary of
      // another kind still shows; the run panel, which handles every kind, takes its tap.
      if (kind.type === 'next' || kind.type === 'lap') {
        if (runCtx) void taps.tap(run.id, runCtx, kind.type, {}, expect);
      } else void navigate(`/t/${topic.slug}/record`);
    },
  };
}
