/**
 * Run alerts while the PWA is open (timers2.md §9.2): one `setTimeout` to the next alert
 * over every local run (`lib/runs/alerts.ts` plans it), recomputed on every `LocalRun`
 * change and on `visibilitychange`. An alert fires a toast ("{label} · {segment}"),
 * `navigator.vibrate([200,100,200])` (a no-op on iOS), a short tone (OQ-13, `useRunAudio`)
 * and, when notifications are granted, `registration.showNotification`. Mute (App settings)
 * silences the tone and vibration, not the toast.
 *
 * Only while the page is visible: nothing fires while hidden (nothing is pushed). On return
 * an alert at most 30 s late fires at once; an older one is dropped.
 */
import { useQueries } from '@tanstack/react-query';
import { useEffect, useMemo, useState } from 'react';

import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import {
  alertKeys,
  alertSchedule,
  type AlertRun,
  type AlertTimer,
  type PlannedAlert,
} from '../../lib/runs/alerts';
import { serverNow } from '../../lib/runs/clock';
import { isOpen, type LocalRun } from '../../lib/runs/localView';
import { serverOffset } from '../../lib/runs/serverClock';
import { useRuns } from '../../lib/runs/useRuns';
import { getRegistration } from '../pwa/swRegistration';
import { useToast, type ToastInput } from '../ui/Toast';
import { timerOf, topicVersionsOptions } from './context';
import { alertsMuted, playAlertTone, useRunAudioUnlock } from './useRunAudio';

export interface AlertSource {
  run: AlertRun;
  timer: AlertTimer | null | undefined;
  /** For the notification's title and link; null while unknown. */
  topic: { name: string; slug: string } | null;
}

// ---- alerts fired already (this tab's session) ------------------------------------------

const FIRED_KEY = 'quickr.firedAlerts';
const MAX_FIRED = 200;
let fired: Set<string> | null = null;

function firedSet(): Set<string> {
  if (fired) return fired;
  fired = new Set();
  try {
    const raw: unknown = JSON.parse(sessionStorage.getItem(FIRED_KEY) ?? '[]');
    if (Array.isArray(raw)) for (const k of raw) if (typeof k === 'string') fired.add(k);
  } catch {
    // nothing readable: a reload may refire an alert under 30 s late
  }
  return fired;
}

function markFired(alert: PlannedAlert): void {
  const set = firedSet();
  for (const k of alertKeys(alert)) set.add(k);
  const keep = [...set].slice(-MAX_FIRED);
  fired = new Set(keep);
  try {
    sessionStorage.setItem(FIRED_KEY, JSON.stringify(keep));
  } catch {
    // memory only
  }
}

/** Tests: forget the fired alerts. */
export function resetFiredAlerts(): void {
  fired = null;
  try {
    sessionStorage.removeItem(FIRED_KEY);
  } catch {
    // nothing stored
  }
}

// ---- firing ---------------------------------------------------------------------------

/** `setTimeout`'s ceiling (a longer delay fires at once). */
const MAX_DELAY_MS = 2 ** 31 - 1;

function vibrate(): void {
  try {
    if ('vibrate' in navigator) navigator.vibrate([200, 100, 200]);
  } catch {
    // not allowed here
  }
}

function notificationsGranted(): boolean {
  try {
    return typeof Notification !== 'undefined' && Notification.permission === 'granted';
  } catch {
    return false;
  }
}

async function notify(alert: PlannedAlert, src: AlertSource, muted: boolean): Promise<void> {
  const reg =
    getRegistration() ??
    ('serviceWorker' in navigator
      ? await navigator.serviceWorker.getRegistration().catch(() => undefined)
      : undefined);
  if (!reg) return;
  await reg.showNotification(src.topic?.name ?? 'quickR', {
    body: `${alert.label} · ${alert.segment}`,
    tag: `quickr.alert.${alert.id}`,
    data: { url: src.topic ? `/t/${src.topic.slug}/record` : '/' },
    silent: muted,
  });
}

function fire(alert: PlannedAlert, src: AlertSource, toast: (t: ToastInput) => void): void {
  markFired(alert);
  const muted = alertsMuted();
  toast({ title: `${alert.label} · ${alert.segment}`, tone: 'info', duration: 8000 });
  if (!muted) {
    vibrate();
    playAlertTone();
  }
  if (notificationsGranted()) {
    notify(alert, src, muted).catch((err: unknown) => {
      console.warn('[runs] alert notification failed', err);
    });
  }
}

/** The scheduler over the given runs (exported for tests; `RunAlerts` feeds it). */
export function RunAlertsFor({ sources }: { sources: readonly AlertSource[] }) {
  const { toast } = useToast();
  // Bumped by the timeout and by visibilitychange: the schedule is recomputed.
  const [tick, setTick] = useState(0);
  useRunAudioUnlock();

  useEffect(() => {
    const onVisibility = () => setTick((t) => t + 1);
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, []);

  useEffect(() => {
    // Hidden: nothing fires and nothing waits; the return recomputes.
    if (document.visibilityState === 'hidden') return;
    const now = serverNow(Date.now(), serverOffset());
    const { due, next } = alertSchedule(sources, now, firedSet());
    for (const alert of due) {
      const src = sources.find((s) => s.run.id.toLowerCase() === alert.run_id);
      if (src) fire(alert, src, toast);
    }
    if (!next) return;
    const id = window.setTimeout(
      () => setTick((t) => t + 1),
      Math.min(MAX_DELAY_MS, Math.max(0, next.at - now)),
    );
    return () => window.clearTimeout(id);
  }, [sources, tick, toast]);

  return null;
}

const TOPIC_STALE_MS = 5 * 60_000;

/**
 * App-wide (mounted in `AppShell`): the local view's open runs, each with its pinned
 * version's timer (`listTopicVersions`; the queued taps' steps and lap types while that
 * isn't known) and its topic.
 */
export function RunAlerts() {
  const { runs } = useRuns();
  const open = useMemo(() => runs.filter(isOpen), [runs]);
  const versions = useQueries({
    queries: open.map((r) => topicVersionsOptions(r.topic_id)),
  });
  const topics = useQueries({
    queries: open.map((r) => ({
      ...getTopicOptions({ path: { ref: r.topic_id } }),
      staleTime: TOPIC_STALE_MS,
      enabled: r.topic === null,
    })),
  });
  const versionData = versions.map((v) => v.data);
  const topicData = topics.map((t) => t.data);
  const key = JSON.stringify([
    versions.map((v) => v.dataUpdatedAt),
    topics.map((t) => t.dataUpdatedAt),
  ]);
  const sources = useMemo(
    () =>
      open.map((run, i): AlertSource => {
        const detail = topicData[i];
        return {
          run,
          timer: timerFor(run, versionData[i]),
          topic: run.topic ?? (detail ? { name: detail.name, slug: detail.slug } : null),
        };
      }),
    // versionData/topicData are new arrays each render; `key` says when they change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [open, key],
  );
  return <RunAlertsFor sources={sources} />;
}

function timerFor(
  run: LocalRun,
  versions: Parameters<typeof timerOf>[0],
): AlertTimer | null | undefined {
  const timer = timerOf(versions, run.version);
  if (timer !== undefined) return timer;
  // Versions not known (offline, nothing cached): the queued taps' copy, if any.
  return run.steps || run.laps ? { steps: run.steps ?? [], laps: run.laps ?? [] } : undefined;
}
