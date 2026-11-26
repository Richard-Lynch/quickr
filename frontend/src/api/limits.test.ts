/** `FALLBACK_LIMITS` is a snapshot of the server's `GET /limits` (the generated fixture). */
import { describe, expect, it } from 'vitest';

import fixtureRaw from '../../../shared/fixtures/api/getLimits.json?raw';
import { FALLBACK_LIMITS } from './limits';

describe('FALLBACK_LIMITS', () => {
  it('equals the server defaults', () => {
    const fixture = JSON.parse(fixtureRaw) as { body: unknown };
    expect(FALLBACK_LIMITS).toEqual(fixture.body);
  });
});
