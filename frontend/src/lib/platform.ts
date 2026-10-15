/** Where are we running? Pure functions take their inputs so they are testable. */

export type IosBrowser = 'safari' | 'chrome' | 'firefox' | 'edge' | 'other';

export type Platform = { os: 'ios'; browser: IosBrowser } | { os: 'android' } | { os: 'desktop' };

export function detectPlatform(
  ua: string = typeof navigator === 'undefined' ? '' : navigator.userAgent,
  maxTouchPoints: number = typeof navigator === 'undefined' ? 0 : navigator.maxTouchPoints,
): Platform {
  // iPadOS 13+ reports a desktop Mac UA; touch support gives it away.
  const ios = /iPad|iPhone|iPod/.test(ua) || (ua.includes('Macintosh') && maxTouchPoints > 1);
  if (ios) {
    // Every iOS browser is WebKit; they differ only in UI (where "Add to Home Screen" is).
    const browser: IosBrowser = ua.includes('CriOS')
      ? 'chrome'
      : ua.includes('FxiOS')
        ? 'firefox'
        : ua.includes('EdgiOS')
          ? 'edge'
          : ua.includes('Safari') && !/(GSA|OPT|DuckDuckGo|YaBrowser)\//.test(ua)
            ? 'safari'
            : 'other';
    return { os: 'ios', browser };
  }
  if (ua.includes('Android')) return { os: 'android' };
  return { os: 'desktop' };
}

/** Launched from the home screen / as an installed app (not a browser tab). */
export function isStandalone(): boolean {
  if (typeof window === 'undefined') return false;
  const nav = navigator as Navigator & { standalone?: boolean };
  if (nav.standalone === true) return true; // iOS
  if (typeof window.matchMedia !== 'function') return false;
  return ['standalone', 'fullscreen', 'minimal-ui', 'window-controls-overlay'].some(
    (m) => window.matchMedia(`(display-mode: ${m})`).matches,
  );
}
