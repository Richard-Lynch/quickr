/**
 * Normalise everything the API client can throw into one shape:
 * a banner message plus field errors keyed by dotted path.
 *
 * Sources:
 * - `Problem` envelope `{code, detail, errors: [{loc, message}]}` (every API 4xx,
 *   including request-shape 422s)
 * - `ZodError` from the generated SDK's request/response validators
 * - network failures / anything else
 */
import { z } from 'zod';

import type { Problem } from '../client';
import { zProblem } from '../client/zod.gen';

export interface FieldError {
  /** Dotted path relative to the request body, e.g. `questions.0.min` or `answers.mood`. */
  path: string;
  message: string;
}

export interface MappedError {
  message: string;
  code: string | null;
  fieldErrors: FieldError[];
}

const QUESTION_TAGS = new Set(['int', 'double', 'str', 'enum']);
const ROOTS = new Set(['body', 'query', 'path', 'header']);

/**
 * Turn a server `loc` into a body-relative dotted path. Drops the `body` root and
 * the discriminator tag pydantic inserts for tagged unions
 * (`['body','questions',0,'int','min']` -> `questions.0.min`).
 */
export function locToPath(loc: readonly (string | number)[]): string {
  const parts: (string | number)[] = [];
  loc.forEach((seg, i) => {
    if (i === 0 && typeof seg === 'string' && ROOTS.has(seg)) return;
    const prev = loc[i - 1];
    if (typeof seg === 'string' && QUESTION_TAGS.has(seg) && typeof prev === 'number') return;
    parts.push(seg);
  });
  return parts.join('.');
}

/** Pydantic messages look like "Value error, min must be <= max". */
export function cleanMessage(msg: string): string {
  const m = /Value error, ([^[\n]+)/.exec(msg);
  const text = (m?.[1] ?? msg).trim();
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function isProblem(e: unknown): e is Problem {
  return zProblem.safeParse(e).success;
}

const FRIENDLY_CODES: Record<string, string> = {
  conflict: 'Conflict',
  not_found: 'Not found',
  topic_archived: 'This topic is archived',
  invalid_answers: 'Some answers need attention',
  incompatible_version: 'This change is not allowed',
  invalid_request: 'Some fields need attention',
};

export function mapApiError(error: unknown): MappedError {
  if (isProblem(error)) {
    const fieldErrors = error.errors.map((i) => ({
      path: locToPath(i.loc),
      message: cleanMessage(i.message),
    }));
    const only = fieldErrors.length === 1 ? fieldErrors[0] : undefined;
    // Request-shape errors carry a generic detail; the single field issue is more useful.
    let message = cleanMessage(error.detail) || FRIENDLY_CODES[error.code] || 'Request failed';
    if (error.code === 'invalid_request') {
      message = only
        ? `${only.path ? `${only.path}: ` : ''}${only.message}`
        : 'Some fields need attention';
    }
    return { code: error.code, message, fieldErrors };
  }
  if (error instanceof z.ZodError) {
    return {
      code: 'client_validation',
      message: 'The request did not pass validation',
      fieldErrors: error.issues.map((i) => ({
        path: locToPath(i.path.filter((p): p is string | number => typeof p !== 'symbol')),
        message: i.message,
      })),
    };
  }
  if (error instanceof TypeError) {
    return { code: 'network', message: 'Could not reach the server', fieldErrors: [] };
  }
  if (error instanceof Error) {
    return { code: null, message: error.message || 'Something went wrong', fieldErrors: [] };
  }
  if (typeof error === 'string' && error.trim()) {
    return { code: null, message: error.trim().slice(0, 300), fieldErrors: [] };
  }
  return { code: null, message: 'Something went wrong', fieldErrors: [] };
}

export function errorMessage(error: unknown): string {
  return mapApiError(error).message;
}

export function isConflict(error: unknown): boolean {
  return isProblem(error) && error.code === 'conflict';
}

/**
 * Apply field errors to a form. `resolve` maps a server path to a form field
 * name (or null when the form has no such field). Returns the errors that
 * could not be placed — show those in a banner.
 */
export function applyFieldErrors<TName extends string>(
  fieldErrors: readonly FieldError[],
  resolve: (path: string) => TName | null,
  setError: (name: TName, error: { type: string; message: string }) => void,
): FieldError[] {
  const unplaced: FieldError[] = [];
  for (const fe of fieldErrors) {
    const name = resolve(fe.path);
    if (name === null) unplaced.push(fe);
    else setError(name, { type: 'server', message: fe.message });
  }
  return unplaced;
}
