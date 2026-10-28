/** The active service worker registration, once `UpdatePrompt` has registered it. */
let current: ServiceWorkerRegistration | null = null;
const listeners = new Set<() => void>();

export function setRegistration(r: ServiceWorkerRegistration): void {
  current = r;
  listeners.forEach((l) => {
    l();
  });
}

export function getRegistration(): ServiceWorkerRegistration | null {
  return current;
}

export function subscribeRegistration(l: () => void): () => void {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}

/**
 * The registration once there is one: `UpdatePrompt`'s, else the browser's, else the first
 * one `UpdatePrompt` sets within `ms`; null after that.
 */
export async function awaitRegistration(
  ms: number,
  lookup: () => Promise<ServiceWorkerRegistration | undefined> = () =>
    'serviceWorker' in navigator
      ? navigator.serviceWorker.getRegistration()
      : Promise.resolve(undefined),
): Promise<ServiceWorkerRegistration | null> {
  if (current) return current;
  const found = await lookup().catch(() => undefined);
  if (found) return found;
  // set by UpdatePrompt while we awaited (TS can't see that)
  // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition
  if (current) return current;
  return new Promise((resolve) => {
    const done = (r: ServiceWorkerRegistration | null) => {
      clearTimeout(timer);
      unsubscribe();
      resolve(r);
    };
    const unsubscribe = subscribeRegistration(() => {
      done(current);
    });
    const timer = setTimeout(() => {
      done(null);
    }, ms);
  });
}
