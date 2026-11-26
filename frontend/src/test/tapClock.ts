/**
 * The run tap cooldown on a clock the test moves by hand (#188). On the real clock a loaded
 * machine stretches the time between two taps past the cooldown, or ends a cooldown before
 * the test has looked at the disabled controls; on this one only `advance` moves time.
 */
import { act } from '@testing-library/react';

import {
  RUN_TAP_COOLDOWN_MS,
  runTapClockMoved,
  setRunTapCooldown,
} from '../components/runs/useRunActions';

export interface TapClock {
  /** Move the clock by `ms` (back, when negative), and let the controls re-read it. */
  advance: (ms: number) => void;
}

/** Turn the cooldown on (`ms`, the app's by default) with time standing still at 0. */
export function tapCooldownOn(ms: number = RUN_TAP_COOLDOWN_MS): TapClock {
  let now = 0;
  setRunTapCooldown(ms, () => now);
  return {
    advance: (by) => {
      act(() => {
        now += by;
        runTapClockMoved();
      });
    },
  };
}
