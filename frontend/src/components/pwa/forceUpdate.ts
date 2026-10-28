/**
 * The forced update of an outdated bundle (docs/specs/client-versions.md §5.2).
 *
 * The service worker is never unregistered: that would delete the Web Push subscription,
 * and `push.ts` doesn't subscribe again. nginx serves `sw.js` with `no-cache`, so
 * `update()` finds a new worker whenever one has been deployed.
 */
import { hasForcedReload, markForcedReload } from '../../api/clientVersion';

/** How long a new worker gets to become waiting, and then to take control. */
export const UPDATE_WAIT_MS = 10_000;

export interface ForceUpdateDeps {
  /** The app's registration (`swRegistration.ts`), or null without a service worker. */
  registration: ServiceWorkerRegistration | null;
  /** Fires `controllerchange` once the waiting worker takes over. */
  container: Pick<ServiceWorkerContainer, 'addEventListener' | 'removeEventListener'> | null;
  reload: () => void;
  online: () => boolean;
  waitMs?: number;
  /** The Reload button: the user asked, so the loop guard doesn't apply. */
  ignoreGuard?: boolean;
}

/**
 * `reloading`: the page is reloading into the new bundle. `failed`: it can't update now
 * (offline, or a forced reload already happened in this session: the frontend image is
 * behind the backend), so the overlay asks the user to reload.
 */
export type ForceUpdateResult = 'reloading' | 'failed';

/**
 * 1. `registration.update()` at once;
 * 2. a worker waiting, or waiting within {@link UPDATE_WAIT_MS}: `SKIP_WAITING`, and reload
 *    when it takes control;
 * 3. no new worker: reload anyway;
 * 4. at most one forced reload per session (`sessionStorage`).
 */
export async function forceUpdate(deps: ForceUpdateDeps): Promise<ForceUpdateResult> {
  if (!deps.ignoreGuard && hasForcedReload()) return 'failed';
  if (!deps.online()) return 'failed';
  const waitMs = deps.waitMs ?? UPDATE_WAIT_MS;
  const reg = deps.registration;
  if (reg) {
    try {
      await reg.update();
    } catch {
      // offline, or the server is down: a reload would not help either
      return 'failed';
    }
    const waiting = reg.waiting ?? (await waitingWorker(reg, waitMs));
    if (waiting) {
      const changed = controllerChange(deps.container, waitMs);
      waiting.postMessage({ type: 'SKIP_WAITING' });
      await changed;
    }
  }
  markForcedReload();
  deps.reload();
  return 'reloading';
}

/** The worker that becomes waiting within `ms`, or null. */
function waitingWorker(reg: ServiceWorkerRegistration, ms: number): Promise<ServiceWorker | null> {
  return new Promise((resolve) => {
    const tracked = new Set<ServiceWorker>();
    const done = (w: ServiceWorker | null) => {
      clearTimeout(timer);
      reg.removeEventListener('updatefound', check);
      for (const t of tracked) t.removeEventListener('statechange', check);
      resolve(w);
    };
    function check() {
      if (reg.waiting) {
        done(reg.waiting);
        return;
      }
      const installing = reg.installing;
      if (installing && !tracked.has(installing)) {
        tracked.add(installing);
        installing.addEventListener('statechange', check);
      }
    }
    const timer = setTimeout(() => {
      done(null);
    }, ms);
    reg.addEventListener('updatefound', check);
    check();
  });
}

/** Resolves on `controllerchange`, or after `ms` (the reload then loads what's there). */
function controllerChange(container: ForceUpdateDeps['container'], ms: number): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      container?.removeEventListener('controllerchange', done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    container?.addEventListener('controllerchange', done);
  });
}
