/** Every API response is a server-time sample: the generated client's and the outbox's. */
import 'fake-indexeddb/auto';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { createClientConfig } from '../../api/clientConfig';
import { outbox } from '../outbox/client';
import { RUN_EVENT } from '../outbox/kinds';
import { runItem, T0 } from '../../test/runs';
import { memoryAckedStore, setAckedStore } from './acked';
import { SERVER_TIME_HEADER } from './clock';
import { resetServerOffset, serverOffset } from './serverClock';

afterEach(async () => {
  vi.useRealTimers(); // first: IndexedDB needs real timers
  resetServerOffset();
  await outbox.clear();
  vi.unstubAllGlobals();
});

const answer = (serverTime: number) =>
  vi.fn(() =>
    Promise.resolve(
      new Response('{}', {
        headers: { [SERVER_TIME_HEADER]: String(serverTime), 'Content-Type': 'application/json' },
      }),
    ),
  );

describe('server-time wiring (timers.md §5.1)', () => {
  it("the generated client's fetch records samples", async () => {
    vi.useFakeTimers({ now: 100_000 });
    const fetchMock = answer(102_000);
    vi.stubGlobal('fetch', fetchMock);
    const config = createClientConfig({});
    await config.fetch?.('/api/v1/runs');
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(serverOffset()).toBe(2000);
  });

  it("the page outbox's sends record samples", async () => {
    setAckedStore(memoryAckedStore());
    const fetchMock = answer(Date.now() + 7000);
    vi.stubGlobal('fetch', fetchMock);
    const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
    await outbox.enqueue(RUN_EVENT, start.payload, { id: 'r1' });
    await outbox.flush();
    expect(fetchMock).toHaveBeenCalledOnce();
    // About 7 s ahead (the real clock moved a little meanwhile).
    expect(Math.abs(serverOffset() - 7000)).toBeLessThan(1000);
  });
});
