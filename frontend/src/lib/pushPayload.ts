/**
 * Push message contract (shared by `sw.ts` and tests; keep it pure).
 *
 * Server payload JSON: `{ "title", "body", "url", "tag", "topic_slug" }` — every field
 * optional; `url` is an in-app path such as `/t/{slug}/record`.
 */
export interface PushPayload {
  title: string;
  body: string;
  /** Same-origin path to open on click. */
  url: string;
  /** Notifications with the same tag replace each other (de-dupe). */
  tag: string | undefined;
  topic_slug: string | undefined;
}

const str = (v: unknown): string | undefined =>
  typeof v === 'string' && v.trim() ? v.trim() : undefined;

/** Only same-origin paths: a push must never open an arbitrary site. */
export function safeInAppPath(url: unknown): string {
  const s = str(url);
  if (!s?.startsWith('/') || s.startsWith('//')) return '/';
  return s;
}

/** Tolerant parse: a malformed push still shows *something* (iOS revokes silent pushes). */
export function parsePushPayload(raw: unknown): PushPayload {
  let data: unknown = raw;
  if (typeof raw === 'string') {
    try {
      data = JSON.parse(raw);
    } catch {
      data = { body: raw };
    }
  }
  const o = (typeof data === 'object' && data !== null ? data : {}) as Record<string, unknown>;
  const topicSlug = str(o.topic_slug);
  return {
    title: str(o.title) ?? 'quickR',
    body: str(o.body) ?? '',
    url: safeInAppPath(o.url ?? (topicSlug ? `/t/${topicSlug}/record` : undefined)),
    tag: str(o.tag),
    topic_slug: topicSlug,
  };
}

/** Message the SW posts to a focused window so the SPA routes without a reload. */
export interface NavigateMessage {
  type: 'quickr:navigate';
  url: string;
}

export function isNavigateMessage(data: unknown): data is NavigateMessage {
  return (
    typeof data === 'object' &&
    data !== null &&
    (data as { type?: unknown }).type === 'quickr:navigate' &&
    typeof (data as { url?: unknown }).url === 'string'
  );
}
