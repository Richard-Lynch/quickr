/**
 * The home card of a topic with an open run (active-surfaces.md §6.2, the PWA side of
 * §3.2): larger and tinted, with the segment clock big (the lap is what is being timed),
 * the run total beside it, the status and headline, and the run's controls inline. The
 * whole card opens the run panel. Idle and finishing topics keep `TopicTile`'s layout.
 */
import type { CSSProperties } from 'react';
import { Link } from 'react-router';

import type { TopicSummary } from '../../client';
import { topicStyle, type Appearance } from '../../lib/appearance';
import type { LocalRun } from '../../lib/runs/localView';
import type { Timer } from '../../lib/runs/types';
import { activeMs, alertLine, headline as runHeadline, segmentMs } from '../runs/model';
import { useRunControlsOnScreen } from '../runs/onScreen';
import { Duration, useServerNow } from '../runs/RunClock';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon, type IconName } from '../ui/Icon';
import { TopicGlyph } from '../ui/TopicGlyph';

/**
 * The topic as the card reads it. `appearance` (appearance.md §1.1) is optional until the
 * generated `TopicSummary` carries it; without it the card is the brand accent.
 */
export type CardTopic = Pick<TopicSummary, 'id' | 'slug' | 'name'> & {
  appearance?: Appearance | null | undefined;
};

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

/**
 * The card's theme (appearance.md §4.2): the topic's tint variables on the card, read by the
 * one `topic-tint` utility set, which falls back to the accent for a topic without a colour.
 */
export function cardTint(topic: CardTopic): {
  style: CSSProperties;
  card: string;
  bar: string;
} {
  return {
    style: topicStyle(topic.appearance),
    card: 'border-topic-tint/45 bg-topic-tint-soft',
    bar: 'bg-topic-tint',
  };
}

/**
 * Whether the run is a queued `reopen` the server hasn't acked (the "Resuming…" projection,
 * timers2.md §5.3): the card shows "Resuming…" and no controls until the ack (§3.3, §6.3).
 * Pending M1: the local view has no such projection yet, so no run is resuming.
 */
export const isResuming: (run: LocalRun) => boolean = () => false;

/**
 * The controls row's buttons: 56 px, as `Button size="lg"`, tinted or semantic per §6.2. A long
 * label ("Next: {long step}") wraps to a second line rather than being cut off. A disabled
 * button still takes the tap (no `pointer-events-none`), so a tap in the cooldown never falls
 * through to the card's link.
 */
const CONTROL =
  'inline-flex min-h-14 select-none items-center justify-center gap-2 rounded-full py-2 text-center text-base leading-tight font-semibold transition-[background-color,filter,transform] duration-150 active:scale-[0.97] motion-reduce:active:scale-none disabled:cursor-not-allowed disabled:opacity-50';

export function ActiveTopicCard({
  topic,
  run,
  timer,
  controls,
  resuming = false,
}: {
  topic: CardTopic;
  /** The topic's open run (running or paused). */
  run: LocalRun;
  /** The run's pinned version's timer; null while the steps aren't known. */
  timer: Timer | null;
  controls: CardControls;
  /** A queued, unacked reopen (`isResuming`): "Resuming…" and no controls until the ack. */
  resuming?: boolean;
}) {
  const paused = run.status === 'paused';
  const now = useServerNow(!paused);
  // The card shows this run and its controls: the running bar leaves the run out (§6.3).
  useRunControlsOnScreen(run.topic_id);
  const tint = cardTint(topic);
  const open = run.state.open;
  // With nothing open the headline is just "Running"/"Paused", which the badge already says.
  const headline = open ? runHeadline(run.state, run.status, timer).text : null;
  const alert = alertLine(run.state, timer, now);
  // A resuming run has no controls until the ack.
  const { primary, stop, pauseResume } = resuming
    ? { primary: null, stop: null, pauseResume: null }
    : controls;

  return (
    <article
      aria-label={topic.name}
      data-testid="active-card"
      style={tint.style}
      className={cn(
        '@container relative flex overflow-hidden rounded-card border shadow-card transition-[border-color]',
        tint.card,
      )}
    >
      <span aria-hidden className={cn('absolute inset-y-0 left-0 w-1', tint.bar)} />
      <div className="flex min-w-0 flex-1 flex-col gap-3 py-3.5 pr-3 pl-5">
        <div
          className={cn('flex min-w-0 items-start', pauseResume && 'pr-[6.5rem] @max-[21rem]:pr-0')}
        >
          <h2 className="flex min-w-0 items-center gap-2 pt-1.5 font-display text-[1.2rem] leading-tight font-semibold tracking-tight">
            <span aria-hidden className="contents">
              <TopicGlyph appearance={topic.appearance} name={topic.name} size={24} />
            </span>
            {/* The whole card opens the run panel; its controls sit above this overlay. */}
            <Link
              to={`/t/${topic.slug}/record`}
              className="after:absolute after:inset-0 after:rounded-card"
            >
              {topic.name}
            </Link>
          </h2>
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
              {resuming ? 'Resuming…' : paused ? 'Paused' : 'Running'}
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
          // Stacks when the text is large (rem bases): the primary over a full-width Stop (§7).
          <div className="relative z-10 flex flex-wrap gap-2 @max-[21rem]:order-2">
            {primary ? (
              <button
                type="button"
                data-testid="card-primary"
                aria-label={primary.label}
                disabled={primary.disabled}
                onClick={primary.onTap}
                className={cn(
                  CONTROL,
                  'min-w-0 flex-[3_1_12rem] bg-topic-tint px-4 text-topic-on-tint shadow-[0_1px_0_rgb(0_0_0/0.15),inset_0_1px_0_rgb(255_255_255/0.2)] hover:brightness-110',
                )}
              >
                <Icon name={primary.icon} className="size-5 shrink-0" strokeWidth={2.6} />
                <span className="min-w-0 [overflow-wrap:anywhere]">{primary.title}</span>
              </button>
            ) : null}
            {stop ? (
              <button
                type="button"
                data-testid="card-stop"
                aria-label={stop.label}
                disabled={stop.disabled}
                onClick={stop.onTap}
                className={cn(
                  CONTROL,
                  'flex-[1_0_5.25rem] gap-1.5 border border-line-strong bg-surface px-2 text-danger hover:border-ink/40 hover:bg-sunken',
                )}
              >
                <Icon name={stop.icon} className="size-4.5 shrink-0" strokeWidth={2.6} />
                {stop.title}
              </button>
            ) : null}
          </div>
        ) : null}
        {/* Last for screen readers (§7: the controls in order primary, Stop, Pause), shown in
            the title row's corner; at large text (a card under 21rem) under the headline. */}
        {pauseResume ? (
          <button
            type="button"
            data-testid={pauseResume.paused ? 'card-resume' : 'card-pause'}
            aria-label={pauseResume.label}
            disabled={pauseResume.disabled}
            onClick={pauseResume.onTap}
            className="absolute top-2.5 right-2 z-10 inline-flex min-h-11 shrink-0 items-center gap-1.5 self-start rounded-full px-3 text-sm font-semibold text-ink-soft transition-colors hover:bg-surface/70 hover:text-ink disabled:cursor-wait disabled:opacity-60 @max-[21rem]:relative @max-[21rem]:top-auto @max-[21rem]:right-auto @max-[21rem]:order-1 @max-[21rem]:-my-1.5 @max-[21rem]:-ml-3"
          >
            <Icon name={pauseResume.icon} className="size-4" strokeWidth={2.4} />
            {pauseResume.title}
          </button>
        ) : null}
      </div>
    </article>
  );
}
