/**
 * Client API levels (docs/specs/client-versions.md §5.1, V10, V14): the header every request
 * carries, and what fresh responses say. The bundle's level is 1 (shared/api-level.json).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { getClientVersions } from '../client';
import { client } from '../client/client.gen';
import { timedFetch } from '../lib/runs/serverClock';
import {
  API_LEVEL,
  API_LEVEL_HEADER,
  CLIENT_HEADER,
  CLIENT_HEADER_VALUE,
  FORCED_RELOAD_KEY,
  MIN_CLIENT_LEVEL_HEADER,
  clientVersionState,
  hasForcedReload,
  isClientOutdated,
  isClientOutdatedProblem,
  isServerBehind,
  markForcedReload,
  parseApiLevel,
  parseMinClientLevel,
  resetClientVersion,
} from './clientVersion';
import apiLevel from './apiLevel.json';
import { FROM_CACHE_HEADER } from './constants';

beforeEach(() => {
  // Node's Request needs an absolute URL.
  client.setConfig({ baseUrl: 'http://localhost' });
});

afterEach(() => {
  client.setConfig({ baseUrl: '' });
  resetClientVersion();
  sessionStorage.clear();
  vi.unstubAllGlobals();
});

/** A server answer with the level headers (§3.2). */
function answer(
  opts: { status?: number; level?: number; min?: number; body?: unknown; extra?: object } = {},
) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (opts.level !== undefined) headers[API_LEVEL_HEADER] = String(opts.level);
  if (opts.min !== undefined) headers[MIN_CLIENT_LEVEL_HEADER] = `ios=0, web=${opts.min}`;
  Object.assign(headers, opts.extra);
  return new Response(JSON.stringify(opts.body ?? {}), { status: opts.status ?? 200, headers });
}

/** The 426 body: the repo's Problem envelope (CV-SERVER), no type/title/status. */
const outdatedProblem = {
  code: 'client_outdated',
  detail: 'This version of quickR is too old for the server.',
  errors: [],
  min_client_level: 2,
  client_level: 1,
};

const VERSIONS = {
  api_level: 1,
  min_client_level: { ios: 0, web: 0 },
  update_url: { ios: 'itms-beta://' },
};

describe('the level copy (§2)', () => {
  it('is the api_level of src/api/apiLevel.json', () => {
    expect(API_LEVEL).toBe(apiLevel.api_level);
    expect(CLIENT_HEADER_VALUE).toBe(
      `web; level=${String(apiLevel.api_level)}; build=${__BUILD_TIME__}`,
    );
  });
});

describe('parsing', () => {
  it('reads the web minimum, wherever it is', () => {
    expect(parseMinClientLevel('ios=2, web=3')).toBe(3);
    expect(parseMinClientLevel('web=0,ios=4')).toBe(0);
    expect(parseMinClientLevel('ios=2')).toBeNull();
    expect(parseMinClientLevel('web=two')).toBeNull();
    expect(parseMinClientLevel(null)).toBeNull();
  });

  it('reads the API level', () => {
    expect(parseApiLevel(' 2 ')).toBe(2);
    expect(parseApiLevel('-1')).toBeNull();
    expect(parseApiLevel('')).toBeNull();
    expect(parseApiLevel(null)).toBeNull();
  });

  it('keys a 426 on its code', () => {
    expect(isClientOutdatedProblem(426, outdatedProblem)).toBe(true);
    expect(isClientOutdatedProblem(426, { code: 'other' })).toBe(false);
    expect(isClientOutdatedProblem(409, outdatedProblem)).toBe(false);
    expect(isClientOutdatedProblem(426, 'client_outdated')).toBe(false);
  });
});

describe('timedFetch sends X-QuickR-Client (§3.1)', () => {
  it('through the generated client, which passes a Request', async () => {
    const fetchMock = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(
      () => Promise.resolve(answer({ body: VERSIONS })),
    );
    vi.stubGlobal('fetch', fetchMock);
    const { data } = await getClientVersions();
    expect(data?.api_level).toBe(1);
    const sent = fetchMock.mock.calls[0]?.[0];
    expect(sent).toBeInstanceOf(Request);
    const headers = (sent as Request).headers;
    expect(headers.get(CLIENT_HEADER)).toBe(CLIENT_HEADER_VALUE);
    // The channel header the generated client set is still there.
    expect(headers.get('X-QuickR-Channel')).toBe('ui');
  });

  it("merges into a Request's headers and keeps its body", async () => {
    const base = vi.fn((input: RequestInfo | URL) => Promise.resolve(answer({ body: input })));
    const request = new Request('http://x/api/v1/entries', {
      method: 'POST',
      headers: { 'X-Other': 'kept' },
      body: '{"a":1}',
    });
    await timedFetch(base)(request);
    const sent = base.mock.calls[0]?.[0] as Request;
    expect(sent.headers.get(CLIENT_HEADER)).toBe(CLIENT_HEADER_VALUE);
    expect(sent.headers.get('X-Other')).toBe('kept');
    expect(sent.method).toBe('POST');
    expect(await sent.text()).toBe('{"a":1}');
  });

  it('merges into a URL and init (the outbox), keeping a plain object', async () => {
    const base = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(() =>
      Promise.resolve(answer()),
    );
    await timedFetch(base)('/api/v1/entries', {
      method: 'POST',
      headers: { 'X-QuickR-Channel': 'ui', Accept: 'application/json' },
    });
    expect(base.mock.calls[0]?.[1]).toMatchObject({
      method: 'POST',
      headers: {
        'X-QuickR-Channel': 'ui',
        Accept: 'application/json',
        [CLIENT_HEADER]: CLIENT_HEADER_VALUE,
      },
    });
  });

  it('merges into a Headers init, and adds headers to a bare URL', async () => {
    const base = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(() =>
      Promise.resolve(answer()),
    );
    await timedFetch(base)('/api/v1/a', { headers: new Headers({ 'X-Other': 'kept' }) });
    await timedFetch(base)('/api/v1/b');
    const first = new Headers(base.mock.calls[0]?.[1]?.headers);
    expect(first.get('X-Other')).toBe('kept');
    expect(first.get(CLIENT_HEADER)).toBe(CLIENT_HEADER_VALUE);
    expect(new Headers(base.mock.calls[1]?.[1]?.headers).get(CLIENT_HEADER)).toBe(
      CLIENT_HEADER_VALUE,
    );
  });

  it("doesn't replace a client header that is already there", async () => {
    const base = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(() =>
      Promise.resolve(answer()),
    );
    await timedFetch(base)('/api/v1/a', {
      headers: { 'x-quickr-client': 'web; level=9; build=t' },
    });
    expect(base.mock.calls[0]?.[1]?.headers).toEqual({
      'x-quickr-client': 'web; level=9; build=t',
    });
  });
});

describe('detection (§5.1)', () => {
  const fetchOnce = (res: Response) => timedFetch(() => Promise.resolve(res))('/api/v1/topics');

  it('a minimum above the bundle is outdated, through the generated client', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.resolve(answer({ level: 2, min: 2, body: VERSIONS }))),
    );
    await getClientVersions();
    expect(isClientOutdated()).toBe(true);
  });

  it('a 426 client_outdated is outdated, whatever the headers say', async () => {
    await fetchOnce(answer({ status: 426, body: outdatedProblem }));
    expect(isClientOutdated()).toBe(true);
  });

  it('another 426 is not', async () => {
    await fetchOnce(answer({ status: 426, body: { code: 'other', detail: 'x', errors: [] } }));
    expect(isClientOutdated()).toBe(false);
  });

  it('the body stays readable for the caller', async () => {
    const res = await fetchOnce(answer({ status: 426, body: outdatedProblem }));
    expect(await res.json()).toEqual(outdatedProblem);
  });

  it("ignores a cached response's headers", async () => {
    await fetchOnce(answer({ level: 0, min: 5, extra: { [FROM_CACHE_HEADER]: '1' } }));
    await fetchOnce(answer({ status: 426, body: outdatedProblem, extra: { Age: '30' } }));
    expect(clientVersionState()).toEqual({ outdated: false, serverApiLevel: null });
  });

  it('a fresh response that is not outdated clears the state and the reload mark', async () => {
    markForcedReload();
    await fetchOnce(answer({ level: 1, min: 2 }));
    expect(isClientOutdated()).toBe(true);
    expect(hasForcedReload()).toBe(true);
    await fetchOnce(answer({ level: 1, min: 0 }));
    expect(isClientOutdated()).toBe(false);
    expect(sessionStorage.getItem(FORCED_RELOAD_KEY)).toBeNull();
  });

  it("a response without the level headers (a proxy's page) says nothing", async () => {
    markForcedReload();
    await fetchOnce(answer({ level: 1, min: 2 }));
    await fetchOnce(new Response('Bad gateway', { status: 502 }));
    expect(isClientOutdated()).toBe(true);
    expect(hasForcedReload()).toBe(true);
  });

  it('a cached response that is not outdated keeps the reload mark', async () => {
    markForcedReload();
    await fetchOnce(answer({ level: 1, min: 0, extra: { [FROM_CACHE_HEADER]: '1' } }));
    expect(hasForcedReload()).toBe(true);
  });
});

describe('the server behind (§5.4, V14)', () => {
  const fetchOnce = (res: Response) => timedFetch(() => Promise.resolve(res))('/api/v1/topics');

  it('a level below the bundle is behind; one at it is not', async () => {
    await fetchOnce(answer({ level: API_LEVEL - 1, min: 0 }));
    expect(isServerBehind()).toBe(true);
    expect(isClientOutdated()).toBe(false);
    // A response without the header keeps what the last one said.
    await fetchOnce(new Response('', { status: 502 }));
    expect(isServerBehind()).toBe(true);
    await fetchOnce(answer({ level: API_LEVEL, min: 0 }));
    expect(isServerBehind()).toBe(false);
    await fetchOnce(answer({ level: API_LEVEL + 1, min: 0 }));
    expect(isServerBehind()).toBe(false);
  });
});
