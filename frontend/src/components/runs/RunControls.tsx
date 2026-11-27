/**
 * The run panel's controls (active-surfaces.md §6.1, as the iOS `RunControls` of §2.2): the
 * one primary at 72 px, the secondaries beside each other at 56 px (Stop, Pause or Resume), and
 * a "More" sheet for the rest (Skip, then Discard run…). Placement is `controlsLayout`'s, by
 * role (D-1); the only per-kind code here is the title and icon table of §1.3.
 *
 * No duplication (§2.2): each action renders once, in its role's slot. An empty `actions` (a
 * queued reopen before its ack, §1.2 row 11) renders nothing.
 */
import { useState } from 'react';

import { Button } from '../ui/Button';
import { cn } from '../ui/cn';
import { Icon, type IconName } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';
import { controlsLayout } from './controlsLayout';
import type { RunAction, RunActionKind } from './model';

/** The button's text (§1.3). `…` marks an action that confirms first. */
export function actionTitle(kind: RunActionKind): string {
  switch (kind.type) {
    case 'start':
      return 'Start';
    case 'next':
      // Steps unknown (§1.2 row 9): the model's `next("")` reads a plain "Next" (§1.3).
      return kind.label === '' ? 'Next' : `Next: ${kind.label}`;
    case 'lap':
      return kind.nextTypeLabel === null ? 'Lap' : `Lap → ${kind.nextTypeLabel}`;
    case 'skip':
      return `Skip ${kind.label}`;
    case 'pause':
      return 'Pause';
    case 'resume':
      return 'Resume';
    case 'stop':
      return 'Stop';
    case 'addDetails':
      return 'Add details';
    case 'reopen':
      return 'Resume run';
    case 'revert':
      return 'Undo resume…';
    case 'discard':
      return 'Discard run…';
  }
}

/** The accessible name (§1.3 "VoiceOver / aria-label"). */
export function actionLabel(kind: RunActionKind, topic: string): string {
  switch (kind.type) {
    case 'start':
      return `Start ${topic}`;
    case 'lap':
      return kind.nextTypeLabel === null ? 'Lap' : `Lap, then ${kind.nextTypeLabel}`;
    case 'stop':
      return `Stop ${topic}`;
    case 'addDetails':
      return `Add details to ${topic}`;
    case 'reopen':
      return `Resume the last run of ${topic}`;
    case 'revert':
      return 'Undo the resume and keep the stop';
    case 'discard':
      return 'Discard run';
    case 'next':
    case 'skip':
    case 'pause':
    case 'resume':
      return actionTitle(kind);
  }
}

/** §1.3's PWA icons; `restore` stands in for the table's `undo` (the PWA set has no `undo`). */
const ICON: Record<RunActionKind['type'], IconName> = {
  start: 'play',
  next: 'chevronRight',
  lap: 'flag',
  skip: 'skip',
  pause: 'pause',
  resume: 'play',
  stop: 'stop',
  addDetails: 'edit',
  reopen: 'restore',
  revert: 'restore',
  discard: 'trash',
};

/** The action's icon (§1.3), for the surfaces that render a kind outside `RunControls`. */
export function actionIcon(kind: RunActionKind): IconName {
  return ICON[kind.type];
}

export function RunControls({
  actions,
  busy,
  topic,
  onAction,
  tinted = false,
}: {
  /** `actions(state, status, timer, now)` from `./model`, in display order. */
  actions: readonly RunAction[];
  /** A tap is being enqueued, or the run's context isn't known yet: every button is off. */
  busy: boolean;
  /** The topic's name, for the accessible names of Stop and its kin (§1.3). */
  topic: string;
  onAction: (action: RunAction) => void;
  /** The topic has a colour: the hero primary fills with its tint (appearance.md §6.4, #286). */
  tinted?: boolean;
}) {
  const { primary, secondaries, overflow } = controlsLayout(actions);
  const [more, setMore] = useState(false);
  const off = (a: RunAction) => busy || !a.enabled;
  if (!primary && secondaries.length === 0 && overflow.length === 0) return null;

  return (
    <div className="flex flex-col gap-2" role="group" aria-label="Run controls">
      {primary ? (
        <Button
          size="hero"
          variant={tinted ? 'topic' : 'primary'}
          className="w-full min-w-0"
          data-testid="run-primary"
          aria-label={actionLabel(primary.kind, topic)}
          disabled={off(primary)}
          icon={<Icon name={ICON[primary.kind.type]} strokeWidth={2.6} />}
          onClick={() => onAction(primary)}
        >
          <span className="min-w-0 break-words">{actionTitle(primary.kind)}</span>
        </Button>
      ) : null}

      {secondaries.length > 0 || overflow.length > 0 ? (
        // Wraps rather than squeezing: on a narrow or zoomed screen Pause/Resume and More move
        // to a second line before a label would truncate.
        <div className="flex flex-wrap gap-2">
          {secondaries.map((a) => (
            // `cn` doesn't merge, so nothing here restates a property `lg`/`secondary` set: the
            // padding narrows by breakpoint (px-7 leaves no room for "Pause" beside Stop and More
            // at 390 px) and Stop's danger colour sits on its icon and label.
            <Button
              key={a.id}
              size="lg"
              variant="secondary"
              className="min-w-[7.5rem] flex-1 max-sm:px-3"
              data-testid={`run-${a.id}`}
              aria-label={actionLabel(a.kind, topic)}
              disabled={off(a)}
              icon={
                <Icon
                  name={ICON[a.kind.type]}
                  className={cn('size-4.5', a.kind.type === 'stop' && 'text-danger')}
                  strokeWidth={2.4}
                />
              }
              onClick={() => onAction(a)}
            >
              <span className={cn('truncate', a.kind.type === 'stop' && 'text-danger')}>
                {actionTitle(a.kind)}
              </span>
            </Button>
          ))}
          {overflow.length > 0 ? (
            <button
              type="button"
              aria-label="More"
              title="More"
              data-testid="run-more"
              className="inline-flex size-14 shrink-0 items-center justify-center rounded-full border border-line-strong bg-surface text-ink-soft transition-colors hover:bg-sunken hover:text-ink active:scale-95 disabled:pointer-events-none disabled:opacity-50 motion-reduce:active:scale-none"
              disabled={busy}
              onClick={() => setMore(true)}
            >
              <Icon name="dots" className="size-5" strokeWidth={3} />
            </button>
          ) : null}
        </div>
      ) : null}

      <Sheet open={more} onClose={() => setMore(false)} title="More">
        <ul className="flex flex-col gap-2 pb-2" aria-label="More run actions">
          {overflow.map((a) => (
            <li key={a.id}>
              {/* A plain button, not `Button size="lg"`: that fixes one line (`h-14
                  whitespace-nowrap`), and "Skip {step}" names a step the headline may not
                  (after a lap, the next one), so the item wraps and grows instead. */}
              <button
                type="button"
                className={cn(
                  'flex min-h-14 w-full items-center gap-2 rounded-[1.75rem] px-5 py-3 text-left text-base font-semibold transition-colors active:scale-[0.98] disabled:pointer-events-none disabled:opacity-50 motion-reduce:active:scale-none',
                  a.role === 'destructive'
                    ? 'text-danger hover:bg-danger-soft'
                    : 'border border-line-strong bg-surface text-ink hover:bg-sunken',
                )}
                data-testid={`run-${a.id}`}
                aria-label={actionLabel(a.kind, topic)}
                disabled={off(a)}
                onClick={() => {
                  setMore(false);
                  onAction(a);
                }}
              >
                <Icon name={ICON[a.kind.type]} className="size-4.5 shrink-0" />
                <span className="min-w-0 break-words">{actionTitle(a.kind)}</span>
              </button>
            </li>
          ))}
        </ul>
      </Sheet>
    </div>
  );
}
