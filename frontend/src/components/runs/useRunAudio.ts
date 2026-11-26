/**
 * The run alerts' sound (timers2.md §9.2, OQ-13) and their mute (App settings).
 *
 * Browsers, iOS Safari above all, only let an `AudioContext` start inside a user gesture:
 * {@link unlockRunAudio} creates and resumes the one context on a tap (Start and Lap), and
 * an alert later plays a short synthesised tone through it ({@link playAlertTone}).
 *
 * The run controls call it from `useRunActions`' `guarded` (M2's file, one line). Until
 * that line lands, and as a backstop, {@link useRunAudioUnlock} also unlocks on any tap in
 * the app while it is mounted (`RunAlerts` mounts it app-wide), a Start or Lap tap included.
 */
import { useCallback, useEffect, useSyncExternalStore } from 'react';

// ---- the audio context ----------------------------------------------------------------

type AudioContextCtor = typeof AudioContext;

let ctx: AudioContext | null = null;

function audioContextCtor(): AudioContextCtor | null {
  const g = globalThis as {
    AudioContext?: AudioContextCtor;
    webkitAudioContext?: AudioContextCtor;
  };
  return g.AudioContext ?? g.webkitAudioContext ?? null;
}

function context(): AudioContext | null {
  if (ctx) return ctx;
  const Ctor = audioContextCtor();
  if (!Ctor) return null;
  try {
    ctx = new Ctor();
  } catch {
    return null;
  }
  return ctx;
}

/**
 * Create and resume the alerts' `AudioContext`. Call it synchronously from a tap's handler
 * (before any `await`): that is what lets it sound later. Cheap once running.
 */
export function unlockRunAudio(): void {
  const c = context();
  if (!c || c.state === 'running') return;
  try {
    void c.resume().catch(() => undefined);
    // iOS: a silent buffer started in the gesture is what unlocks output on older WebKit.
    const src = c.createBufferSource();
    src.buffer = c.createBuffer(1, 1, 22050);
    src.connect(c.destination);
    src.start(0);
  } catch {
    // not allowed here: the next tap tries again
  }
}

/** One beep of the tone, `at` seconds on the context's clock. */
function beep(c: AudioContext, at: number, freq: number): void {
  const osc = c.createOscillator();
  const gain = c.createGain();
  osc.type = 'sine';
  osc.frequency.value = freq;
  gain.gain.setValueAtTime(0.0001, at);
  gain.gain.exponentialRampToValueAtTime(0.35, at + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, at + 0.18);
  osc.connect(gain);
  gain.connect(c.destination);
  osc.start(at);
  osc.stop(at + 0.2);
}

/**
 * The alert tone: two short beeps, about half a second (OQ-13). Silent when the context was
 * never unlocked by a tap and the browser keeps it suspended.
 */
export function playAlertTone(): void {
  const c = context();
  if (!c) return;
  try {
    if (c.state === 'suspended') void c.resume().catch(() => undefined);
    const t = c.currentTime + 0.01;
    beep(c, t, 880);
    beep(c, t + 0.26, 1175);
  } catch {
    // no audio here
  }
}

/** Tests: forget the context. */
export function resetRunAudio(): void {
  ctx = null;
}

const GESTURES = ['pointerdown', 'touchend', 'click', 'keydown'] as const;

/**
 * Unlock on every tap anywhere in the app while mounted (capture phase, so a control that
 * stops propagation still counts).
 */
export function useRunAudioUnlock(): void {
  useEffect(() => {
    for (const g of GESTURES) document.addEventListener(g, unlockRunAudio, true);
    return () => {
      for (const g of GESTURES) document.removeEventListener(g, unlockRunAudio, true);
    };
  }, []);
}

/** The audio unlock for a tap handler: `const { unlock } = useRunAudio();`. */
export function useRunAudio(): { unlock: () => void; play: () => void } {
  const unlock = useCallback(() => unlockRunAudio(), []);
  const play = useCallback(() => playAlertTone(), []);
  return { unlock, play };
}

// ---- the global mute (App settings) ---------------------------------------------------

/** `localStorage`: "1" mutes the alerts' tone and vibration (the toast stays). */
export const ALERTS_MUTED_KEY = 'quickr.alertsMuted';

const muteListeners = new Set<() => void>();

export function alertsMuted(): boolean {
  try {
    return localStorage.getItem(ALERTS_MUTED_KEY) === '1';
  } catch {
    return false;
  }
}

export function setAlertsMuted(muted: boolean): void {
  try {
    if (muted) localStorage.setItem(ALERTS_MUTED_KEY, '1');
    else localStorage.removeItem(ALERTS_MUTED_KEY);
  } catch {
    // blocked storage: nothing to remember it in
  }
  muteListeners.forEach((l) => {
    l();
  });
}

function subscribeMuted(l: () => void): () => void {
  muteListeners.add(l);
  const onStorage = (e: StorageEvent) => {
    if (e.key === null || e.key === ALERTS_MUTED_KEY) l();
  };
  window.addEventListener('storage', onStorage);
  return () => {
    muteListeners.delete(l);
    window.removeEventListener('storage', onStorage);
  };
}

/** Whether alerts are muted; follows the toggle in this tab and others. */
export function useAlertsMuted(): boolean {
  return useSyncExternalStore(subscribeMuted, alertsMuted, alertsMuted);
}
