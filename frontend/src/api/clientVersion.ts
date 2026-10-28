/**
 * Client API levels (docs/specs/client-versions.md §5): the `X-QuickR-Client` header this
 * bundle sends, and what the server's answers say about it.
 *
 * {@link timedFetch} feeds every fresh `/api/v1` response to {@link observeResponse}, in the
 * page and in the service worker. The bundle is **outdated** when the server's `web` minimum
 * is above `__API_LEVEL__`, or when it answers 426 `client_outdated`; the server is
 * **behind** when its `X-QuickR-Api-Level` is below `__API_LEVEL__`.
 *
 * The state is kept in memory only (§5.3), so a reload or a service worker restart checks
 * again with its next request. Dependency-free and window-free: `sw.ts` bundles it too.
 */

export const CLIENT_HEADER = 'X-QuickR-Client';
export const API_LEVEL_HEADER = 'X-QuickR-Api-Level';
export const MIN_CLIENT_LEVEL_HEADER = 'X-QuickR-Min-Client-Level';

export const CLIENT_OUTDATED_STATUS = 426;
export const CLIENT_OUTDATED_CODE = 'client_outdated';

/** The level this bundle speaks (shared/api-level.json, §2). */
export const API_LEVEL: number = __API_LEVEL__;

/** `web; level=<int>; build=<string>` (§3.1). The build is only logged by the server. */
export const CLIENT_HEADER_VALUE = `web; level=${String(API_LEVEL)}; build=${__BUILD_TIME__}`;

/** `sessionStorage` key: a forced reload happened in this session (§5.2 step 4). */
export const FORCED_RELOAD_KEY = 'quickr.outdatedReload';

const LEVEL = /^\d+$/;

/** `X-QuickR-Api-Level`, or null when absent or not a level. */
export function parseApiLevel(header: string | null): number | null {
  const v = header?.trim();
  return v && LEVEL.test(v) ? Number(v) : null;
}

/** The `web` minimum of `X-QuickR-Min-Client-Level: ios=2, web=2`, or null. */
export function parseMinClientLevel(header: string | null): number | null {
  for (const part of header?.split(',') ?? []) {
    const [platform, level] = part.split('=').map((s) => s.trim());
    if (platform === 'web' && level !== undefined && LEVEL.test(level)) return Number(level);
  }
  return null;
}

/** A 426 whose Problem `code` is `client_outdated` (§3.3): refused before any effect. */
export function isClientOutdatedProblem(status: number, body: unknown): boolean {
  return (
    status === CLIENT_OUTDATED_STATUS &&
    typeof body === 'object' &&
    body !== null &&
    (body as { code?: unknown }).code === CLIENT_OUTDATED_CODE
  );
}

// ---- state ---------------------------------------------------------------------------

export interface ClientVersionState {
  /** The server refuses this bundle: nothing is sent, and the page updates itself. */
  outdated: boolean;
  /** The `X-QuickR-Api-Level` of the latest fresh response that had one. */
  serverApiLevel: number | null;
}

let state: ClientVersionState = { outdated: false, serverApiLevel: null };
const listeners = new Set<() => void>();

function setState(next: ClientVersionState): void {
  if (next.outdated === state.outdated && next.serverApiLevel === state.serverApiLevel) return;
  state = next;
  listeners.forEach((l) => {
    l();
  });
}

export function clientVersionState(): ClientVersionState {
  return state;
}

export function isClientOutdated(): boolean {
  return state.outdated;
}

/** Whether the server speaks a lower level than this bundle (§5.4: a warning only). */
export function isServerBehind(s: ClientVersionState = state): boolean {
  return s.serverApiLevel !== null && s.serverApiLevel < API_LEVEL;
}

export function subscribeClientVersion(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Record that the server refuses this bundle (also what the service worker posts, §5.1). */
export function markClientOutdated(): void {
  setState({ ...state, outdated: true });
}

/**
 * Read one **fresh** response's levels (the caller skips cached ones: their headers are old).
 * A response that carries the minimum and doesn't say outdated clears the state and the
 * forced-reload mark (§5.2 step 4); one without the level headers (a proxy's error page)
 * says nothing either way. A 426's body is read from a clone.
 */
export async function observeResponse(res: Response): Promise<void> {
  const min = parseMinClientLevel(res.headers.get(MIN_CLIENT_LEVEL_HEADER));
  const serverApiLevel = parseApiLevel(res.headers.get(API_LEVEL_HEADER)) ?? state.serverApiLevel;
  let outdated = min !== null && min > API_LEVEL;
  if (res.status === CLIENT_OUTDATED_STATUS) {
    try {
      outdated ||= isClientOutdatedProblem(res.status, await res.clone().json());
    } catch {
      // not a Problem: the minimum header decides
    }
  }
  if (outdated) {
    setState({ outdated: true, serverApiLevel });
    return;
  }
  if (min !== null) {
    clearForcedReload();
    setState({ outdated: false, serverApiLevel });
  } else {
    setState({ ...state, serverApiLevel });
  }
}

/** Tests: forget what responses said. */
export function resetClientVersion(): void {
  state = { outdated: false, serverApiLevel: null };
  unstoredMark = false;
}

// ---- the forced-reload mark (§5.2 step 4) ----------------------------------------------

/** The part of `Storage` used here (the service worker has none). */
interface MarkStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function session(): MarkStorage | null {
  try {
    return (globalThis as { sessionStorage?: MarkStorage }).sessionStorage ?? null;
  } catch {
    return null;
  }
}

/** Set when the mark couldn't be stored: this page then never reloads on its own. */
let unstoredMark = false;

export function hasForcedReload(): boolean {
  if (unstoredMark) return true;
  try {
    return session()?.getItem(FORCED_RELOAD_KEY) != null;
  } catch {
    return false;
  }
}

/**
 * Record a forced reload. False when it can't be stored (no or blocked `sessionStorage`):
 * the reloaded page couldn't see it, so the caller mustn't reload on its own (a loop). The
 * mark is then kept in memory.
 */
export function markForcedReload(): boolean {
  try {
    const store = session();
    if (store) {
      store.setItem(FORCED_RELOAD_KEY, String(Date.now()));
      return true;
    }
  } catch {
    // blocked storage
  }
  unstoredMark = true;
  return false;
}

export function clearForcedReload(): void {
  unstoredMark = false;
  try {
    session()?.removeItem(FORCED_RELOAD_KEY);
  } catch {
    // nothing stored
  }
}

// ---- service worker → pages (§5.1) ---------------------------------------------------

export interface ClientOutdatedMessage {
  type: 'quickr:client-outdated';
}

export const CLIENT_OUTDATED_MESSAGE: ClientOutdatedMessage = { type: 'quickr:client-outdated' };

export function isClientOutdatedMessage(data: unknown): data is ClientOutdatedMessage {
  return (
    typeof data === 'object' &&
    data !== null &&
    (data as { type?: unknown }).type === CLIENT_OUTDATED_MESSAGE.type
  );
}
