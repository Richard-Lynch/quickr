import { beforeEach, describe, expect, it, vi } from 'vitest';

import { T0, runItem } from '../../test/runs';
import {
  ACKED_MAX_AGE_MS,
  ackedItems,
  getAckedSnapshot,
  memoryAckedStore,
  pruneAcked,
  recordAcked,
  setAckedStore,
  subscribeAcked,
} from './acked';

beforeEach(() => {
  setAckedStore(memoryAckedStore());
});

describe('acked run events', () => {
  const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
  const next = runItem('next', { id: 'n1', run: 'r1', at: T0 + 1000, seg: 0 });

  it('keeps an ack until a listRuns fetch that began after it answers', async () => {
    await recordAcked(start, 1000);
    await recordAcked(next, 2000);
    await pruneAcked(1500, 2500);
    expect((await ackedItems()).map((i) => i.id)).toEqual(['n1']);
    expect(getAckedSnapshot().map((i) => i.id)).toEqual(['n1']);
  });

  it('with a time, leaves out records older than the maximum age (the SW’s view)', async () => {
    await recordAcked(start, 1000);
    await recordAcked(next, 2000);
    expect((await ackedItems(1000 + ACKED_MAX_AGE_MS)).map((i) => i.id)).toEqual(['r1', 'n1']);
    expect((await ackedItems(1000 + ACKED_MAX_AGE_MS + 1)).map((i) => i.id)).toEqual(['n1']);
    expect((await ackedItems()).map((i) => i.id)).toEqual(['r1', 'n1']); // no time: all
  });

  it('drops anything older than the maximum age', async () => {
    await recordAcked(start, 1000);
    await pruneAcked(0, 1000 + ACKED_MAX_AGE_MS + 1);
    expect(await ackedItems()).toEqual([]);
  });

  it('tells subscribers when the snapshot changes', async () => {
    const listener = vi.fn();
    const stop = subscribeAcked(listener);
    await pruneAcked(0);
    expect(listener).toHaveBeenCalledOnce();
    stop();
  });
});
