/**
 * The run panel on a timed topic's Record page (timers.md §11.5, as the iOS run screen of
 * §11.2): total and segment timers, the step checklist, the primary button, Lap, Skip,
 * Pause or Resume, Stop, and Discard behind a confirmation. Idle, it offers Start.
 */
import { useState } from 'react';

import type { RunEventPayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import type { RunContext } from '../../lib/runs/actions';
import { parseInstant } from '../../lib/runs/instant';
import type { LocalRun } from '../../lib/runs/localView';
import type { TimerStep } from '../../lib/runs/types';
import { StickyActions } from '../AppShell';
import { Button } from '../ui/Button';
import { Badge, Card } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { ConfirmSheet } from '../ui/Sheet';
import { Duration, useServerNow } from './RunClock';
import {
  activeMs,
  checklist,
  expectOf,
  laps,
  primaryAction,
  segmentMs,
  skipTarget,
  type ChecklistRow,
} from './model';
import type { RunActions } from './useRunActions';

export function RunPanel({
  run,
  ctx,
  actions,
  onStopped,
  onDiscarded,
}: {
  run: LocalRun;
  /** The run's own version's context; null while it isn't known (controls wait). */
  ctx: RunContext | null;
  actions: RunActions;
  /** The stop is queued. `totalMs` is the run's active time at the tap. */
  onStopped: (run: LocalRun, item: OutboxItem<RunEventPayload>, totalMs: number) => void;
  onDiscarded: () => void;
}) {
  const paused = run.status === 'paused';
  const now = useServerNow(!paused);
  // Null: the steps aren't known here yet (no step list, no Skip; the clock still runs).
  const steps: readonly TimerStep[] | null = ctx ? ctx.steps : run.steps;
  const total = activeMs(run.state, now);
  const segment = segmentMs(run.state, now);
  const primary = primaryAction(run, steps);
  const skip = skipTarget(run, steps);
  const open = run.state.open;
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const disabled = ctx === null || actions.busy;

  // Captured at render: a second tap before the screen catches up targets what it saw.
  const expect = expectOf(run, steps);
  const tap = (type: Parameters<RunActions['tap']>[2]) =>
    ctx ? actions.tap(run.id, ctx, type, {}, expect) : Promise.resolve(null);
  const stop = async () => {
    const item = await tap('stop');
    if (item) onStopped(run, item, activeMs(run.state, parseInstant(item.payload.event.at)));
  };

  return (
    <>
      <Card className="flex flex-col gap-5 p-5 sm:p-6" aria-label="Run">
        <div className="flex items-center justify-between gap-3">
          <Badge tone={paused ? 'warn' : 'accent'}>
            {paused ? (
              <Icon name="pause" className="size-3.5" strokeWidth={2.6} />
            ) : (
              <span className="relative flex size-2">
                <span className="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60 motion-reduce:hidden" />
                <span className="relative inline-flex size-2 rounded-full bg-accent" />
              </span>
            )}
            {paused ? 'Paused' : 'Running'}
          </Badge>
          {run.queued.length > 0 ? (
            <span className="text-xs text-muted">Saved on this device</span>
          ) : null}
        </div>

        <div className="flex flex-col items-center gap-1 text-center">
          <Duration
            ms={total}
            label="Total"
            className={cn(
              'text-[3.75rem] leading-none font-semibold tracking-tight sm:text-7xl',
              paused && 'text-muted',
            )}
          />
          {open ? (
            <p className="flex items-center gap-2 text-[0.95rem] text-ink-soft">
              <span className="font-semibold text-ink" data-testid="segment-label">
                {open.label}
              </span>
              <Duration ms={segment} label={open.label} className="text-muted" />
            </p>
          ) : null}
        </div>

        <Steps run={run} steps={steps} segmentMs={segment} />

        <div className="grid grid-cols-3 gap-2">
          <Button
            variant="secondary"
            icon={<Icon name="flag" className="size-4" />}
            disabled={disabled || !open}
            onClick={() => void tap('lap')}
          >
            Lap
          </Button>
          <Button
            variant="secondary"
            icon={<Icon name="skip" className="size-4" />}
            disabled={disabled || skip === null}
            onClick={() => void tap('skip')}
            className="min-w-0"
            aria-label={skip ? `Skip ${skip.label}` : 'Skip'}
          >
            <span className="truncate">{skip ? `Skip ${skip.label}` : 'Skip'}</span>
          </Button>
          <Button
            variant="secondary"
            icon={<Icon name={paused ? 'play' : 'pause'} className="size-4" />}
            disabled={disabled}
            onClick={() => void tap(paused ? 'resume' : 'pause')}
          >
            {paused ? 'Resume' : 'Pause'}
          </Button>
        </div>

        <button
          type="button"
          onClick={() => setConfirmDiscard(true)}
          disabled={disabled}
          className="self-center text-sm font-semibold text-danger underline-offset-2 hover:underline disabled:opacity-50"
        >
          Discard
        </button>
      </Card>

      <StickyActions>
        {primary.type === 'next' ? (
          <Button
            size="lg"
            variant="secondary"
            icon={<Icon name="stop" className="size-4.5" />}
            disabled={disabled}
            onClick={() => void stop()}
          >
            Stop
          </Button>
        ) : null}
        <Button
          size="lg"
          variant="primary"
          className="min-w-0 flex-1 sm:flex-none"
          disabled={disabled}
          icon={<Icon name={primary.type === 'next' ? 'chevronRight' : 'stop'} strokeWidth={2.6} />}
          onClick={() => void (primary.type === 'next' ? tap('next') : stop())}
        >
          <span className="truncate">{primary.label}</span>
        </Button>
      </StickyActions>

      <ConfirmSheet
        open={confirmDiscard}
        onClose={() => setConfirmDiscard(false)}
        onConfirm={() => {
          void tap('discard').then((item) => {
            setConfirmDiscard(false);
            if (item) onDiscarded();
          });
        }}
        title="Discard this run?"
        body="Its times won’t be saved. This can’t be undone."
        confirmLabel="Discard"
        cancelLabel="Keep timing"
        danger
        busy={actions.busy}
      />
    </>
  );
}

const STATUS_ICON: Record<ChecklistRow['status'], React.ReactNode> = {
  done: <Icon name="check" className="size-3.5" strokeWidth={3} />,
  skipped: <Icon name="skip" className="size-3" strokeWidth={2.4} />,
  current: <span className="size-2 rounded-full bg-on-accent" />,
  upcoming: null,
};

/** The step checklist (§11.2), then the laps. */
function Steps({
  run,
  steps,
  segmentMs: live,
}: {
  run: LocalRun;
  steps: readonly TimerStep[] | null;
  segmentMs: number;
}) {
  const rows = checklist(run.state, steps);
  const done = laps(run.state);
  const open = run.state.open;
  const lapOpen = open?.kind === 'lap';
  if (rows.length === 0 && done.length === 0 && !lapOpen) return null;
  return (
    <ol className="flex flex-col divide-y divide-dashed divide-line rounded-2xl border border-line">
      {rows.map((r) => (
        <Row
          key={r.key}
          status={r.status}
          label={r.label}
          ms={r.status === 'current' ? live : r.ms}
        />
      ))}
      {done.map((l) => (
        <Row key={l.label} status="done" label={l.label} ms={l.ms} lap />
      ))}
      {lapOpen ? <Row status="current" label={open.label} ms={live} lap /> : null}
    </ol>
  );
}

function Row({
  status,
  label,
  ms,
  lap = false,
}: {
  status: ChecklistRow['status'];
  label: string;
  ms: number | null;
  lap?: boolean;
}) {
  return (
    <li
      className={cn(
        'flex min-h-11 items-center gap-3 px-3.5 py-2',
        status === 'current' && 'bg-accent-soft/60',
      )}
      data-status={status}
    >
      <span
        aria-hidden
        className={cn(
          'grid size-5.5 shrink-0 place-items-center rounded-full border-2',
          status === 'done' && 'border-ok bg-ok text-white',
          status === 'skipped' && 'border-line-strong text-muted',
          status === 'current' && 'border-accent bg-accent',
          status === 'upcoming' && 'border-line-strong',
          lap && status !== 'current' && 'border-dashed',
        )}
      >
        {STATUS_ICON[status]}
      </span>
      <span
        className={cn(
          'min-w-0 flex-1 truncate',
          status === 'current' ? 'font-semibold' : 'text-ink-soft',
          status === 'skipped' && 'text-muted line-through',
        )}
      >
        {label}
        <span className="sr-only">
          {status === 'done'
            ? ', done'
            : status === 'skipped'
              ? ', skipped'
              : status === 'current'
                ? ', now'
                : ''}
        </span>
      </span>
      {ms !== null ? (
        <Duration
          ms={ms}
          className={cn('text-sm', status === 'current' ? 'text-ink' : 'text-muted')}
        />
      ) : status === 'skipped' ? (
        <span className="text-xs text-muted">Skipped</span>
      ) : null}
    </li>
  );
}

/** Idle: the topic's steps, and Start. */
export function RunStart({
  steps,
  disabled,
  busy,
  onStart,
  note,
}: {
  steps: readonly TimerStep[];
  disabled: boolean;
  busy: boolean;
  onStart: () => void;
  note?: React.ReactNode;
}) {
  return (
    <>
      <Card className="flex flex-col gap-5 p-5 sm:p-6" aria-label="Run">
        <div className="flex flex-col items-center gap-1 text-center">
          <Duration
            ms={0}
            className="text-[3.75rem] leading-none font-semibold tracking-tight text-muted sm:text-7xl"
          />
          <p className="text-[0.95rem] text-muted">
            {steps.length === 0
              ? 'One tap starts the timer; Stop saves it.'
              : `${String(steps.length)} ${steps.length === 1 ? 'step' : 'steps'}, timed in order.`}
          </p>
        </div>
        {steps.length > 0 ? (
          <ol className="flex flex-col divide-y divide-dashed divide-line rounded-2xl border border-line">
            {steps.map((s) => (
              <Row key={s.key} status="upcoming" label={s.label} ms={null} />
            ))}
          </ol>
        ) : null}
        {note}
      </Card>
      <StickyActions>
        <Button
          size="lg"
          variant="primary"
          className="flex-1 sm:flex-none"
          disabled={disabled}
          loading={busy}
          icon={<Icon name="play" strokeWidth={2.4} />}
          onClick={onStart}
        >
          Start
        </Button>
      </StickyActions>
    </>
  );
}
