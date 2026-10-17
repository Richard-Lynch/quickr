/**
 * Text lengths as the server counts them. Python's `len` and pydantic's `max_length` count
 * code points; JS `.length` counts UTF-16 units, which over-counts emoji and other astral
 * characters (one code point, two units). iOS counts code points too.
 */

/** Characters in `s`, counted as code points. */
export function charCount(s: string): number {
  return Array.from(s).length;
}

/**
 * A native `maxLength` (UTF-16 units) that never blocks a value within `max` code points:
 * every code point is at most two units. Validation enforces the exact limit.
 */
export function inputMaxLength(max: number): number {
  return 2 * max;
}

/** The server rejects NUL in text answers (`services/answers.py`). iOS shows the same message. */
export const INVALID_CHARACTER_MESSAGE = 'Remove the invalid character';

export function hasInvalidCharacter(s: string): boolean {
  return s.includes('\u0000');
}
