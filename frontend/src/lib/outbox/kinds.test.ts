import { describe, expect, it } from 'vitest';

import { ENTRY_CREATE, OUTBOX_KINDS, problemCode } from './kinds';

describe('entry.create classification', () => {
  const classify = (status: number, body: unknown) =>
    OUTBOX_KINDS[ENTRY_CREATE]?.classify?.(status, body);

  it('retires a create whose id was deleted on the server', () => {
    expect(classify(409, { code: 'entry_deleted', detail: 'gone', errors: [] })).toBe('retired');
  });

  it('leaves every other response to the default classification', () => {
    expect(classify(409, { code: 'conflict', detail: 'other topic', errors: [] })).toBeUndefined();
    expect(classify(404, { code: 'entry_deleted' })).toBeUndefined();
    expect(classify(409, undefined)).toBeUndefined();
    expect(classify(201, { id: 'x' })).toBeUndefined();
  });

  it('reads Problem codes defensively', () => {
    expect(problemCode({ code: 'x' })).toBe('x');
    expect(problemCode({ code: 1 })).toBeUndefined();
    expect(problemCode('x')).toBeUndefined();
    expect(problemCode(null)).toBeUndefined();
  });
});
