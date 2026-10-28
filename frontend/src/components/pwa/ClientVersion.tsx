import { useEffect, useRef, useState, useSyncExternalStore } from 'react';

import {
  clientVersionState,
  hasForcedReload,
  isServerBehind,
  subscribeClientVersion,
} from '../../api/clientVersion';
import { hasUnsavedChanges } from '../../lib/unsavedChanges';
import { Button } from '../ui/Button';
import { Icon } from '../ui/Icon';
import { ConfirmSheet } from '../ui/Sheet';
import { Spinner } from '../ui/Spinner';
import { forceUpdate, type ForceUpdateDeps } from './forceUpdate';
import { getRegistration } from './swRegistration';

/** What responses said about this bundle and the server (docs/specs/client-versions.md §5). */
export function useClientVersion() {
  return useSyncExternalStore(subscribeClientVersion, clientVersionState, clientVersionState);
}

function browserDeps(): ForceUpdateDeps {
  const sw = 'serviceWorker' in navigator ? navigator.serviceWorker : null;
  return {
    registration: getRegistration(),
    container: sw,
    reload: () => {
      window.location.reload();
    },
    online: () => navigator.onLine,
  };
}

type Phase = 'updating' | 'failed' | 'confirm' | 'deferred';

/**
 * Shown while the bundle is outdated (§5.2): the forced update starts at once, under a
 * blocking "Updating quickR…" overlay. When it can't complete (offline, or a forced reload
 * already happened this session) the overlay asks the user to reload. Unsaved form changes
 * are asked about first; "Not now" leaves a bar so the text can be copied out.
 */
export function ClientOutdated({ deps = browserDeps }: { deps?: () => ForceUpdateDeps }) {
  const [phase, setPhase] = useState<Phase>(() =>
    hasForcedReload() ? 'failed' : hasUnsavedChanges() ? 'confirm' : 'updating',
  );
  const started = useRef(false);

  const run = (ignoreGuard: boolean) => {
    setPhase('updating');
    void forceUpdate({ ...deps(), ignoreGuard }).then((r) => {
      if (r === 'failed') setPhase('failed');
    });
  };

  useEffect(() => {
    if (started.current || phase !== 'updating') return;
    started.current = true;
    run(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once, on mount
  }, []);

  if (phase === 'confirm') {
    return (
      <ConfirmSheet
        open
        onClose={() => setPhase('deferred')}
        onConfirm={() => run(false)}
        title="quickR needs an update"
        body={
          <p>
            You have unsaved changes. Updating reloads the app and discards them. Your queued
            changes are safe.
          </p>
        }
        cancelLabel="Not now"
        confirmLabel="Update now"
        danger
      />
    );
  }

  if (phase === 'deferred') {
    return (
      <div
        role="status"
        className="fixed inset-x-0 bottom-[calc(env(safe-area-inset-bottom)+6rem)] z-40 flex justify-center px-3 sm:bottom-6"
      >
        <div className="flex w-full max-w-sm items-center gap-3 rounded-2xl border border-line bg-ink py-2 pr-2 pl-4 text-paper shadow-float">
          <Icon name="alert" className="size-4.5 shrink-0" />
          <p className="min-w-0 flex-1 text-sm font-semibold">quickR needs an update</p>
          <button
            type="button"
            className="h-9 shrink-0 rounded-full bg-accent px-4 text-sm font-semibold text-on-accent"
            onClick={() => setPhase('confirm')}
          >
            Update
          </button>
        </div>
      </div>
    );
  }

  return (
    <div
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="client-outdated-title"
      className="fixed inset-0 z-50 grid place-items-center bg-paper/95 px-6 backdrop-blur-sm"
    >
      <div className="flex max-w-sm flex-col items-center gap-4 text-center">
        {phase === 'updating' ? (
          <>
            <Spinner className="size-7 text-accent" />
            <p id="client-outdated-title" className="font-display text-xl font-semibold">
              Updating quickR…
            </p>
          </>
        ) : (
          <>
            <Icon name="cloudOff" className="size-7 text-ink-soft" />
            <p id="client-outdated-title" className="font-display text-xl font-semibold">
              quickR needs an update. Connect to the internet and reload.
            </p>
            <p className="text-sm text-ink-soft">Your unsynced changes are safe on this device.</p>
            <Button variant="primary" onClick={() => run(true)}>
              Reload
            </Button>
          </>
        )}
      </div>
    </div>
  );
}

export const SERVER_BEHIND_DISMISSED_KEY = 'quickr.serverBehindDismissed';

function dismissedThisSession(): boolean {
  try {
    return sessionStorage.getItem(SERVER_BEHIND_DISMISSED_KEY) != null;
  } catch {
    return false;
  }
}

/**
 * The server speaks a lower API level than this bundle (§5.4): a dismissable note, which
 * stays dismissed for the session. It blocks, reloads and holds nothing, and goes away when
 * a response reports a level at or above this bundle's.
 */
export function ServerBehindBanner() {
  const state = useClientVersion();
  const [dismissed, setDismissed] = useState(dismissedThisSession);
  if (!isServerBehind(state) || state.outdated || dismissed) return null;
  return (
    <div
      role="status"
      className="fixed inset-x-0 top-[calc(env(safe-area-inset-top)+4.25rem)] z-40 flex justify-center px-3 sm:top-[calc(env(safe-area-inset-top)+4.75rem)]"
    >
      <div className="flex w-full max-w-md animate-rise items-start gap-3 rounded-2xl border border-line bg-surface py-2.5 pr-2 pl-4 text-sm shadow-float">
        <Icon name="info" className="mt-0.5 size-4.5 shrink-0 text-ink-soft" />
        <p className="min-w-0 flex-1">
          The quickR server is older than this app. It keeps working, but deploy the server to
          finish the update.
        </p>
        <button
          type="button"
          aria-label="Dismiss"
          className="grid size-8 shrink-0 place-items-center rounded-full opacity-60 hover:opacity-100"
          onClick={() => {
            try {
              sessionStorage.setItem(SERVER_BEHIND_DISMISSED_KEY, '1');
            } catch {
              // dismissed for this page only
            }
            setDismissed(true);
          }}
        >
          <Icon name="x" className="size-4" />
        </button>
      </div>
    </div>
  );
}
