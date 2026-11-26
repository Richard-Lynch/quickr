/**
 * The active card's controls (`CardControls`) for an open run: M1's
 * `actions(state, status, timer, now)` placed by `tileControls` (active-surfaces.md §1, §6.2)
 * — the primary (Lap or Next, never Stop) and Stop in the controls row, Pause or Resume in
 * the title row — with the titles, icons and accessible names of §1.3.
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
import { finishUrl, hasQuestions } from '../runs/RunTile';
import { useRunActions } from '../runs/useRunActions';
import type { IconName } from '../ui/Icon';
import { useToast } from '../ui/Toast';
import type { CardButton, CardControls } from './ActiveTopicCard';

/** §1.3's title, icon and accessible name of a card control's kind. */
function present(
  kind: RunAction['kind'],
  topicName: string,
): { title: string; label: string; icon: IconName } | null {
  switch (kind.type) {
    case 'next': {
      // Steps unknown (§1.2 row 9): `next("Next")` is a plain "Next", not "Next: Next".
      const title = kind.label === 'Next' ? 'Next' : `Next: ${kind.label}`;
      return { title, label: title, icon: 'chevronRight' };
    }
    case 'lap':
      return kind.nextTypeLabel === null
        ? { title: 'Lap', label: 'Lap', icon: 'flag' }
        : {
            title: `Lap → ${kind.nextTypeLabel}`,
            label: `Lap, then ${kind.nextTypeLabel}`,
            icon: 'flag',
          };
    case 'stop':
      return { title: 'Stop', label: `Stop ${topicName}`, icon: 'stop' };
    case 'pause':
      return { title: 'Pause', label: 'Pause', icon: 'pause' };
    case 'resume':
      return { title: 'Resume', label: 'Resume', icon: 'play' };
    default:
      // `tileControls` places only these kinds on the card.
      return null;
  }
}

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
  const button = (a: RunAction | null): CardButton | null => {
    const shown = a && present(a.kind, topic.name);
    if (!a || !shown) return null;
    const type = a.kind.type;
    return {
      ...shown,
      disabled: runCtx === null || taps.busy || !a.enabled,
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
