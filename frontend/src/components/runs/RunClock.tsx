import { useState, useSyncExternalStore } from 'react';

import { serverNow } from '../../lib/runs/clock';
import { fmtDuration } from '../../lib/runs/format';
import { serverOffset } from '../../lib/runs/serverClock';
import { cn } from '../ui/cn';

export const TICK_MS = 250;

const read = () => serverNow(Date.now(), serverOffset());

// ---- one ticker for every running timer on screen --------------------------------------

let ticked = read();
const listeners = new Set<() => void>();
let interval: ReturnType<typeof setInterval> | undefined;

function tick(): void {
  ticked = read();
  listeners.forEach((l) => {
    l();
  });
}

function onVisible(): void {
  if (document.visibilityState === 'visible') tick();
}

function subscribeTicker(listener: () => void): () => void {
  listeners.add(listener);
  if (listeners.size === 1) {
    ticked = read();
    interval = setInterval(tick, TICK_MS);
    document.addEventListener('visibilitychange', onVisible);
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      clearInterval(interval);
      interval = undefined;
      document.removeEventListener('visibilitychange', onVisible);
    }
  };
}

const getTicked = () => ticked;
const noSubscription = () => () => undefined;

/**
 * Now on the server's clock (device time + offset, §5.1), the clock runs are timed on.
 * While `ticking`, it follows one shared ticker (a few times a second, so a timer never
 * visibly skips a second); otherwise it is read once when ticking stops (a paused or
 * closed run doesn't move).
 */
export function useServerNow(ticking: boolean): number {
  const [frozen, setFrozen] = useState(read);
  const [wasTicking, setWasTicking] = useState(ticking);
  if (wasTicking !== ticking) {
    // It just stopped (or started): freeze at this moment.
    setWasTicking(ticking);
    if (!ticking) setFrozen(read());
  }
  const live = useSyncExternalStore(
    ticking ? subscribeTicker : noSubscription,
    getTicked,
    getTicked,
  );
  return ticking ? live : frozen;
}

/** A duration as the run screens show it: `m:ss`, or `h:mm:ss` from one hour (§11.1). */
export function Duration({
  ms,
  className,
  label,
}: {
  ms: number;
  className?: string | undefined;
  /** For screen readers: what the duration is of. */
  label?: string;
}) {
  return (
    <span className={cn('font-mono tabular', className)}>
      {label ? <span className="sr-only">{label} </span> : null}
      {fmtDuration(ms)}
    </span>
  );
}
