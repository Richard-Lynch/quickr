/** `FALLBACK_LIMITS` is a snapshot of the server's `GET /limits` (the generated fixture). */
import { describe, expect, it } from 'vitest';

import fixture from '../../../shared/fixtures/api/getLimits.json';
import { FALLBACK_LIMITS } from './limits';

describe('FALLBACK_LIMITS', () => {
  it('equals the server defaults', () => {
    expect(FALLBACK_LIMITS).toEqual(fixture.body);
  });
});
