/**
 * Where a run's actions go on a surface (active-surfaces.md §1, D-1): the one primary, the
 * secondaries beside it, and the "More" sheet. Placement reads `role` only, never `kind`, so a
 * kind M1 starts returning later (`reopen`, `revert`) lands in its role's slot with no edit here.
 * The input is `actions(state, status, timer, now)` from `./model`, whose primary rule is
 * timers2.md §10's. The iOS app's `QuickrCore/Surfaces/RunControlsLayout.swift`.
 *
 * The run panel renders all three slots (§6.1); the active card renders `tileControls` (§6.2).
 */
import type { RunAction } from './model';

export interface ControlsLayout {
  /** The `primary` action; null when there is none (a closed run's `[]`, or row 13's lone `reopen`). */
  primary: RunAction | null;
  /** The `secondary` actions in input order: Stop, then Pause or Resume; Resume run when idle. */
  secondaries: RunAction[];
  /**
   * The sheet, in input order with every `destructive` action after the `overflow` ones. Also
   * holds anything without a slot of its own: a second `primary` (there is exactly one, §1.2, so
   * it never happens) or a role this build doesn't know. No action is ever dropped.
   */
  overflow: RunAction[];
}

/**
 * Places `actions` by role. Every action lands in exactly one slot; `enabled` is passed through
 * untouched, so a busy run (§1.2 row 14) keeps its layout with every button off.
 */
export function controlsLayout(actions: readonly RunAction[]): ControlsLayout {
  let primary: RunAction | null = null;
  const secondaries: RunAction[] = [];
  const overflow: RunAction[] = [];
  const destructive: RunAction[] = [];
  for (const action of actions) {
    if (action.role === 'primary' && primary === null) primary = action;
    else if (action.role === 'secondary') secondaries.push(action);
    else if (action.role === 'destructive') destructive.push(action);
    else overflow.push(action);
  }
  return { primary, secondaries, overflow: [...overflow, ...destructive] };
}

/**
 * The active card's controls (active-surfaces.md §6.2, as iOS §3.2): the primary and Stop in the
 * controls row, Pause or Resume as the title row's text button. The card has no sheet.
 */
export interface TileControls {
  primary: RunAction | null;
  stop: RunAction | null;
  /** Pause while running, Resume while paused. */
  pauseResume: RunAction | null;
}

/**
 * The card's three controls, from the secondaries' Stop and Pause/Resume. §6.2 puts those two in
 * different rows, the one place a kind picks a slot; other secondaries (an idle topic's Resume
 * run) are not the card's: the idle tile renders them (§6.3).
 */
export function tileControls(actions: readonly RunAction[]): TileControls {
  const { primary, secondaries } = controlsLayout(actions);
  return {
    primary,
    stop: secondaries.find((a) => a.kind.type === 'stop') ?? null,
    pauseResume:
      secondaries.find((a) => a.kind.type === 'pause' || a.kind.type === 'resume') ?? null,
  };
}
