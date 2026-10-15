/**
 * App icon badge (Badging API). Works in installed apps on iOS/iPadOS 16.4+ (needs
 * notification permission there), Chromium desktop and some Android launchers.
 * No-ops elsewhere. Feed it the "due" count from the schedules feature.
 */
interface BadgeNavigator {
  setAppBadge?: (contents?: number) => Promise<void>;
  clearAppBadge?: () => Promise<void>;
}

const nav = (): BadgeNavigator | undefined =>
  typeof navigator === 'undefined' ? undefined : navigator;

export function badgeSupported(): boolean {
  return typeof nav()?.setAppBadge === 'function';
}

/** Show `count` on the app icon (0 clears it). Never throws; resolves to success. */
export async function setAppBadge(count: number): Promise<boolean> {
  const n = nav();
  try {
    if (count <= 0) return await clearAppBadge();
    if (!n?.setAppBadge) return false;
    await n.setAppBadge(Math.floor(count));
    return true;
  } catch {
    return false;
  }
}

export async function clearAppBadge(): Promise<boolean> {
  const n = nav();
  try {
    if (n?.clearAppBadge) {
      await n.clearAppBadge();
      return true;
    }
    if (n?.setAppBadge) {
      await n.setAppBadge(0);
      return true;
    }
    return false;
  } catch {
    return false;
  }
}
