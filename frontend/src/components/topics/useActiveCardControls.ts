/**
 * The active card's controls (`CardControls`) for an open run.
 *
 * Seam: this is today's tile buttons (timers.md §11.1: Next while a named step remains,
 * else Stop), with Stop beside a Next and Pause/Resume in the title row. Phase 2 of
 * F2-HOME replaces the body with M2-MODEL-ADOPT's tile layout over M1's
 * `actions(run.state, run.status, timer, now)` (active-surfaces.md §1, §6.2), which makes
 * Lap the primary; `ActiveTopicCard` does not change.
 */
import { useNavigate } from 'react-router';

import type { RunContext } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { parseInstant } from '../../lib/runs/instant';
import type { LocalRun } from '../../lib/runs/localView';
import { useRunContext, useTopicVersions } from '../runs/context';
import { activeMs, expectOf, primaryAction } from '../runs/model';
import { finishUrl, hasQuestions } from '../runs/RunTile';
import { useRunActions } from '../runs/useRunActions';
import { useToast } from '../ui/Toast';
import type { CardControls } from './ActiveTopicCard';

export function useActiveCardControls(topic: RunContext['topic'], run: LocalRun): CardControls {
  const actions = useRunActions();
  const navigate = useNavigate();
  const { toast } = useToast();
  const versions = useTopicVersions(run.topic_id);
  const runCtx = useRunContext(run, topic);
  const steps = runCtx ? runCtx.steps : run.steps;
  const primary = primaryAction(run, steps);
  // Captured at render: a second tap before the card catches up targets what it showed.
  const expect = expectOf(run, steps);
  const disabled = runCtx === null || actions.busy;
  const paused = run.status === 'paused';

  const stop = () => {
    if (!runCtx) return;
    void actions.tap(run.id, runCtx, 'stop', {}, expect).then((item) => {
      if (!item) return;
      // A version with questions opens the answers form; one without says it's saved.
      if (hasQuestions(versions.data, run.version) !== false) {
        void navigate(finishUrl(topic.slug, run));
      } else {
        const total = activeMs(run.state, parseInstant(item.payload.event.at));
        toast({ title: `Saved ${topic.name}: ${fmtDuration(total)}` });
      }
    });
  };
  const stopButton = {
    title: 'Stop',
    label: `Stop · ${topic.name}`,
    icon: 'stop',
    disabled,
    onTap: stop,
  } as const;

  return {
    primary:
      primary.type === 'next'
        ? {
            title: primary.label,
            label: `${primary.label} · ${topic.name}`,
            icon: 'chevronRight',
            disabled,
            onTap: () => {
              if (runCtx) void actions.tap(run.id, runCtx, 'next', {}, expect);
            },
          }
        : stopButton,
    // On the last step Stop is today's primary: never a second Stop beside it.
    stop: primary.type === 'next' ? stopButton : null,
    pauseResume: {
      paused,
      title: paused ? 'Resume' : 'Pause',
      label: `${paused ? 'Resume' : 'Pause'} ${topic.name}`,
      icon: paused ? 'play' : 'pause',
      disabled,
      onTap: () => {
        if (runCtx) void actions.tap(run.id, runCtx, paused ? 'resume' : 'pause', {}, expect);
      },
    },
  };
}
