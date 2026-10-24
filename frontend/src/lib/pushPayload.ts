/**
 * Push message contract (shared by `sw.ts` and tests; keep it pure).
 *
 * Server payload JSON (`PushPayload` in the API schema): `{ "title", "body", "url", "tag",
 * "topic_slug" }`, plus the actionable fields of docs/ios/specs/notifications.md §10 —
 * `v`, `kind`, `server_id`, `topic_id`, `version`, `due_since` and `quick_log` (§2.3). Every
 * field is optional; `url` is an in-app path such as `/t/{slug}/record`.
 */
export interface PushPayload {
  title: string;
  body: string;
  /** Same-origin path to open on click. */
  url: string;
  /** Notifications with the same tag replace each other (de-dupe). */
  tag: string | undefined;
  topic_slug: string | undefined;
  /** The actionable part, when the push is a v1 due reminder that carries all of it. */
  quickr: PushQuickr | undefined;
}

/** What a reminder's actions need (notifications.md §2.1, §10). */
export interface PushQuickr {
  /** Needed for the action entry id (notifications.md §7.4). */
  server_id: string;
  topic_id: string;
  /** The topic version actions log against. */
  version: number;
  /** The slot, canonical (UTC, whole seconds, `Z`). */
  due_since: string;
  quick_log: QuickLogDescriptor;
}

export interface QuickLogEnumDescriptor {
  type: 'enum';
  key: string;
  label: string;
  options: { value: string; label: string }[];
  total_options: number;
}

export interface QuickLogNumberDescriptor {
  type: 'int' | 'double';
  key: string;
  label: string;
  unit: string | null;
  last_value: number | null;
}

/** A topic with no questions (a "single" topic): one "Log it" action, an entry with no answers. */
export interface QuickLogSingleDescriptor {
  type: 'single';
}

/** A timed topic: one "Start" action, which starts a run (timers.md §10.1). */
export interface QuickLogTimedDescriptor {
  type: 'timed';
}

export type QuickLogDescriptor =
  | QuickLogEnumDescriptor
  | QuickLogNumberDescriptor
  | QuickLogSingleDescriptor
  | QuickLogTimedDescriptor;

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
    quickr: parseQuickr(o),
  };
}

const record = (v: unknown): Record<string, unknown> | undefined =>
  typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : undefined;

const finite = (v: unknown): number | undefined =>
  typeof v === 'number' && Number.isFinite(v) ? v : undefined;

/**
 * The actionable fields, or undefined unless this is a v1 `due` reminder with a server id,
 * topic id, version, slot and a well-formed descriptor (anything else is display-only, §2.1).
 */
function parseQuickr(o: Record<string, unknown>): PushQuickr | undefined {
  if (o.v !== 1 || o.kind !== 'due') return undefined;
  const serverId = str(o.server_id);
  const topicId = str(o.topic_id);
  const version = finite(o.version);
  const dueSince = str(o.due_since);
  const quickLog = parseQuickLog(o.quick_log);
  if (
    !serverId ||
    !topicId ||
    version === undefined ||
    !Number.isInteger(version) ||
    !dueSince ||
    !quickLog
  ) {
    return undefined;
  }
  return {
    server_id: serverId,
    topic_id: topicId,
    version,
    due_since: dueSince,
    quick_log: quickLog,
  };
}

export function parseQuickLog(raw: unknown): QuickLogDescriptor | undefined {
  const q = record(raw);
  if (q?.type === 'single') return { type: 'single' };
  if (q?.type === 'timed') return { type: 'timed' };
  const key = str(q?.key);
  if (!q || !key) return undefined;
  const label = typeof q.label === 'string' ? q.label : key;
  if (q.type === 'enum') {
    if (!Array.isArray(q.options)) return undefined;
    const options = q.options.flatMap((raw) => {
      const opt = record(raw);
      return typeof opt?.value === 'string' && typeof opt.label === 'string'
        ? [{ value: opt.value, label: opt.label }]
        : [];
    });
    if (options.length !== q.options.length || options.length === 0) return undefined;
    return {
      type: 'enum',
      key,
      label,
      options,
      total_options: finite(q.total_options) ?? options.length,
    };
  }
  if (q.type === 'int' || q.type === 'double') {
    const unit = typeof q.unit === 'string' && q.unit ? q.unit : null;
    return { type: q.type, key, label, unit, last_value: finite(q.last_value) ?? null };
  }
  return undefined;
}

/**
 * `fmt` of notifications.md §4.4: base 10 for `int`; for `double`, the shortest round-trip
 * decimal (JS `String(x)`, the same digits as Python `repr`) without an exponent, trailing
 * zeros or `-0`. `null` when the value can't be represented exactly: non-finite, or an `int`
 * beyond 2^53 (JSON numbers lose its digits in JS).
 */
export function formatQuickLogNumber(kind: 'int' | 'double', x: number): string | null {
  if (!Number.isFinite(x)) return null;
  if (kind === 'int') return Number.isSafeInteger(x) ? String(x === 0 ? 0 : x) : null;
  return x === 0 ? '0' : expandExponent(String(x));
}

function expandExponent(s: string): string {
  const m = /^(-?)(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(s);
  if (!m) return s;
  const [, sign = '', whole = '', fraction = '', exponent = '0'] = m;
  const digits = whole + fraction;
  const point = whole.length + Number(exponent);
  if (point <= 0) return `${sign}0.${'0'.repeat(-point)}${digits}`;
  if (point >= digits.length) return sign + digits + '0'.repeat(point - digits.length);
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
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
