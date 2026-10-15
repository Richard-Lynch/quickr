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
