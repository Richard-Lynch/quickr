/**
 * A small stateful quickR server behind `fetch`, for the run UI's component tests: one
 * timed topic (detail and versions), `listRuns`, `listEntries`, and `recordRunEvent`
 * folded with the PWA's own fold (the server's reference is checked against the same
 * vectors). Stop makes the entry, or leaves the run finishing when a required question
 * has no answer; finish makes or patches the entry; a finish of an open run answers 409
 * `run_open`. `override` can answer an event itself (a void reply, a 422). Every request
 * is recorded.
 */
import type {
  EntryOut,
  RunEventIn,
  RunEventResult,
  RunOut,
  TopicDetail,
  TopicVersionOut,
} from '../client';
import { fold, projectTiming, stateToWire, timingToWire } from '../lib/runs/fold';
import { formatInstant, parseInstant } from '../lib/runs/instant';
import type { RunEvent, RunStatus } from '../lib/runs/types';

export interface RecordedRequest {
  method: string;
  path: string;
  body: unknown;
}

interface StoredRun {
  id: string;
  topic_id: string;
  version: number;
  status: RunStatus;
  events: (RunEvent & { arrival: number })[];
  revision: number;
}

export interface FakeRunServer {
  runs: Map<string, StoredRun>;
  entries: EntryOut[];
  requests: RecordedRequest[];
  /** The `recordRunEvent` bodies, in order. */
  events: () => RunEventIn[];
  /** `listTopicVersions` fails (503): the device can't learn the steps. */
  versionsDown: boolean;
  /** Answer an event yourself: return a Response, or undefined for the normal handling. */
  override: ((body: RunEventIn, server: FakeRunServer) => Response | undefined) | null;
  fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
  runOut: (id: string) => RunOut;
  /** Record an event as if another device had sent it (not in `requests`). */
  record: (runId: string, body: RunEventIn) => void;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'X-QuickR-Server-Time': String(Date.now()) },
  });
const problem = (status: number, code: string) => json(status, { code, detail: code, errors: [] });

export function fakeRunServer(topic: TopicDetail, versions: TopicVersionOut[]): FakeRunServer {
  let arrival = 0;
  const server: FakeRunServer = {
    runs: new Map(),
    entries: [],
    requests: [],
    override: null,
    versionsDown: false,
    events: () =>
      server.requests
        .filter((r) => r.method === 'POST' && r.path.startsWith('/api/v1/runs/'))
        .map((r) => r.body as RunEventIn),
    fetch: (input, init) => handle(input, init),
    runOut,
    record: (runId, body) => {
      recordEvent(runId, body);
    },
  };

  const stepsOf = (version: number) =>
    versions.find((v) => v.version === version)?.timer?.steps ?? [];
  const questionsOf = (version: number) =>
    versions.find((v) => v.version === version)?.questions ?? topic.questions;

  function runOut(id: string): RunOut {
    const r = server.runs.get(id);
    if (!r) throw new Error(`no run ${id}`);
    const state = fold(r.id, stepsOf(r.version), r.events);
    return {
      id: r.id,
      topic_id: r.topic_id,
      version: r.version,
      status: r.status,
      revision: r.revision,
      started_at: formatInstant(state.started_at),
      ended_at: state.ended_at === null ? null : formatInstant(state.ended_at),
      edited: false,
      events: r.events.map((e) => ({
        id: e.id,
        type: e.type,
        at: formatInstant(e.at),
        seg: e.seg,
        step: e.step,
        pause_id: e.pause_id,
        arrival: e.arrival,
        effect: state.effects[e.id]?.effect ?? 'applied',
        reason: state.effects[e.id]?.reason ?? null,
        source: 'ui',
      })),
      state: { ...stateToWire(state), status: r.status },
      aliases: [],
    };
  }

  function makeEntry(
    r: StoredRun,
    answers: RunEventIn['answers'],
    notes: string | null | undefined,
  ) {
    const state = fold(r.id, stepsOf(r.version), r.events);
    const timing = timingToWire(projectTiming(state, stepsOf(r.version)));
    const types = new Map(questionsOf(r.version).map((q) => [q.key, q.type]));
    const now = new Date().toISOString();
    const entry: EntryOut = {
      id: r.id,
      topic_id: r.topic_id,
      version: r.version,
      revision: 1,
      source: 'ui',
      channel: 'ui',
      captured_at: timing.ended_at,
      created_at: now,
      updated_at: now,
      notes: notes ?? '',
      meta: {},
      answers: Object.entries(answers ?? {}).flatMap(([key, value]) => {
        const type = types.get(key);
        return type && value !== null ? [{ key, type, value }] : [];
      }) as EntryOut['answers'],
      timing: { ...timing, skipped: [...timing.skipped] },
    };
    server.entries = [entry, ...server.entries.filter((e) => e.id !== r.id)];
    return entry;
  }

  function result(
    status: number,
    r: StoredRun,
    eventId: string,
    effect?: RunEventResult['event'],
  ): Response {
    const out = runOut(r.id);
    const e = out.events.find((x) => x.id === eventId);
    const body: RunEventResult = {
      event: effect ?? { id: eventId, effect: e?.effect ?? 'applied', reason: e?.reason ?? null },
      run: out,
      entry: server.entries.find((x) => x.id === r.id) ?? null,
    };
    return json(status, body);
  }

  function recordEvent(runId: string, body: RunEventIn): Response {
    const custom = server.override?.(body, server);
    if (custom) return custom;
    if (body.type === 'start') {
      const r: StoredRun = {
        id: runId,
        topic_id: body.topic_id ?? '',
        version: body.version ?? 1,
        status: 'running',
        events: [],
        revision: 0,
      };
      server.runs.set(runId, r);
    }
    const r = server.runs.get(runId);
    if (!r) return problem(404, 'not_found');
    if (body.type === 'finish') {
      if (r.status === 'running' || r.status === 'paused') return problem(409, 'run_open');
      r.revision += 1;
      if (r.status === 'finishing') r.status = 'stopped';
      makeEntry(r, body.answers, body.notes);
      return result(200, r, body.id, { id: body.id, effect: 'applied', reason: null });
    }
    r.events.push({
      id: body.id,
      type: body.type,
      at: parseInstant(body.at),
      seg: body.seg ?? null,
      step: body.step ?? null,
      pause_id: body.pause_id ?? null,
      arrival: ++arrival,
    });
    r.revision += 1;
    const state = fold(r.id, stepsOf(r.version), r.events);
    if (state.status === 'stopped' && (r.status === 'running' || r.status === 'paused')) {
      const required = questionsOf(r.version).some((q) => q.required);
      if (required && body.answers == null) r.status = 'finishing';
      else {
        r.status = 'stopped';
        makeEntry(r, body.answers, body.notes);
      }
    } else if (state.status === 'discarded') r.status = 'discarded';
    else if (r.status === 'running' || r.status === 'paused') r.status = state.status;
    return result(body.type === 'start' ? 201 : 200, r, body.id);
  }

  async function handle(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const url = new URL(
      input instanceof Request ? input.url : input instanceof URL ? input.href : input,
      'https://q.test',
    );
    const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
    const text =
      typeof init?.body === 'string'
        ? init.body
        : input instanceof Request
          ? await input.text()
          : '';
    const body: unknown = text ? JSON.parse(text) : undefined;
    const path = url.pathname;
    server.requests.push({ method, path, body });

    const run = /^\/api\/v1\/runs\/([^/]+)\/events$/.exec(path);
    if (method === 'POST' && run)
      return recordEvent(decodeURIComponent(run[1] ?? ''), body as RunEventIn);
    if (method === 'GET' && path === '/api/v1/runs') {
      const listed = [...server.runs.values()].filter((r) =>
        ['running', 'paused', 'finishing'].includes(r.status),
      );
      return json(
        200,
        listed.map((r) => runOut(r.id)),
      );
    }
    const t = /^\/api\/v1\/topics\/([^/]+)(\/[a-z]+)?$/.exec(path);
    const ref = t ? decodeURIComponent(t[1] ?? '') : null;
    if (method === 'GET' && t && (ref === topic.id || ref === topic.slug)) {
      if (!t[2]) return json(200, topic);
      if (t[2] === '/versions') {
        return server.versionsDown ? problem(503, 'unavailable') : json(200, versions);
      }
      if (t[2] === '/entries') {
        return json(200, {
          items: server.entries,
          total: server.entries.length,
          limit: 25,
          offset: 0,
        });
      }
    }
    return problem(404, 'not_found');
  }

  return server;
}
