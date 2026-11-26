/** Taps from the run surfaces: a version-mismatch throw is handled, not lost (F-OUTBOX note). */
import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, screen, waitFor } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { runsQueryKey } from '../../api/runs';
import { client } from '../../client/client.gen';
import { outbox } from '../../lib/outbox/client';
import { memoryAckedStore, setAckedStore } from '../../lib/runs/acked';
import { CTX, T0, ev, serverRun } from '../../test/runs';
import { tapCooldownOn } from '../../test/tapClock';
import { ToastProvider } from '../ui/Toast';
import {
  RUN_TAP_COOLDOWN_MS,
  setRunTapCooldown,
  useRunActions,
  useRunCooldown,
} from './useRunActions';

afterEach(async () => {
  vi.restoreAllMocks();
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
  return renderHook(() => ({ ...useRunActions(), cooling: useRunCooldown(CTX.topic.id) }), {
    wrapper,
  });
}

/** The run events this test enqueued, by type (the outbox is shared across tests). */
async function mine(before: Set<string>): Promise<string[]> {
  return (await outbox.list())
    .filter((i) => !before.has(i.id))
    .map((i) => (i.payload as { event: { type: string } }).event.type);
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

  it('a discard isn’t held by the cooldown (it is confirmed first, as on iOS)', async () => {
    const { result } = setup();
    // Time stands still: the discard is inside the lap's cooldown however slow the machine.
    tapCooldownOn();
    // (An earlier test's lap may still be in the shared outbox.)
    const before = new Set((await outbox.list()).map((i) => i.id));
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
      await result.current.tap('r1', CTX, 'discard');
    });
    expect(await mine(before)).toEqual(['lap', 'discard']);
  });
});

describe('the tap cooldown’s clock (#188)', () => {
  it('ignores a second tap until the cooldown has passed, then takes it', async () => {
    const { result } = setup();
    const clock = tapCooldownOn();
    const before = new Set((await outbox.list()).map((i) => i.id));
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(result.current.cooling).toBe(true);
    clock.advance(RUN_TAP_COOLDOWN_MS - 1);
    expect(result.current.cooling).toBe(true);
    await act(async () => {
      expect(await result.current.tap('r1', CTX, 'lap')).toBeNull();
    });
    clock.advance(1);
    expect(result.current.cooling).toBe(false);
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(await mine(before)).toEqual(['lap', 'lap']);
  });

  it('a clock that steps back doesn’t leave the controls dead', async () => {
    const { result } = setup();
    const clock = tapCooldownOn();
    clock.advance(3_600_000);
    const before = new Set((await outbox.list()).map((i) => i.id));
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(result.current.cooling).toBe(true);
    // Set back an hour: behind the tap, which ends its cooldown rather than stretching it.
    clock.advance(-3_600_000);
    expect(result.current.cooling).toBe(false);
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(await mine(before)).toEqual(['lap', 'lap']);
  });

  it('runs on monotonic time: the device clock moving changes nothing', async () => {
    const { result } = setup();
    // The app's own clock (no injected one), with monotonic time held still by hand, so a
    // slow machine can't end the cooldown before the double tap below.
    let mono = 1_000;
    vi.spyOn(performance, 'now').mockImplementation(() => mono);
    setRunTapCooldown(50);
    const before = new Set((await outbox.list()).map((i) => i.id));
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(result.current.cooling).toBe(true);
    const wall = Date.now();
    const now = vi.spyOn(Date, 'now');
    // Set on an hour: the cooldown isn't over early, so the double tap is still ignored.
    now.mockImplementation(() => wall + 3_600_000);
    await act(async () => {
      expect(await result.current.tap('r1', CTX, 'lap')).toBeNull();
    });
    // Set back an hour, and the cooldown's time passes: it ends on time.
    now.mockImplementation(() => wall - 3_600_000);
    mono += 50;
    // The cooldown's own timer re-enables the controls: nothing else re-renders the hook.
    await waitFor(() => expect(result.current.cooling).toBe(false));
    await act(async () => {
      await result.current.tap('r1', CTX, 'lap');
    });
    expect(await mine(before)).toEqual(['lap', 'lap']);
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
