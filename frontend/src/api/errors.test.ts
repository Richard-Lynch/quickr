import { describe, expect, it, vi } from 'vitest';
import { z } from 'zod';

import { applyFieldErrors, cleanMessage, isConflict, locToPath, mapApiError } from './errors';

describe('locToPath', () => {
  it('strips body roots and pydantic union tags', () => {
    expect(locToPath(['body', 'questions', 0, 'int', 'min'])).toBe('questions.0.min');
    expect(locToPath(['answers', 'mood'])).toBe('answers.mood');
    expect(locToPath(['query', 'limit'])).toBe('limit');
    expect(locToPath(['body', 'questions', 2, 'enum'])).toBe('questions.2');
  });
});

describe('cleanMessage', () => {
  it('extracts pydantic value errors', () => {
    expect(cleanMessage('Value error, min must be <= max')).toBe('Min must be <= max');
    expect(
      cleanMessage(
        '1 validation error for QuestionSet\n  Value error, question keys must be unique [type=value_error]',
      ),
    ).toBe('Question keys must be unique');
    expect(cleanMessage('required')).toBe('Required');
  });
});

describe('mapApiError', () => {
  it('maps Problem envelopes', () => {
    const m = mapApiError({
      code: 'invalid_answers',
      detail: 'one or more answers are invalid',
      errors: [{ loc: ['answers', 'mood'], message: 'option is archived' }],
    });
    expect(m).toEqual({
      code: 'invalid_answers',
      message: 'One or more answers are invalid',
      fieldErrors: [{ path: 'answers.mood', message: 'Option is archived' }],
    });
  });

  it('maps FastAPI HTTPValidationError', () => {
    const m = mapApiError({
      detail: [
        {
          type: 'value_error',
          loc: ['body', 'questions', 0, 'int'],
          msg: 'Value error, min must be <= max',
        },
        { type: 'missing', loc: ['body', 'name'], msg: 'Field required' },
      ],
    });
    expect(m.code).toBe('validation_error');
    expect(m.message).toBe('Some fields need attention');
    expect(m.fieldErrors).toEqual([
      { path: 'questions.0', message: 'Min must be <= max' },
      { path: 'name', message: 'Field required' },
    ]);
  });

  it('maps client-side ZodErrors from the SDK validators', () => {
    const r = z
      .object({ body: z.object({ name: z.string().min(1) }) })
      .safeParse({ body: { name: '' } });
    expect(r.success).toBe(false);
    const m = mapApiError(r.error);
    expect(m.code).toBe('client_validation');
    expect(m.fieldErrors[0]?.path).toBe('name');
  });

  it('maps network and unknown errors', () => {
    expect(mapApiError(new TypeError('Failed to fetch')).code).toBe('network');
    expect(mapApiError(new Error('boom')).message).toBe('boom');
    expect(mapApiError('<html>Bad gateway</html>').message).toBe('<html>Bad gateway</html>');
    expect(mapApiError(undefined).message).toBe('Something went wrong');
  });

  it('detects conflicts', () => {
    expect(isConflict({ code: 'conflict', detail: 'stale', errors: [] })).toBe(true);
    expect(isConflict({ code: 'not_found', detail: 'x', errors: [] })).toBe(false);
    expect(isConflict(new Error('x'))).toBe(false);
  });
});

describe('applyFieldErrors', () => {
  it('places resolvable errors and returns the rest', () => {
    const setError = vi.fn();
    const rest = applyFieldErrors(
      [
        { path: 'answers.mood', message: 'bad' },
        { path: 'answers.ghost', message: 'unknown question' },
      ],
      (p) => (p === 'answers.mood' ? 'answers.mood' : null),
      setError,
    );
    expect(setError).toHaveBeenCalledWith('answers.mood', { type: 'server', message: 'bad' });
    expect(rest).toEqual([{ path: 'answers.ghost', message: 'unknown question' }]);
  });
});
