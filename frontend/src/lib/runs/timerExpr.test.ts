/**
 * The expression port's errors (timers2.md §2.3): each code at the position of the token it is
 * reported at, and the server's 422 message (`"{code} at {pos}: {detail}"`, §1.3) spelt as
 * `backend/app/services/timer_expr.py` spells it, so the builder shows the server's text
 * before the server does. The messages below were copied from the Python evaluator's output.
 */
import { describe, expect, it } from 'vitest';

import { ExprError, evaluate, pyRepr, tryEvaluate } from './timerExpr';

const T = { t: 60_000 };

function message(text: string, variables: Record<string, number> = T): string {
  const r = tryEvaluate(text, variables);
  if (r.ok) throw new Error(`${text} evaluated to ${String(r.ms)}`);
  return r.error.message;
}

describe('timer expression errors', () => {
  it.each([
    ['-t', 'negative at 0: the result is below 0'],
    ['30S', "syntax at 2: unknown unit 'S' (use ms, s, m or h)"],
    ['30', 'type at 0: the result is a number: add a unit (ms, s, m or h)'],
    ['t+30', 'type at 1: duration + number'],
    ['t*t', 'type at 1: duration * duration'],
    ['2/t', 'type at 1: number / duration'],
    ['t/(t-t)', 'type at 1: duration / duration'],
    ['x/2', "unknown_variable at 0: unknown variable 'x'"],
    ['30+x', "unknown_variable at 3: unknown variable 'x'"],
    ['ab_c', "unknown_variable at 0: unknown variable 'ab_c'"],
    ['t/0', 'div_zero at 1: division by zero'],
    ['t/(1-1)', 'div_zero at 1: division by zero'],
    ['t/0+x', 'div_zero at 1: division by zero'],
    ['t+'.repeat(32) + 't', 'too_long at 64: longer than 64 characters'],
    ['168h+0.5ms', 'too_long at 0: longer than 7 days'],
    ['t+', 'syntax at 2: unexpected end'],
    ['x+', 'syntax at 2: unexpected end'],
    ['(t', 'syntax at 2: unexpected end'],
    ['', 'syntax at 0: empty expression'],
    ['   ', 'syntax at 3: unexpected end'],
    ['30d', "syntax at 2: unknown unit 'd' (use ms, s, m or h)"],
    ['30sec', "syntax at 3: unknown unit 'ec' (use ms, s, m or h)"],
    ['30sx', "syntax at 3: unknown unit 'x' (use ms, s, m or h)"],
    ['30 s', "syntax at 3: unexpected 's'"],
    ['1m30s', "syntax at 2: unexpected '30s'"],
    ['t 30s', "syntax at 2: unexpected '30s'"],
    ['t 1.s', "syntax at 2: unexpected '1'"],
    ['t)', "syntax at 1: unexpected ')'"],
    ['1.s', "syntax at 1: unknown character '.'"],
    ['t*.5', "syntax at 2: unknown character '.'"],
    ['1..2', "syntax at 1: unknown character '.'"],
    ['t +30s', "syntax at 1: unknown character '\\xa0'"],
    ['1+ ', "syntax at 2: unknown character '\\u2028'"],
    ['1+\u000b', "syntax at 2: unknown character '\\x0b'"],
    ["1+'", 'syntax at 2: unknown character "\'"'],
    ['1+\\', "syntax at 2: unknown character '\\\\'"],
    ['1+😀', "syntax at 2: unknown character '😀'"],
    ['😀'.repeat(33), "syntax at 0: unknown character '😀'"],
  ])('%j → %s', (text, expected) => {
    expect(message(text)).toBe(expected);
  });

  it('carries code, pos and detail separately', () => {
    const r = tryEvaluate('t+30', T);
    expect(r.ok).toBe(false);
    if (r.ok) return;
    expect(r.error).toBeInstanceOf(ExprError);
    expect([r.error.code, r.error.pos, r.error.detail]).toEqual(['type', 1, 'duration + number']);
  });

  it('counts positions in code points, not UTF-16 units', () => {
    // Two astral characters before the error: Python's offset 2, not 4.
    const r = tryEvaluate('😀😀', T);
    expect(r.ok ? null : r.error.pos).toBe(0);
    expect(message('t+(😀')).toBe("syntax at 3: unknown character '😀'");
    // 64 astral characters are 64 code points: within the limit, so the parse reports.
    expect(message('😀'.repeat(64))).toMatch(/^syntax at 0/);
    expect(message('😀'.repeat(65))).toBe('too_long at 64: longer than 64 characters');
  });

  it('takes the length limit from the server', () => {
    expect(() => evaluate('t+t', T, { maxLength: 2 })).toThrow(
      'too_long at 2: longer than 2 characters',
    );
  });

  it('matches variables case-insensitively and never answers -0', () => {
    expect(evaluate('T/2', T)).toBe(30_000);
    expect(evaluate('t/2', { T: 60_000 })).toBe(30_000);
    expect(Object.is(evaluate('-(t-t)', T), 0)).toBe(true);
    // Prototype names are not variables.
    expect(message('constructor')).toBe("unknown_variable at 0: unknown variable 'constructor'");
  });

  it('spells characters as Python’s repr() does', () => {
    expect(pyRepr('a')).toBe("'a'");
    expect(pyRepr("'")).toBe('"\'"');
    expect(pyRepr('é')).toBe("'é'");
    expect(pyRepr('​')).toBe("'\\u200b'");
    expect(pyRepr('\u{e0001}')).toBe("'\\U000e0001'");
  });
});
