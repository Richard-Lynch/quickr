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

// Python's str.isspace(): what the server's str.strip() removes. Unlike JS trim(), it includes
// U+001C–U+001F and U+0085 and excludes U+FEFF.
const PY_SPACE =
  '\\t\\n\\v\\f\\r\\x1c-\\x20\\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000';
const PY_STRIP = new RegExp(`^[${PY_SPACE}]+|[${PY_SPACE}]+$`, 'g');

/**
 * Text as the server normalises answers (`services/answers.py::_normalise`, Python
 * `str.strip()`), so a value that validates is exactly what the server stores. iOS does the
 * same (`ServerText.strip`); see shared/fixtures/answer-text-vectors.json.
 */
export function serverStrip(s: string): string {
  return s.replace(PY_STRIP, '');
}
