/**
 * Delayed commits for "Undo" toasts: the destructive request is only sent once the
 * undo window has passed. Lives outside React so navigating away doesn't cancel it.
 * If the page is hidden / closed first, pending commits run immediately (best effort)
 * rather than being silently dropped.
 */
export const UNDO_WINDOW_MS = 6_000;

interface PendingCommit {
  timer: ReturnType<typeof setTimeout>;
  commit: () => unknown;
}

const pending = new Map<number, PendingCommit>();
let nextId = 1;
let listening = false;

function run(id: number): void {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  clearTimeout(p.timer);
  try {
    void Promise.resolve(p.commit()).catch((err: unknown) => {
      console.error('[undo] commit failed', err);
    });
  } catch (err) {
    console.error('[undo] commit failed', err);
  }
}

export function flushUndoables(): void {
  [...pending.keys()].forEach(run);
}

function listen(): void {
  if (listening || typeof window === 'undefined') return;
  listening = true;
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flushUndoables();
  });
  window.addEventListener('pagehide', flushUndoables);
}

export interface Undoable {
  /** Cancel the commit. Returns false if it already ran. */
  undo: () => boolean;
}

export function scheduleUndoable(
  commit: () => unknown,
  delayMs: number = UNDO_WINDOW_MS,
): Undoable {
  listen();
  const id = nextId++;
  pending.set(id, {
    commit,
    timer: setTimeout(() => {
      run(id);
    }, delayMs),
  });
  return {
    undo: () => {
      const p = pending.get(id);
      if (!p) return false;
      clearTimeout(p.timer);
      pending.delete(id);
      return true;
    },
  };
}
