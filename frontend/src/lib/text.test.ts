import { describe, expect, it } from 'vitest';

import { notesSchema, sourceSchema } from './entryMeta';
import { charCount, inputMaxLength } from './text';
import { FALLBACK_LIMITS } from '../api/limits';

describe('text lengths count code points, like the server and iOS', () => {
  it('counts an emoji as one character', () => {
    expect(charCount('')).toBe(0);
    expect(charCount('abc')).toBe(3);
    expect(charCount('😀')).toBe(1);
    expect('😀'.length).toBe(2);
    expect(charCount('a😀b')).toBe(3);
  });

  it('native maxLength never blocks a value within the limit', () => {
    expect(inputMaxLength(5)).toBeGreaterThanOrEqual('😀😀😀😀😀'.length);
  });

  it('source and notes limits count code points', () => {
    const limits = { ...FALLBACK_LIMITS, max_source_length: 2, max_notes_length: 3 };
    expect(sourceSchema(limits).safeParse('😀😀').success).toBe(true);
    expect(sourceSchema(limits).safeParse('😀😀😀').error?.issues[0]?.message).toBe(
      'At most 2 characters',
    );
    expect(notesSchema(limits).safeParse(' 😀😀😀 ').data).toBe('😀😀😀');
    expect(notesSchema(limits).safeParse('😀😀😀😀').error?.issues[0]?.message).toBe(
      'At most 3 characters',
    );
  });
});
