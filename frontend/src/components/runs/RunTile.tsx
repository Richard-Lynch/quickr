/**
 * A timed topic's home tile parts (timers.md §11.1, §11.5): idle shows Start; running shows
 * "Running · 4:12", the segment label and Next or Stop; finishing shows "Add details".
 * `TopicTile` lays them out like its Log action.
 */
import { Link, useNavigate } from 'react-router';

import type { TopicVersionOut } from '../../client';
import type { RunContext } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { parseInstant } from '../../lib/runs/instant';
import { isOpen, type LocalRun } from '../../lib/runs/localView';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';
import { useToast } from '../ui/Toast';
import { contextFor, useRunContext, useTopicVersions } from './context';
import { activeMs, expectOf, primaryAction, segmentMs, type PrimaryAction } from './model';
import { useServerNow } from './RunClock';
import { useRunActions } from './useRunActions';

type TopicRef = RunContext['topic'];

/** The record page's answers form for a run that Stop just ended (`RecordPage`). */
export function finishUrl(slug: string, run: Pick<LocalRun, 'id' | 'version'>): string {
  return `/t/${slug}/record?finish=${encodeURIComponent(run.id)}&v=${String(run.version)}`;
}

/** Whether the run's version has questions to answer after Stop, or null if unknown. */
export function hasQuestions(
  versions: readonly TopicVersionOut[] | undefined,
  version: number,
): boolean | null {
  const v = versions?.find((x) => x.version === version);
  return v ? v.questions.length > 0 : null;
}

/** "Running · 4:12" (or "Paused · …") and the open segment; "Add details" when finishing. */
export function RunStatus({ run }: { run: LocalRun }) {
  const now = useServerNow(run.status === 'running');
  if (run.status === 'finishing') {
    return (
      <span className="inline-flex h-6 items-center gap-1 rounded-full bg-warn-soft px-2.5 text-xs font-semibold whitespace-nowrap text-warn">
        <Icon name="edit" className="size-3.5" strokeWidth={2.4} />
        Add details
      </span>
    );
  }
  const paused = run.status === 'paused';
  const open = run.state.open;
  return (
    <>
      <span
        className={cn(
          'inline-flex h-6 items-center gap-1.5 rounded-full px-2.5 text-xs font-semibold whitespace-nowrap',
          paused ? 'bg-warn-soft text-warn' : 'bg-accent-soft text-accent-strong',
        )}
      >
        <Icon name={paused ? 'pause' : 'timer'} className="size-3.5" strokeWidth={2.4} />
        {paused ? 'Paused' : 'Running'} ·{' '}
        <span className="font-mono tabular">{fmtDuration(activeMs(run.state, now))}</span>
      </span>
      {open ? (
        <span className="truncate">
          <strong className="font-semibold text-ink-soft">{open.label}</strong>{' '}
          <span className="font-mono tabular">{fmtDuration(segmentMs(run.state, now))}</span>
        </span>
      ) : null}
    </>
  );
}

const ACTION =
  'relative z-10 flex w-[5.25rem] shrink-0 flex-col items-center justify-center gap-1 border-l px-1 text-[0.95rem] font-semibold transition-[background-color,transform] select-none active:scale-[0.97] disabled:cursor-wait disabled:opacity-60';

/**
 * The tile's action: Start when idle, the primary button (Next or Stop) while running,
 * and "Add details" for a finishing run.
 */
export function RunTileAction({
  topic,
  run,
  versions,
  currentVersion,
  loud,
}: {
  topic: TopicRef;
  /** The topic's current version: a start is pinned to it. */
  currentVersion: number;
  run: LocalRun | undefined;
  versions: readonly TopicVersionOut[] | undefined;
  /** The topic is due: the loud version, as the Log action. */
  loud: boolean;
}) {
  const actions = useRunActions();
  const primary = useRunPrimary(topic, run);

  if (run?.status === 'finishing') {
    return (
      <Link
        to={finishUrl(topic.slug, run)}
        aria-label={`Add details to ${topic.name}`}
        className={cn(ACTION, 'border-line bg-warn-soft text-warn hover:brightness-[0.97]')}
      >
        <Icon name="edit" className="size-6" strokeWidth={2.4} />
        <span className="text-center text-[0.8rem] leading-tight">Add details</span>
      </Link>
    );
  }

  if (primary) {
    return (
      <button
        type="button"
        aria-label={`${primary.label} · ${topic.name}`}
        disabled={primary.disabled}
        onClick={primary.onTap}
        className={cn(
          ACTION,
          'border-accent-strong/30 bg-accent text-on-accent hover:bg-accent-strong',
        )}
      >
        <Icon
          name={primary.type === 'next' ? 'chevronRight' : 'stop'}
          className="size-6"
          strokeWidth={2.6}
        />
        {primary.type === 'next' ? 'Next' : 'Stop'}
      </button>
    );
  }

  const ctx = contextFor(topic, versions, currentVersion);
  return (
    <button
      type="button"
      aria-label={`Start ${topic.name}`}
      disabled={ctx === null || actions.busy}
      onClick={() => {
        if (ctx) void actions.start(ctx);
      }}
      className={cn(
        ACTION,
        loud
          ? 'border-accent-strong/30 bg-accent text-on-accent hover:bg-accent-strong'
          : 'border-line bg-accent-soft text-accent-strong hover:brightness-[0.97]',
      )}
    >
      <Icon name="play" className="size-6" strokeWidth={2.4} />
      Start
    </button>
  );
}

/**
 * An open run's primary button (§11.1): Next while a named step remains, else Stop. After
 * a Stop, a version with questions opens the answers form; one without says it's saved.
 * Null when the run isn't open.
 */
export function useRunPrimary(
  topic: TopicRef,
  run: LocalRun | undefined,
): (PrimaryAction & { disabled: boolean; onTap: () => void }) | null {
  const actions = useRunActions();
  const navigate = useNavigate();
  const { toast } = useToast();
  const versions = useTopicVersions(run?.topic_id ?? '', Boolean(run));
  const runCtx = useRunContext(run, topic);
  if (!run || !isOpen(run)) return null;
  const steps = runCtx?.steps ?? run.steps ?? [];
  const primary = primaryAction(run, steps);
  const expect = expectOf(run, steps);
  return {
    ...primary,
    disabled: runCtx === null || actions.busy,
    onTap: () => {
      if (!runCtx) return;
      if (primary.type === 'next') {
        void actions.tap(run.id, runCtx, 'next', {}, expect);
        return;
      }
      void actions.tap(run.id, runCtx, 'stop', {}, expect).then((item) => {
        if (!item) return;
        if (hasQuestions(versions.data, run.version) !== false) {
          void navigate(finishUrl(topic.slug, run));
        } else {
          const total = activeMs(run.state, parseInstant(item.payload.event.at));
          toast({ title: `Saved ${topic.name}: ${fmtDuration(total)}` });
        }
      });
    },
  };
}
