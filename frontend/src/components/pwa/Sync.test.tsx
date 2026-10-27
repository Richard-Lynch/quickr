/** The sync sheet's rows for run events: their titles and Fix paths (timers.md §8.1). */
import { describe, expect, it } from 'vitest';

import { T0, runItem } from '../../test/runs';
import { describeOutboxItem } from './Sync';

const invalid = { message: 'Invalid answers', status: 422, body: { code: 'validation_error' } };

describe('describeOutboxItem for run events', () => {
  it('a finish refused with a 422 is "Details", fixed in the answers form', () => {
    const item = {
      ...runItem('finish', { id: 'f1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: invalid,
    };
    expect(describeOutboxItem(item)).toMatchObject({
      title: 'Details · Morning',
      fixUrl: '/t/morning/record?fix=f1',
    });
  });

  it('a stop with answers refused with a 422 is fixed in the answers form too', () => {
    const item = {
      ...runItem('stop', { id: 's1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: invalid,
    };
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

  it('a stop failed as already logged (its start’s id_conflict) has no Fix', () => {
    const item = {
      ...runItem('stop', { id: 's1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: {
        message: 'Already logged elsewhere',
        status: 409,
        body: { code: 'id_conflict' },
      },
    };
    expect(describeOutboxItem(item).fixUrl).toBeNull();
  });

  it('answers refused other than with a 422 have no Fix (#59)', () => {
    const item = {
      ...runItem('finish', { id: 'f1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: { message: 'The run is still open', status: 409, body: { code: 'run_open' } },
    };
    expect(describeOutboxItem(item).fixUrl).toBeNull();
  });

  it('a 422 after an attempt that may have reached the server has no Fix', () => {
    const answers = {
      ...runItem('finish', { id: 'f1', run: 'r1', at: T0, answers: { mood: 2 }, status: 'failed' }),
      last_error: invalid,
      maybe_delivered: true,
    };
    expect(describeOutboxItem(answers).fixUrl).toBeNull();
    const stop = {
      ...runItem('stop', { id: 's1', run: 'r1', at: T0, status: 'failed' }),
      last_error: { message: 'Topic is not timed', status: 409, body: { code: 'topic_not_timed' } },
      maybe_delivered: true,
    };
    expect(describeOutboxItem(stop).fixUrl).toBeNull();
  });
});
