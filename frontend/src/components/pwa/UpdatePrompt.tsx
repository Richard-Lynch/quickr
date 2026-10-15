import { useEffect, useState } from 'react';
import { useRegisterSW } from 'virtual:pwa-register/react';

import { hasUnsavedChanges } from '../../lib/unsavedChanges';
import { ConfirmSheet } from '../ui/Sheet';
import { useToast } from '../ui/Toast';
import { Icon } from '../ui/Icon';
import { setRegistration } from './swRegistration';

const HOUR = 60 * 60 * 1000;

/**
 * Registers the service worker and shows an unobtrusive "Update available — Reload"
 * card when a new version is waiting. Nothing reloads until the user taps Reload, and
 * if a form has unsaved changes we ask first.
 */
export function UpdatePrompt() {
  const { toast } = useToast();
  const [dismissed, setDismissed] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const {
    needRefresh: [needRefresh],
    offlineReady: [offlineReady, setOfflineReady],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return;
      setRegistration(registration);
      // Home-screen apps can stay open for days: look for updates hourly and on resume.
      const check = () => {
        if (navigator.onLine) registration.update().catch(() => undefined);
      };
      setInterval(check, HOUR);
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') check();
      });
    },
    onRegisterError(error: unknown) {
      console.warn('[sw] registration failed', error);
    },
  });

  useEffect(() => {
    if (!offlineReady) return;
    toast({ title: 'Ready to work offline', tone: 'info' });
    setOfflineReady(false);
  }, [offlineReady, setOfflineReady, toast]);

  const reload = () => {
    void updateServiceWorker(true);
  };

  if (!needRefresh || dismissed) return null;

  return (
    <>
      <div
        role="status"
        className="fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+6rem)] z-40 flex justify-center px-3 sm:bottom-6"
      >
        <div className="flex w-full max-w-sm animate-rise items-center gap-3 rounded-2xl border border-line bg-ink py-2 pr-2 pl-4 text-paper shadow-float">
          <Icon name="sync" className="size-4.5 shrink-0" />
          <p className="min-w-0 flex-1 text-sm font-semibold">Update available</p>
          <button
            type="button"
            className="h-9 shrink-0 rounded-full bg-accent px-4 text-sm font-semibold text-on-accent"
            onClick={() => {
              if (hasUnsavedChanges()) setConfirm(true);
              else reload();
            }}
          >
            Reload
          </button>
          <button
            type="button"
            aria-label="Later"
            className="grid size-9 shrink-0 place-items-center rounded-full opacity-60 hover:opacity-100"
            onClick={() => setDismissed(true)}
          >
            <Icon name="x" className="size-4" />
          </button>
        </div>
      </div>
      <ConfirmSheet
        open={confirm}
        onClose={() => setConfirm(false)}
        onConfirm={reload}
        title="Reload now?"
        body={<p>You have unsaved changes. Reloading to update will discard them.</p>}
        cancelLabel="Not now"
        confirmLabel="Reload anyway"
        danger
      />
    </>
  );
}
