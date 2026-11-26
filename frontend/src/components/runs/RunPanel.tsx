/**
 * The run panel on a timed topic's Record page (active-surfaces.md §6.1, as the iOS run screen
 * of §2.1): the header (badge, total clock, headline with the segment clock, alert line), then
 * `RunControls` (the primary, Stop and Pause or Resume, a "More" sheet with Skip and Discard
 * run…), then the step and lap table, which has no buttons (D-3). Idle, it offers Start.
 */
import { useState } from 'react';

import type { RunEventPayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import type { RunContext } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { parseInstant } from '../../lib/runs/instant';
import type { LocalRun } from '../../lib/runs/localView';
import type { Timer, TimerStep } from '../../lib/runs/types';
import { StickyActions } from '../AppShell';
import { Button } from '../ui/Button';
import { Badge, Card } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { ConfirmSheet } from '../ui/Sheet';
import { runTimer } from './context';
import { Duration, useServerNow } from './RunClock';
import type { ReopenOffer } from './reopen';
import { actionLabel, RunControls } from './RunControls';
import {
  actions as runActions,
  activeMs,
  alertLine,
  checklist,
  expectOf,
  headline,
  laps,
  segmentMs,
  type ChecklistRow,
  type RunAction,
} from './model';
import { useRunCooldown, type RunActions } from './useRunActions';

export function RunPanel({
  run,
  ctx,
  timer: pinned,
  topic,
  actions,
  onStopped,
  onDiscarded,
  onReverted,
}: {
  run: LocalRun;
  /** The run's own version's context; null while it isn't known (controls wait). */
  ctx: RunContext | null;
  /**
   * The run's pinned version's timer, when its versions are known (lap types and alerts read
   * it); otherwise one is made from the steps the run knows, or none when those are unknown.
   */
  timer?: Timer | null | undefined;
  /** The topic's name, for the controls' accessible names. */
  topic: string;
  actions: RunActions;
  /** The stop is queued. `totalMs` is the run's active time at the tap. */
  onStopped: (run: LocalRun, item: OutboxItem<RunEventPayload>, totalMs: number) => void;
  onDiscarded: () => void;
  /** Undo resume…: the discard of a reopened run, queued; the stop and its entry stay. */
  onReverted: () => void;
}) {
  const paused = run.status === 'paused';
  const now = useServerNow(!paused);
  // Null: the steps aren't known here yet (no step list, no Skip; the clock still runs).
  const steps: readonly TimerStep[] | null = ctx ? ctx.steps : run.steps;
  const timer = runTimer(pinned, steps);
  const total = activeMs(run.state, now);
  const segment = segmentMs(run.state, now);
  const open = run.state.open;
  const head = headline(run.state, run.status, timer);
  const alert = alertLine(run.state, timer, now);
  // A reopen queued from the entry, not acked yet (§1.2 row 11, timers2.md §5.3): the header
  // says "Resuming…" and there are no controls until the server answers.
  const resuming = run.resuming;
  const list = resuming ? [] : withRevert(runActions(run.state, run.status, timer, now), run);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [confirmRevert, setConfirmRevert] = useState(false);
  const cooling = useRunCooldown(run.topic_id);

  // Captured at render: a second tap before the screen catches up targets what it saw.
  const expect = expectOf(run, steps);
  const tap = (type: Parameters<RunActions['tap']>[2]) =>
    ctx ? actions.tap(run.id, ctx, type, {}, expect) : Promise.resolve(null);
  const stop = async () => {
    const item = await tap('stop');
    if (item) onStopped(run, item, activeMs(run.state, parseInstant(item.payload.event.at)));
  };
  const onAction = (a: RunAction) => {
    switch (a.kind.type) {
      case 'next':
      case 'lap':
      case 'skip':
      case 'pause':
      case 'resume':
        void tap(a.kind.type);
        return;
      case 'stop':
        void stop();
        return;
      case 'discard':
        setConfirmDiscard(true);
        return;
      case 'revert':
        setConfirmRevert(true);
        return;
      // Not an open run's (§1.2 rows 2, 12, 13).
      case 'start':
      case 'addDetails':
      case 'reopen':
        return;
    }
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
            {resuming ? 'Resuming…' : paused ? 'Paused' : 'Running'}
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
                {head.text}
              </span>
              <Duration ms={segment} label={head.text} className="text-muted" />
            </p>
          ) : null}
          {alert !== null ? (
            <p className="flex items-center gap-1.5 text-sm text-ink-soft" data-testid="alert-line">
              <Icon name="bell" className="size-3.5" />
              {alert}
            </p>
          ) : null}
        </div>

        <RunControls
          actions={list}
          busy={ctx === null || actions.busy || cooling}
          topic={topic}
          onAction={onAction}
        />

        <Steps run={run} steps={steps} segmentMs={segment} />
      </Card>

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
      {/* A revert is the run's discard after its reopen (timers2.md §3.4): the server restores
          the stop, and the outbox doesn't drop the queue for it (K6, §5.5). */}
      <ConfirmSheet
        open={confirmRevert}
        onClose={() => setConfirmRevert(false)}
        onConfirm={() => {
          void tap('discard').then((item) => {
            setConfirmRevert(false);
            if (item) onReverted();
          });
        }}
        title="Undo the resume?"
        body="The run goes back to how it was when you stopped it, and its entry stays saved."
        confirmLabel="Undo resume"
        cancelLabel="Keep timing"
        danger
        busy={actions.busy}
      />
    </>
  );
}

/**
 * Whether the run is open again after a reopen of its stop (§1.2 row 10): a `reopen` the fold
 * applied, from the server or queued here.
 */
function reopened(run: LocalRun): boolean {
  return run.events.some(
    (e) => e.type === 'reopen' && run.state.effects[e.id.toLowerCase()]?.effect === 'applied',
  );
}

/**
 * §1.2 row 10, until M1's `actions` returns it: a reopened run offers `revert` ("Undo
 * resume…") **instead of** `discard`, in the same destructive slot. `actions` takes the state
 * alone, which doesn't say the run was reopened; the run's events do.
 */
export function withRevert(list: readonly RunAction[], run: LocalRun): RunAction[] {
  if (!reopened(run)) return [...list];
  return list.map((a) =>
    a.kind.type === 'discard' ? { ...a, kind: { type: 'revert' }, id: 'revert' } : a,
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
    <ol
      aria-label="Steps"
      className="flex flex-col divide-y divide-dashed divide-line rounded-2xl border border-line"
    >
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

/** Idle: the topic's steps, and Start (with Resume under it while the last stop is resumable). */
export function RunStart({
  steps,
  disabled,
  busy,
  onStart,
  reopen = null,
  note,
}: {
  steps: readonly TimerStep[];
  disabled: boolean;
  busy: boolean;
  onStart: () => void;
  reopen?: ReopenOffer | null;
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
        <div className="flex flex-1 flex-col gap-2 sm:flex-none sm:flex-row-reverse">
          <Button
            size="lg"
            variant="primary"
            className="w-full sm:w-auto"
            disabled={disabled}
            loading={busy}
            icon={<Icon name="play" strokeWidth={2.4} />}
            onClick={onStart}
          >
            Start
          </Button>
          {reopen ? (
            <Button
              size="lg"
              variant="secondary"
              data-testid="run-reopen"
              aria-label={actionLabel({ type: 'reopen', target: '' }, reopen.topic)}
              disabled={disabled || busy}
              icon={<Icon name="restore" className="size-4.5" strokeWidth={2.4} />}
              onClick={reopen.onReopen}
            >
              Resume · {fmtDuration(reopen.totalMs)}
            </Button>
          ) : null}
        </div>
      </StickyActions>
    </>
  );
}
