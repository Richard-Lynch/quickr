/** Taps from the run surfaces: a version-mismatch throw is handled, not lost (F-OUTBOX note). */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { runsQueryKey } from '../../api/runs';
import { client } from '../../client/client.gen';
import { outbox } from '../../lib/outbox/client';
import { memoryAckedStore, setAckedStore } from '../../lib/runs/acked';
import { CTX, T0, ev, serverRun } from '../../test/runs';
import { ToastProvider } from '../ui/Toast';
import { RUN_TAP_COOLDOWN_MS, setRunTapCooldown, useRunActions } from './useRunActions';

afterEach(async () => {
  setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
  await outbox.clear();
  vi.unstubAllGlobals();
});

function setup(fetch: typeof globalThis.fetch = () => Promise.reject(new TypeError('offline'))) {
  vi.stubGlobal('fetch', vi.fn(fetch));
  setAckedStore(memoryAckedStore());
  setRunTapCooldown(0);
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  qc.setQueryData(runsQueryKey(), [serverRun('r1', [ev('r1', 'start', T0)])]);
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={qc}>
      <ToastProvider>{children}</ToastProvider>
    </QueryClientProvider>
  );
  return renderHook(() => useRunActions(), { wrapper });
}

describe('useRunActions', () => {
  it('a tap with another version’s context enqueues nothing and says so', async () => {
    const { result } = setup();
    let out: unknown = 'unset';
    await act(async () => {
      out = await result.current.tap('r1', { ...CTX, version: 2 }, 'lap');
    });
    expect(out).toBeNull();
    expect(await outbox.list()).toEqual([]);
    expect(screen.getByRole('status')).toHaveTextContent('This run uses another version');
  });

  it('a tap with the run’s own version is enqueued', async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    const items = await outbox.list();
    expect(items.map((i) => (i.payload as { event: { type: string } }).event.type)).toEqual([
      'lap',
    ]);
  });
});

describe('finish', () => {
  it('a 409 run_open reaches the form, and the new item is dropped', async () => {
    client.setConfig({ baseUrl: 'http://quickr.test' });
    const problem = { code: 'run_open', detail: 'The run is still open', errors: [] };
    const { result } = setup(() =>
      Promise.resolve(
        new Response(JSON.stringify(problem), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    );
    let thrown: unknown = null;
    await act(async () => {
      await result.current
        .finish('gone-run', CTX, { answers: { mood: 2 } })
        .catch((e: unknown) => (thrown = e));
    });
    client.setConfig({ baseUrl: '' });
    expect(thrown).toMatchObject({ code: 'run_open' });
    // (An earlier test's lap may still be retrying in the shared outbox.)
    const mine = (await outbox.list()).filter(
      (x) => (x.payload as { run_id?: string }).run_id === 'gone-run',
    );
    expect(mine).toEqual([]);
  });
});
