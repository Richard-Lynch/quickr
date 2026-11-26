/**
 * The active card's controls (`CardControls`) for an open run: M1's
 * `actions(state, status, timer, now)` placed by `tileControls` (active-surfaces.md §1, §6.2)
 * — the primary (Lap or Next, never Stop) and Stop in the controls row, Pause or Resume in
 * the title row — with §1.3's titles, icons and names from `RunControls`' one table.
 */
import { useNavigate } from 'react-router';

import type { RunContext, TapType } from '../../lib/runs/actions';
import { fmtDuration } from '../../lib/runs/format';
import { parseInstant } from '../../lib/runs/instant';
import type { LocalRun } from '../../lib/runs/localView';
import type { Timer } from '../../lib/runs/types';
import { timerOf, useRunContext, useTopicVersions } from '../runs/context';
import { tileControls } from '../runs/controlsLayout';
import { actions as runActions, activeMs, expectOf, type RunAction } from '../runs/model';
import { useServerNow } from '../runs/RunClock';
import { actionIcon, actionLabel, actionTitle } from '../runs/RunControls';
import { finishUrl, hasQuestions } from '../runs/RunTile';
import { useRunActions, useRunCooldown } from '../runs/useRunActions';
import { useToast } from '../ui/Toast';
import type { CardButton, CardControls } from './ActiveTopicCard';

/** The run's pinned version's timer; null (steps unknown, the v1 fallback) until it's known. */
function timerFor(versions: Parameters<typeof timerOf>[0], run: LocalRun): Timer | null {
  const known = timerOf(versions, run.version);
  if (known !== undefined) return known;
  return run.steps ? { steps: [...run.steps] } : null;
}

/** The card's controls, and the run's timer (for its headline and alert line). */
export function useActiveCardControls(
  topic: RunContext['topic'],
  run: LocalRun,
): { controls: CardControls; timer: Timer | null } {
  const taps = useRunActions();
  const navigate = useNavigate();
  const { toast } = useToast();
  const versions = useTopicVersions(run.topic_id);
  const runCtx = useRunContext(run, topic);
  const now = useServerNow(run.status === 'running');
  const timer = timerFor(versions.data, run);
  const layout = tileControls(runActions(run.state, run.status, timer, now));
  // Captured at render: a second tap before the card catches up targets what it showed.
  const expect = expectOf(run, runCtx ? runCtx.steps : run.steps);

  const tap = (type: TapType) =>
    runCtx ? taps.tap(run.id, runCtx, type, {}, expect) : Promise.resolve(null);
  const stop = () => {
    void tap('stop').then((item) => {
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
  // The topic's shared tap cooldown, from whichever surface tapped (as the run panel, §2.2).
  const cooling = useRunCooldown(run.topic_id);
  const button = (a: RunAction | null): CardButton | null => {
    if (!a) return null;
    const type = a.kind.type;
    return {
      title: actionTitle(a.kind),
      label: actionLabel(a.kind, topic.name),
      icon: actionIcon(a.kind),
      disabled: runCtx === null || taps.busy || cooling || !a.enabled,
      onTap: () => {
        if (type === 'stop') stop();
        else if (type === 'next' || type === 'lap' || type === 'pause' || type === 'resume')
          void tap(type);
      },
    };
  };

  const pauseResume = button(layout.pauseResume);
  return {
    controls: {
      primary: button(layout.primary),
      stop: button(layout.stop),
      pauseResume: pauseResume && { ...pauseResume, paused: run.status === 'paused' },
    },
    timer,
  };
}
