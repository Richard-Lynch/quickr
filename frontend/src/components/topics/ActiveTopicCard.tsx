/**
 * The home card of a topic with an open run (active-surfaces.md §6.2, the PWA side of
 * §3.2): larger and tinted, with the segment clock big (the lap is what is being timed),
 * the run total beside it, the status and headline, and the run's controls inline. The
 * whole card opens the run panel. Idle and finishing topics keep `TopicTile`'s layout.
 */
import type { CSSProperties } from 'react';
import { Link } from 'react-router';

import type { TopicSummary } from '../../client';
import type { LocalRun } from '../../lib/runs/localView';
import { activeMs, segmentMs } from '../runs/model';
import { Duration, useServerNow } from '../runs/RunClock';
import { Button } from '../ui/Button';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon, type IconName } from '../ui/Icon';

/** One of the card's buttons, as its controls source renders it (`useActiveCardControls`). */
export interface CardButton {
  title: string;
  /** The accessible name. */
  label: string;
  icon: IconName;
  disabled: boolean;
  onTap: () => void;
}

/**
 * The card's controls: the primary (Lap/Next) and Stop fill the controls row; Pause or
 * Resume is the small text button of the title row. A null slot isn't shown.
 */
export interface CardControls {
  primary: CardButton | null;
  stop: CardButton | null;
  /** Pause while running, Resume while paused: `paused` says which. */
  pauseResume: (CardButton & { paused: boolean }) | null;
}

export interface CardTint {
  style: CSSProperties | undefined;
  card: string;
  bar: string;
}
/**
 * The card's tint: the one seam for M3's topic theme (appearance.md §4.2). Until
 * `topicStyle` and the `topic-tint` utilities land, the brand accent; then this returns
 * `style: topicStyle(topic.appearance)` and the `bg-topic-tint-soft border-topic-tint/45`
 * / `bg-topic-tint` classes, which default to the accent themselves.
 */
export const cardTint: (topic: Pick<TopicSummary, 'id'>) => CardTint = () => ({
  style: undefined,
  card: 'border-accent/45 bg-accent-soft',
  bar: 'bg-accent',
});

/**
 * The headline after "Running ·" (§1.1): the open segment's label. Seam: M1's
 * `headline(state, status, timer).text` ("Rest 2 · lap 4") replaces it; until then the
 * label is the fallback active-surfaces.md §8.2 names. Null when nothing is open.
 */
export function cardHeadline(run: Pick<LocalRun, 'state'>): string | null {
  return run.state.open?.label ?? null;
}

/**
 * The next alert's line ("Half way · in 0:12"). Seam: M1's `alertLine(state, timer, now)`;
 * until it lands no run has alerts, so the row stays collapsed.
 */
export const cardAlertLine: (run: Pick<LocalRun, 'state'>, now: number) => string | null = () =>
  null;

export function ActiveTopicCard({
  topic,
  run,
  controls,
}: {
  topic: Pick<TopicSummary, 'id' | 'slug' | 'name'>;
  /** The topic's open run (running or paused). */
  run: LocalRun;
  controls: CardControls;
}) {
  const paused = run.status === 'paused';
  const now = useServerNow(!paused);
  const tint = cardTint(topic);
  const headline = cardHeadline(run);
  const alert = cardAlertLine(run, now);
  const open = run.state.open;
  const { primary, stop, pauseResume } = controls;

  return (
    <article
      aria-label={topic.name}
      data-testid="active-card"
      style={tint.style}
      className={cn(
        'relative flex overflow-hidden rounded-card border shadow-card transition-[border-color]',
        tint.card,
      )}
    >
      <span aria-hidden className={cn('absolute inset-y-0 left-0 w-1', tint.bar)} />
      <div className="flex min-w-0 flex-1 flex-col gap-3 py-3.5 pr-3 pl-5">
        <div className="flex min-w-0 items-start justify-between gap-2">
          <h2 className="min-w-0 pt-1.5 font-display text-[1.2rem] leading-tight font-semibold tracking-tight">
            {/* The whole card opens the run panel; its controls sit above this overlay. */}
            <Link
              to={`/t/${topic.slug}/record`}
              className="after:absolute after:inset-0 after:rounded-card"
            >
              {topic.name}
            </Link>
          </h2>
          {pauseResume ? (
            <button
              type="button"
              data-testid={pauseResume.paused ? 'card-resume' : 'card-pause'}
              aria-label={pauseResume.label}
              disabled={pauseResume.disabled}
              onClick={pauseResume.onTap}
              className="relative z-10 -mr-1 inline-flex min-h-11 shrink-0 items-center gap-1.5 rounded-full px-3 text-sm font-semibold text-ink-soft transition-colors hover:bg-surface/70 hover:text-ink disabled:cursor-wait disabled:opacity-60"
            >
              <Icon name={pauseResume.icon} className="size-4" strokeWidth={2.4} />
              {pauseResume.title}
            </button>
          ) : null}
        </div>

        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <Duration
            ms={open ? segmentMs(run.state, now) : activeMs(run.state, now)}
            label={open ? 'Segment' : 'Total'}
            className={cn(
              'text-5xl leading-none font-semibold tracking-tight',
              paused && 'text-muted',
            )}
          />
          {open ? (
            <span data-testid="card-total" className="text-[0.8rem] text-muted">
              <span aria-hidden>total </span>
              <Duration ms={activeMs(run.state, now)} label="Total" />
            </span>
          ) : null}
        </div>

        <div className="flex min-w-0 flex-col items-start gap-1">
          <Badge tone={paused ? 'warn' : 'accent'} className="max-w-full">
            <Icon name={paused ? 'pause' : 'timer'} className="size-3.5" strokeWidth={2.4} />
            <span data-testid="card-status" className="truncate">
              {paused ? 'Paused' : 'Running'}
              {headline ? (
                <>
                  {' · '}
                  <strong className="font-semibold">{headline}</strong>
                </>
              ) : null}
            </span>
          </Badge>
          {alert ? (
            <p data-testid="card-alert" className="text-[0.8rem] font-medium text-ink-soft">
              <Icon name="bell" className="mr-1 inline size-3.5 align-[-2px]" />
              {alert}
            </p>
          ) : null}
        </div>

        {primary || stop ? (
          <div className="relative z-10 flex gap-2">
            {primary ? (
              <Button
                size="lg"
                variant="primary"
                data-testid="card-primary"
                aria-label={primary.label}
                disabled={primary.disabled}
                onClick={primary.onTap}
                icon={<Icon name={primary.icon} className="size-5" strokeWidth={2.6} />}
                className="min-w-0 flex-1 px-4 motion-reduce:transform-none"
              >
                <span className="truncate">{primary.title}</span>
              </Button>
            ) : null}
            {stop ? (
              <Button
                size="lg"
                variant="secondary"
                data-testid="card-stop"
                aria-label={stop.label}
                disabled={stop.disabled}
                onClick={stop.onTap}
                icon={<Icon name={stop.icon} className="size-4.5" strokeWidth={2.6} />}
                className={cn(
                  'w-[5.25rem] shrink-0 gap-1.5 px-2 text-danger motion-reduce:transform-none',
                  !primary && 'flex-1',
                )}
              >
                {stop.title}
              </Button>
            ) : null}
          </div>
        ) : null}
      </div>
    </article>
  );
}
