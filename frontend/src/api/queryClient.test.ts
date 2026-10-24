/** Entry changes refresh every cache whose numbers come from entries, timing included. */
import { describe, expect, it } from 'vitest';

import { getTopicTimingQueryKey } from '../client/@tanstack/react-query.gen';
import { createQueryClient, ENTRY_DATA_OPS, invalidateEntryData } from './queryClient';

describe('ENTRY_DATA_OPS', () => {
  it('includes getTopicTiming, so cached run times refresh when entries change', async () => {
    expect(ENTRY_DATA_OPS).toContain('getTopicTiming');
    const qc = createQueryClient();
    const key = getTopicTimingQueryKey({ path: { ref: 'routine' } });
    qc.setQueryData(key, { runs: 0 });
    await invalidateEntryData(qc);
    expect(qc.getQueryState(key)?.isInvalidated).toBe(true);
  });
});
