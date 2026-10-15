/**
 * Install UX. Chromium (Android / desktop) fires `beforeinstallprompt`, which we keep
 * so an "Install app" button can show the native prompt. iOS has no prompt at all —
 * every iOS browser (Safari, Chrome, …) installs via Share → "Add to Home Screen" — so we
 * show instructions instead (see components/pwa/InstallHint).
 */
import { useSyncExternalStore } from 'react';

import { detectPlatform, isStandalone, type Platform } from './platform';
import { readStored, STORAGE_PREFIX, writeStored } from './storage';

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
  readonly userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

interface InstallSnapshot {
  /** The native install prompt is available (Chromium). */
  canPrompt: boolean;
  /** Running as an installed app. */
  standalone: boolean;
  /** `appinstalled` fired during this session. */
  justInstalled: boolean;
}

let deferred: BeforeInstallPromptEvent | null = null;
let snap: InstallSnapshot = { canPrompt: false, standalone: false, justInstalled: false };
const listeners = new Set<() => void>();

function update(patch: Partial<InstallSnapshot>): void {
  snap = { ...snap, ...patch };
  listeners.forEach((l) => {
    l();
  });
}

let captured = false;

/** Call once, as early as possible (before React renders) so the event isn't missed. */
export function captureInstallPrompt(): void {
  if (captured || typeof window === 'undefined') return;
  captured = true;
  snap = { ...snap, standalone: isStandalone() };
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault(); // no mini-infobar: we offer a quiet button instead
    deferred = e as BeforeInstallPromptEvent;
    update({ canPrompt: true });
  });
  window.addEventListener('appinstalled', () => {
    deferred = null;
    update({ canPrompt: false, justInstalled: true });
  });
  if (typeof window.matchMedia === 'function') {
    window.matchMedia('(display-mode: standalone)').addEventListener('change', () => {
      update({ standalone: isStandalone() });
    });
  }
}

/** Show the native prompt. Resolves to whether the user accepted. */
export async function promptInstall(): Promise<boolean> {
  const e = deferred;
  if (!e) return false;
  deferred = null;
  update({ canPrompt: false });
  await e.prompt();
  const choice = await e.userChoice;
  return choice.outcome === 'accepted';
}

export interface InstallState extends InstallSnapshot {
  platform: Platform;
}

const platform = detectPlatform();

export function useInstallState(): InstallState {
  const s = useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => {
        listeners.delete(cb);
      };
    },
    () => snap,
    () => snap,
  );
  return { ...s, platform };
}

const HINT_KEY = `${STORAGE_PREFIX}installHintDismissed`;

export function installHintDismissed(): boolean {
  return readStored(HINT_KEY) === '1';
}

export function dismissInstallHint(): void {
  writeStored(HINT_KEY, '1');
}
