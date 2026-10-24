/**
 * A tap's `listRuns` refresh is best effort (review H2): with the app's real query client
 * (retries, `offlineFirst`) it must still settle, offline or with a server that never
 * answers, or every later tap would wait behind it.
 */
import 'fake-indexeddb/auto';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { client } from '../client/client.gen';
import { outbox } from '../lib/outbox/client';
import { memoryAckedStore, setAckedStore } from '../lib/runs/acked';
import { tapRun } from '../lib/runs/actions';
import { CTX } from '../test/runs';
import { createQueryClient } from './queryClient';
import { refreshRunsForTap, runTapDeps } from './runs';

const never = () => new Promise<Response>(() => undefined);

beforeEach(() => {
  client.setConfig({ baseUrl: 'http://quickr.test' });
  setAckedStore(memoryAckedStore());
});

afterEach(async () => {
  client.setConfig({ baseUrl: '' });
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  await outbox.clear();
});

function setOnline(online: boolean) {
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(online);
}

describe('refreshRunsForTap', () => {
  it('offline: settles at once without a request', async () => {
    const fetch = vi.fn(never);
    vi.stubGlobal('fetch', fetch);
    setOnline(false);
    await refreshRunsForTap(createQueryClient(), 10_000);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('a server that never answers: settles after the timeout', async () => {
    vi.stubGlobal('fetch', vi.fn(never));
    setOnline(true);
    const t = Date.now();
    await refreshRunsForTap(createQueryClient(), 50);
    expect(Date.now() - t).toBeLessThan(2_000);
  });

  it('a failing server: settles without retrying', async () => {
    const fetch = vi.fn(() => Promise.reject(new TypeError('Failed to fetch')));
    vi.stubGlobal('fetch', fetch);
    setOnline(true);
    await refreshRunsForTap(createQueryClient(), 10_000);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('a finish of a run not in the view, then another tap: neither hangs', async () => {
    vi.stubGlobal('fetch', vi.fn(never));
    setOnline(true);
    const deps = runTapDeps(createQueryClient(), 50);
    const finish = await tapRun(deps, 'gone-run', CTX, 'finish', { answers: { mood: 1 } });
    expect(finish?.payload.event.type).toBe('finish');
    // The taps' chain isn't stuck: the next one runs (and finds no run to lap).
    expect(await tapRun(deps, 'gone-run', CTX, 'lap')).toBeNull();
  });
});
