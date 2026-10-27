/** The page outbox's wiring: what happens around a send (timers.md §8.3). */
import 'fake-indexeddb/auto';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { T0, runEventResult, runItem } from '../../test/runs';
import { getAckedSnapshot, memoryAckedStore, setAckedStore } from '../runs/acked';
import { outbox, startOutbox } from './client';
import { RUN_EVENT } from './kinds';

afterEach(async () => {
  await outbox.clear();
  vi.unstubAllGlobals();
});

describe('page outbox', () => {
  it("refreshes the acked snapshot when a run event is sent, so the view doesn't lose it", async () => {
    setAckedStore(memoryAckedStore());
    vi.stubGlobal('fetch', () =>
      Promise.resolve(
        new Response(JSON.stringify(runEventResult('r1')), {
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    );
    const stop = startOutbox();
    const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
    await outbox.enqueue(RUN_EVENT, start.payload, { id: 'r1' });
    await outbox.flush();
    await vi.waitFor(() => {
      expect(getAckedSnapshot().map((i) => i.id)).toEqual(['r1']);
    });
    stop();
  });
});
