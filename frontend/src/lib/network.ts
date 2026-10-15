import { useSyncExternalStore } from 'react';

function subscribe(cb: () => void): () => void {
  window.addEventListener('online', cb);
  window.addEventListener('offline', cb);
  return () => {
    window.removeEventListener('online', cb);
    window.removeEventListener('offline', cb);
  };
}

/**
 * `navigator.onLine` as React state. `false` is reliable ("definitely offline");
 * `true` only means "has a network interface" — requests can still fail.
 */
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => navigator.onLine,
    () => true,
  );
}
