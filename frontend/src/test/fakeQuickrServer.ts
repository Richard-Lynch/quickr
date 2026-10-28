/**
 * A small stateful quickR server behind `fetch`, for outbox and push-action tests: creates
 * entries (idempotent by id), reserves deleted ids (`entry_deleted`), refuses archived (409
 * `topic_archived`) and missing topics (404), and checks the F10 precondition
 * `X-QuickR-Expect-Server-Id` (409 `server_mismatch`). Run events (`POST /runs/{id}/events`):
 * idempotent by event id, and as the backend's `_replay` a replay must match the stored
 * event's `at`, topic, `seg`, `step` and `pause_id` (else 409 `event_conflict`); 409
 * `run_deleted` for a run in `deletedRuns`, 409 `id_conflict` for a start with an entry's
 * id, 409 `topic_not_timed` for a topic marked `untimed`; a start for a topic with an open
 * run is merged into it (201, the start `void`, `merged`; its id becomes an alias). A `stop`
 * closes its run (or the run its id was merged into); a `discard` deletes it; any other tap
 * on a known run is applied. An event whose id is in `unavailable` gets a 503.
 * `GET /runs/{id}` (an alias resolves) and `GET /entries/{id}` read them back; a read of an
 * id in `unavailableReads` gets a 503.
 * Every response carries the identity and level headers (`apiLevel`, `minWebLevel`). A
 * request whose `X-QuickR-Client` level is below `minWebLevel` gets 426 `client_outdated`
 * before any effect (client-versions.md §3.3). Requests are recorded.
 */
export interface FakeEntry {
  id: string;
  topic_id: string;
  answers: { key: string; value: unknown }[];
  source: string;
}

/** What a replay of an event must match (the backend's `_replay`). */
export interface FakeEvent {
  type: string;
  at: string;
  topic_id?: string | null;
  seg?: number | null;
  step?: string | null;
  pause_id?: string | null;
}

export interface FakeRun {
  id: string;
  topic_id: string;
  version: number;
  /** Its start's `at` (the start's id is the run's). */
  at: string;
  source: string;
  status?: 'running' | 'stopped';
  /** Starts merged into this run (their ids, with what they sent). */
  aliases?: Map<string, FakeEvent>;
  /** Its other events (taps after the start), by id. */
  events?: Map<string, FakeEvent>;
}

export interface FakeQuickrServer {
  serverId: string;
  topics: Map<string, { status: 'active' | 'archived'; untimed?: boolean }>;
  entries: Map<string, FakeEntry>;
  deleted: Set<string>;
  runs: Map<string, FakeRun>;
  deletedRuns: Set<string>;
  /** Event ids answered 503 `unavailable` while they are in the set. */
  unavailable: Set<string>;
  /** Run or entry ids whose `GET` is answered 503 while they are in the set. */
  unavailableReads: Set<string>;
  offline: boolean;
  /** `X-QuickR-Api-Level` (default: this bundle's level). */
  apiLevel: number;
  /** The `web` minimum (default 0). */
  minWebLevel: number;
  requests: { method: string; url: string; headers: Record<string, string>; body: unknown }[];
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
}

export function fakeQuickrServer(serverId: string, topicIds: string[]): FakeQuickrServer {
  const server: FakeQuickrServer = {
    serverId,
    topics: new Map(topicIds.map((id) => [id, { status: 'active' as const }])),
    entries: new Map(),
    deleted: new Set(),
    runs: new Map(),
    deletedRuns: new Set(),
    unavailable: new Set(),
    unavailableReads: new Set(),
    offline: false,
    apiLevel: __API_LEVEL__,
    minWebLevel: 0,
    requests: [],
    fetch: (input, init) => Promise.resolve(handle(server, input, init)),
  };
  return server;
}

function respond(server: FakeQuickrServer, status: number, body: unknown): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'X-QuickR-Server-Id': server.serverId,
      'X-QuickR-Epoch': 'E1',
      'X-QuickR-Api-Level': String(server.apiLevel),
      'X-QuickR-Min-Client-Level': `ios=0, web=${String(server.minWebLevel)}`,
    },
  });
}

const problem = (code: string, detail: string) => ({ code, detail, errors: [] });

function handle(server: FakeQuickrServer, input: RequestInfo | URL, init?: RequestInit): Response {
  if (server.offline) throw new TypeError('Failed to fetch');
  const url = input instanceof Request ? input.url : input instanceof URL ? input.href : input;
  const method = init?.method ?? 'GET';
  const headers = Object.fromEntries(new Headers(init?.headers).entries());
  const body: unknown = typeof init?.body === 'string' ? JSON.parse(init.body) : undefined;
  server.requests.push({ method, url, headers, body });

  const level = /level=(\d+)/.exec(headers['x-quickr-client'] ?? '')?.[1];
  if (level !== undefined && Number(level) < server.minWebLevel) {
    return respond(server, 426, {
      ...problem('client_outdated', 'This version of quickR is too old for the server.'),
      min_client_level: server.minWebLevel,
      client_level: Number(level),
    });
  }

  const expected = headers['x-quickr-expect-server-id'];
  if (method !== 'GET' && expected !== undefined && expected !== server.serverId) {
    return respond(server, 409, problem('server_mismatch', 'Expected another server'));
  }
  const path = new URL(url, 'https://q.test').pathname;
  const read = /^\/api\/v1\/(runs|entries)\/([^/]+)$/.exec(path);
  if (method === 'GET' && read)
    return get(server, read[1] ?? '', decodeURIComponent(read[2] ?? ''));
  const run = /^\/api\/v1\/runs\/([^/]+)\/events$/.exec(path);
  if (method === 'POST' && run) return runEvent(server, decodeURIComponent(run[1] ?? ''), body);
  const m = /^\/api\/v1\/topics\/([^/]+)\/entries$/.exec(path);
  if (method !== 'POST' || !m) return respond(server, 404, problem('not_found', 'Not found'));
  const topicId = decodeURIComponent(m[1] ?? '');
  const create = body as { id: string; answers: Record<string, unknown>; source?: string };
  const topic = server.topics.get(topicId);
  if (!topic) return respond(server, 404, problem('not_found', 'Topic not found'));
  if (server.deleted.has(create.id))
    return respond(server, 409, problem('entry_deleted', 'Entry was deleted'));
  const existing = server.entries.get(create.id);
  if (existing) return respond(server, 201, existing);
  if (topic.status === 'archived')
    return respond(server, 409, problem('topic_archived', 'Topic is archived'));
  const entry: FakeEntry = {
    id: create.id,
    topic_id: topicId,
    answers: Object.entries(create.answers).map(([key, value]) => ({ key, value })),
    source: create.source ?? 'api',
  };
  server.entries.set(entry.id, entry);
  return respond(server, 201, entry);
}

/** A `GET /runs/{id}` (an alias resolves) or `GET /entries/{id}`. */
function get(server: FakeQuickrServer, what: string, id: string): Response {
  if (server.unavailableReads.has(id))
    return respond(server, 503, problem('unavailable', 'Try again later'));
  if (what === 'entries') {
    const entry = server.entries.get(id);
    return entry
      ? respond(server, 200, entry)
      : respond(server, 404, problem('not_found', 'Not found'));
  }
  const run = resolveRun(server, id);
  return run
    ? respond(server, 200, runOut(run))
    : respond(server, 404, problem('not_found', 'Not found'));
}

function resolveRun(server: FakeQuickrServer, id: string): FakeRun | undefined {
  return server.runs.get(id) ?? [...server.runs.values()].find((r) => r.aliases?.has(id));
}

/** Enough of a `RunOut` for the clients: its id, topic, status, aliases and effects (no events). */
function runOut(r: FakeRun) {
  const effects: Record<string, { effect: string; reason: string | null }> = {
    [r.id]: { effect: 'applied', reason: null },
  };
  for (const id of r.aliases?.keys() ?? []) effects[id] = { effect: 'void', reason: 'merged' };
  for (const id of r.events?.keys() ?? []) effects[id] = { effect: 'applied', reason: null };
  return {
    id: r.id,
    topic_id: r.topic_id,
    version: r.version,
    status: r.status ?? 'running',
    revision: (r.events?.size ?? 0) + 1,
    aliases: [...(r.aliases?.keys() ?? [])],
    events: [],
    state: { effects },
  };
}

/** Whether `event` replays `stored`, as the backend's `_replay` compares them. */
function sameEvent(stored: FakeEvent, event: FakeEvent): boolean {
  return (
    stored.type === event.type &&
    stored.at === event.at &&
    (stored.topic_id ?? null) === (event.topic_id ?? null) &&
    (stored.seg ?? null) === (event.seg ?? null) &&
    (stored.step ?? null) === (event.step ?? null) &&
    (stored.pause_id ?? null) === (event.pause_id ?? null)
  );
}

function runEvent(server: FakeQuickrServer, runId: string, body: unknown): Response {
  const event = body as FakeEvent & { id: string; version: number; source?: string };
  const sent: FakeEvent = {
    type: event.type,
    at: event.at,
    topic_id: event.topic_id ?? null,
    seg: event.seg ?? null,
    step: event.step ?? null,
    pause_id: event.pause_id ?? null,
  };
  const result = (r: FakeRun, effect: 'applied' | 'void', reason: string | null = null) => ({
    event: { id: event.id, effect, reason },
    run: runOut(r),
    entry: null,
  });
  const conflict = () => respond(server, 409, problem('event_conflict', 'Event id reused'));
  if (server.unavailable.has(event.id))
    return respond(server, 503, problem('unavailable', 'Try again later'));
  if (server.deletedRuns.has(runId))
    return respond(server, 409, problem('run_deleted', 'Run deleted'));
  if (event.type !== 'start') {
    const target = resolveRun(server, runId);
    if (!target) return respond(server, 404, problem('not_found', 'Not found'));
    const stored = target.events?.get(event.id);
    if (stored)
      return sameEvent(stored, sent) ? respond(server, 200, result(target, 'applied')) : conflict();
    if (event.type === 'discard') {
      server.runs.delete(target.id);
      server.deletedRuns.add(target.id);
    } else if (event.type === 'stop') target.status = 'stopped';
    (target.events ??= new Map()).set(event.id, sent);
    return respond(server, 200, result(target, 'applied'));
  }
  if (event.id !== runId) return respond(server, 404, problem('not_found', 'Not found'));
  const existing = server.runs.get(runId);
  if (existing) {
    const start: FakeEvent = { type: 'start', at: existing.at, topic_id: existing.topic_id };
    return sameEvent(start, sent) ? respond(server, 200, result(existing, 'applied')) : conflict();
  }
  for (const r of server.runs.values()) {
    const stored = r.aliases?.get(runId);
    if (stored !== undefined) {
      return sameEvent(stored, sent)
        ? respond(server, 200, result(r, 'void', 'merged'))
        : conflict();
    }
  }
  if (server.entries.has(runId))
    return respond(server, 409, problem('id_conflict', 'An entry’s id'));
  const topicId = event.topic_id ?? '';
  const topic = server.topics.get(topicId);
  if (!topic) return respond(server, 404, problem('not_found', 'Topic not found'));
  if (topic.status === 'archived')
    return respond(server, 409, problem('topic_archived', 'Topic is archived'));
  if (topic.untimed) return respond(server, 409, problem('topic_not_timed', 'Not a timed version'));
  const open = [...server.runs.values()].find(
    (r) => r.topic_id === topicId && (r.status ?? 'running') === 'running',
  );
  if (open) {
    (open.aliases ??= new Map()).set(runId, sent);
    return respond(server, 201, result(open, 'void', 'merged'));
  }
  const created: FakeRun = {
    id: runId,
    topic_id: topicId,
    version: event.version,
    at: event.at,
    source: event.source ?? 'api',
    status: 'running',
  };
  server.runs.set(runId, created);
  return respond(server, 201, result(created, 'applied'));
}
