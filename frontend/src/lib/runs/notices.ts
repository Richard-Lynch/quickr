/**
 * The §11.4 notices: a tap from this device that the server answered as void, for a reason
 * the user should know about. Shown as a toast while the app is on screen
 * (`components/runs/RunNotices.tsx`), otherwise kept for the sync sheet.
 *
 * `stale`, `merged`, `already_paused` and `not_paused` are silent: they are double taps
 * that did what the user wanted.
 */
import type { RunEventResult } from '../../client/types.gen';
import type { RunEventPayload } from '../outbox/kinds';
import type { OutboxItem } from '../outbox/types';

export interface RunNotice {
  /** The event's id. */
  id: string;
  text: string;
}

const TAP_NAMES: Record<RunEventPayload['event']['type'], string> = {
  start: 'Start',
  next: 'Next',
  lap: 'Lap',
  skip: 'Skip',
  pause: 'Pause',
  resume: 'Resume',
  stop: 'Stop',
  finish: 'details',
  discard: 'Discard',
};

function clockTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

/** The notice for a run event's answer, or null when there is nothing to say. */
export function noticeFor(
  item: OutboxItem<RunEventPayload>,
  result: Pick<RunEventResult, 'event' | 'run'>,
): RunNotice | null {
  if (result.event.effect !== 'void') return null;
  const topic = item.payload.topic.name;
  const tap = TAP_NAMES[item.payload.event.type];
  const text = (() => {
    switch (result.event.reason) {
      case 'after_stop':
        return result.run.ended_at
          ? `${topic} was already stopped at ${clockTime(result.run.ended_at)}, so your ${tap} wasn’t added.`
          : `${topic} was already stopped, so your ${tap} wasn’t added.`;
      case 'run_edited':
        return `${topic}’s times were edited, so your ${tap} wasn’t added.`;
      case 'entry_deleted':
        return `${topic}’s run was deleted.`;
      case 'already_closed':
        return `${topic} was already stopped.`;
      default:
        return null;
    }
  })();
  return text === null ? null : { id: item.id, text };
}

// ---- the notices not yet shown ---------------------------------------------------------

let notices: readonly RunNotice[] = [];
const listeners = new Set<() => void>();

function emit(next: readonly RunNotice[]): void {
  notices = next;
  listeners.forEach((l) => {
    l();
  });
}

export function pushRunNotice(n: RunNotice): void {
  if (notices.some((x) => x.id === n.id)) return;
  emit([...notices, n]);
}

export function dismissRunNotice(id: string): void {
  emit(notices.filter((n) => n.id !== id));
}

export function getRunNotices(): readonly RunNotice[] {
  return notices;
}

export function subscribeRunNotices(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Tests: forget every notice. */
export function clearRunNotices(): void {
  emit([]);
}
