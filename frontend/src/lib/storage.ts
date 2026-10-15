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

const SOURCE_KEY = 'quicker.source';
export const DEFAULT_SOURCE = 'phone';

export function rememberedSource(): string {
  return readStored(SOURCE_KEY)?.trim() || DEFAULT_SOURCE;
}

export function rememberSource(source: string): void {
  const s = source.trim();
  if (s) writeStored(SOURCE_KEY, s);
}
