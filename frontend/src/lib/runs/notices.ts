/**
 * The §11.4 notices: a tap from this device that the server answered as void, for a reason
 * the user should know about. Shown as a toast while the app is on screen
 * (`components/runs/RunNotices.tsx`), otherwise kept for the sync sheet.
 *
 * `stale`, `merged`, `already_paused` and `not_paused` are silent: they are double taps
 * that did what the user wanted.
 */
import { createStore, del, entries, set, type UseStore } from 'idb-keyval';

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
//
// Kept in IndexedDB beside the acked-runs record, so the sync sheet still lists them after
// the system ends the app (iOS does, freely). Toasted only when they arrive on screen.

export interface NoticeStore {
  all(): Promise<RunNotice[]>;
  put(n: RunNotice): Promise<void>;
  delete(id: string): Promise<void>;
}

export function idbNoticeStore(dbName = 'quickr-run-notices', storeName = 'items'): NoticeStore {
  let store: UseStore | null = null;
  const s = () => (store ??= createStore(dbName, storeName));
  return {
    all: async () => (await entries<string, RunNotice>(s())).map(([, v]) => v),
    put: (n) => set(n.id, n, s()),
    delete: (id) => del(id, s()),
  };
}

export function memoryNoticeStore(): NoticeStore {
  const map = new Map<string, RunNotice>();
  return {
    all: () => Promise.resolve([...map.values()]),
    put: (n) => {
      map.set(n.id, n);
      return Promise.resolve();
    },
    delete: (id) => {
      map.delete(id);
      return Promise.resolve();
    },
  };
}

let store: NoticeStore = idbNoticeStore();
let notices: readonly RunNotice[] = [];
const listeners = new Set<() => void>();
const arrivals = new Set<(n: RunNotice) => void>();

function emit(next: readonly RunNotice[]): void {
  notices = next;
  listeners.forEach((l) => {
    l();
  });
}

function persist(op: Promise<void>): void {
  op.catch((err: unknown) => {
    console.error('[runs] could not store a notice', err);
  });
}

/** A new notice: kept, and announced to {@link subscribeNoticeArrivals}. */
export function pushRunNotice(n: RunNotice): void {
  if (notices.some((x) => x.id === n.id)) return;
  emit([...notices, n]);
  persist(store.put(n));
  arrivals.forEach((l) => {
    l(n);
  });
}

export function dismissRunNotice(id: string): void {
  emit(notices.filter((n) => n.id !== id));
  persist(store.delete(id));
}

/** Read the stored notices (once, at start). They are listed, never toasted. */
export async function loadRunNotices(): Promise<void> {
  try {
    const stored = await store.all();
    const known = new Set(notices.map((n) => n.id));
    emit([...notices, ...stored.filter((n) => !known.has(n.id))]);
  } catch (err) {
    console.error('[runs] could not read notices', err);
  }
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

/** Each notice as it arrives (not those loaded from storage). */
export function subscribeNoticeArrivals(listener: (n: RunNotice) => void): () => void {
  arrivals.add(listener);
  return () => {
    arrivals.delete(listener);
  };
}

/** Tests: another store, and no notices. */
export function setNoticeStore(next: NoticeStore): void {
  store = next;
  emit([]);
}

/** Tests: forget every notice. */
export function clearRunNotices(): void {
  for (const n of notices) persist(store.delete(n.id));
  emit([]);
}
