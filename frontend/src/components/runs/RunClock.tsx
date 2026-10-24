import { useEffect, useState } from 'react';

import { serverNow } from '../../lib/runs/clock';
import { fmtDuration } from '../../lib/runs/format';
import { serverOffset } from '../../lib/runs/serverClock';
import { cn } from '../ui/cn';

const TICK_MS = 250;

/**
 * Now on the server's clock (device time + offset, §5.1), the clock runs are timed on.
 * Re-renders a few times a second while `ticking`, so a timer never visibly skips a
 * second; frozen otherwise (a paused or closed run doesn't move).
 */
export function useServerNow(ticking: boolean): number {
  const [now, setNow] = useState(() => serverNow(Date.now(), serverOffset()));
  useEffect(() => {
    const tick = () => setNow(serverNow(Date.now(), serverOffset()));
    tick();
    if (!ticking) return;
    const t = window.setInterval(tick, TICK_MS);
    const onVisible = () => {
      if (document.visibilityState === 'visible') tick();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearInterval(t);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [ticking]);
  return now;
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
    <span
      className={cn('font-mono tabular', className)}
      {...(label ? { 'aria-label': `${label} ${fmtDuration(ms)}` } : {})}
    >
      {fmtDuration(ms)}
    </span>
  );
}
