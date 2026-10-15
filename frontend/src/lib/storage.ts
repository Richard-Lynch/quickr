/** localStorage that never throws (private mode, disabled storage, SSR-less tests). */
export function readStored(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeStored(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // ignore — remembering is a convenience
  }
}

export function removeStored(key: string): void {
  try {
    window.localStorage.removeItem(key);
  } catch {
    // ignore
  }
}

/** Every localStorage key the app owns starts with this (see "Clear local data"). */
export const STORAGE_PREFIX = 'quickr.';

const SOURCE_KEY = `${STORAGE_PREFIX}source`;
/** Pre-rename key, still read so nobody loses their remembered source. */
const LEGACY_SOURCE_KEY = 'quicker.source';
export const DEFAULT_SOURCE = 'phone';

export function rememberedSource(): string {
  return readStored(SOURCE_KEY)?.trim() || readStored(LEGACY_SOURCE_KEY)?.trim() || DEFAULT_SOURCE;
}

/** Remove every app-owned localStorage key (including pre-rename ones). */
export function clearStored(): void {
  try {
    const keys: string[] = [];
    for (let i = 0; i < window.localStorage.length; i++) {
      const k = window.localStorage.key(i);
      if (k?.startsWith(STORAGE_PREFIX) || k?.startsWith('quicker.')) keys.push(k);
    }
    keys.forEach((k) => window.localStorage.removeItem(k));
  } catch {
    // ignore
  }
}

export function rememberSource(source: string): void {
  const s = source.trim();
  if (s) writeStored(SOURCE_KEY, s);
}
