/** The sync sheet's rows for run events: their titles and Fix paths (timers.md §8.1). */
import { describe, expect, it } from 'vitest';

import { T0, runItem } from '../../test/runs';
import { describeOutboxItem } from './Sync';

describe('describeOutboxItem for run events', () => {
  it('a finish is "Details", fixed in the answers form', () => {
    const item = runItem('finish', { id: 'f1', run: 'r1', at: T0, answers: { mood: 2 } });
    expect(describeOutboxItem(item)).toMatchObject({
      title: 'Details · Morning',
      fixUrl: '/t/morning/record?fix=f1',
    });
  });

  it('a stop with answers is fixed in the answers form too', () => {
    const item = runItem('stop', { id: 's1', run: 'r1', at: T0, answers: { mood: 2 } });
    expect(describeOutboxItem(item).fixUrl).toBe('/t/morning/record?fix=s1');
  });

  it('a plain stop is fixed on the run panel', () => {
    const item = runItem('stop', { id: 's1', run: 'r1', at: T0 });
    expect(describeOutboxItem(item)).toMatchObject({
      title: 'Stop · Morning',
      fixUrl: '/t/morning/record',
    });
  });

  it('other taps have no Fix', () => {
    expect(
      describeOutboxItem(runItem('next', { id: 'n1', run: 'r1', at: T0, seg: 0 })).fixUrl,
    ).toBeNull();
  });

  it('a finish the server answered 404 (deleted elsewhere) has no Fix', () => {
    const item = {
      ...runItem('finish', { id: 'f1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: { message: 'Not found', status: 404 },
    };
    expect(describeOutboxItem(item).fixUrl).toBeNull();
  });
});
