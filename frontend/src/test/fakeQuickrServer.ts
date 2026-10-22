/**
 * A small stateful quickR server behind `fetch`, for outbox and push-action tests: creates
 * entries (idempotent by id), reserves deleted ids (`entry_deleted`), refuses archived (409
 * `topic_archived`) and missing topics (404), and checks the F10 precondition
 * `X-QuickR-Expect-Server-Id` (409 `server_mismatch`). Every response carries the identity
 * headers. Requests are recorded.
 */
export interface FakeEntry {
  id: string;
  topic_id: string;
  answers: { key: string; value: unknown }[];
  source: string;
}

export interface FakeQuickrServer {
  serverId: string;
  topics: Map<string, { status: 'active' | 'archived' }>;
  entries: Map<string, FakeEntry>;
  deleted: Set<string>;
  offline: boolean;
  requests: { method: string; url: string; headers: Record<string, string>; body: unknown }[];
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
}

export function fakeQuickrServer(serverId: string, topicIds: string[]): FakeQuickrServer {
  const server: FakeQuickrServer = {
    serverId,
    topics: new Map(topicIds.map((id) => [id, { status: 'active' as const }])),
    entries: new Map(),
    deleted: new Set(),
    offline: false,
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

  const expected = headers['x-quickr-expect-server-id'];
  if (method !== 'GET' && expected !== undefined && expected !== server.serverId) {
    return respond(server, 409, problem('server_mismatch', 'Expected another server'));
  }
  const m = /^\/api\/v1\/topics\/([^/]+)\/entries$/.exec(new URL(url, 'https://q.test').pathname);
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
