/**
 * Alert expressions (timers2.md §2): `t/2`, `t+30s`, `1.5m`.
 *
 * A port of the reference `backend/app/services/timer_expr.py`; both replay
 * `shared/fixtures/timer-expr-vectors.json`, whose `meta.semantics` states every rule below.
 * The error message is the server's, character for character (`"{code} at {pos}: {detail}"`,
 * the 422 message of timers2.md §1.3), so the builder can show it before the server does.
 *
 * Evaluation runs in three stages and reports the first error it meets:
 *
 * 1. the text is at most `maxLength` code points (`too_long` at 64);
 * 2. the whole text parses (`syntax` at the leftmost offending token or character; tokens are
 *    matched longest-first and read lazily, so an unknown character after a parse error is
 *    never reached);
 * 3. the tree evaluates on doubles in evaluation order: the left operand, the right operand,
 *    then the operator's checks (`type`, then `div_zero`, then `too_long` when a duration's
 *    magnitude exceeds 7 days; literals and variables are checked as they are read). Last, on
 *    the untruncated result: a number is `type` at 0, below 0 is `negative` at 0. The result is
 *    truncated toward zero to whole ms.
 *
 * Positions and lengths count Unicode code points, as Python's `str` does (not UTF-16 units).
 */

export const MAX_EXPR_LENGTH = 64;
/** 7 days: the bound on the result and on every duration on the way. */
export const MAX_EXPR_MS = 7 * 24 * 3_600_000;

export type ExprErrorCode =
  'syntax' | 'unknown_variable' | 'type' | 'negative' | 'too_long' | 'div_zero';

/** An expression that does not evaluate: `code` (§2.3), `pos` (a 0-based code-point offset)
 * and a human `detail`. `message` is the server's 422 message. */
export class ExprError extends Error {
  readonly code: ExprErrorCode;
  readonly pos: number;
  readonly detail: string;

  constructor(code: ExprErrorCode, pos: number, detail: string) {
    super(`${code} at ${String(pos)}: ${detail}`);
    this.name = 'ExprError';
    this.code = code;
    this.pos = pos;
    this.detail = detail;
  }
}

const UNIT_MS: Readonly<Record<string, number>> = { ms: 1, s: 1_000, m: 60_000, h: 3_600_000 };
const UNITS_LONGEST_FIRST = ['ms', 's', 'm', 'h'];

const WHITESPACE = new Set([' ', '\t', '\r', '\n']);
const isDigit = (c: string | undefined) => c !== undefined && c >= '0' && c <= '9';
const isLetter = (c: string | undefined) =>
  c !== undefined && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'));
const isIdent = (c: string | undefined) => isLetter(c) || isDigit(c) || c === '_';
const OPERATORS = new Set(['+', '-', '*', '/', '(', ')']);

// Python's str.isprintable(): everything but these categories (and space is printable).
const NON_PRINTABLE = /^[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\p{Zs}]$/u;

/** Python's `repr()` of one code point (the server spells unknown characters this way). */
export function pyRepr(c: string): string {
  let body: string;
  if (c === '\\') body = '\\\\';
  else if (c === '\t') body = '\\t';
  else if (c === '\n') body = '\\n';
  else if (c === '\r') body = '\\r';
  else if (c !== ' ' && NON_PRINTABLE.test(c)) {
    const cp = c.codePointAt(0) ?? 0;
    const hex = cp.toString(16);
    if (cp < 0x100) body = `\\x${hex.padStart(2, '0')}`;
    else if (cp < 0x10000) body = `\\u${hex.padStart(4, '0')}`;
    else body = `\\U${hex.padStart(8, '0')}`;
  } else body = c;
  // Python quotes with ' unless the text holds a ' and no ".
  return c === "'" ? `"'"` : `'${body}'`;
}

// --- tokens ---------------------------------------------------------------------------------

type TokenKind = 'number' | 'duration' | 'ident' | 'op' | 'end';

interface Token {
  kind: TokenKind;
  pos: number;
  text: string;
  value: number;
}

/** Reads one token at a time, so the leftmost error is the one reported. */
class Lexer {
  i = 0;
  private readonly text: readonly string[];
  constructor(text: readonly string[]) {
    this.text = text;
  }

  next(): Token {
    const text = this.text;
    const n = text.length;
    while (this.i < n && WHITESPACE.has(text[this.i] ?? '')) this.i += 1;
    const start = this.i;
    if (start === n) return { kind: 'end', pos: start, text: '', value: 0 };
    const c = text[start];
    if (isDigit(c)) return this.number(start);
    if (isLetter(c)) {
      let i = start + 1;
      while (i < n && isIdent(text[i])) i += 1;
      this.i = i;
      return { kind: 'ident', pos: start, text: text.slice(start, i).join(''), value: 0 };
    }
    if (c !== undefined && OPERATORS.has(c)) {
      this.i = start + 1;
      return { kind: 'op', pos: start, text: c, value: 0 };
    }
    throw new ExprError('syntax', start, `unknown character ${pyRepr(c ?? '')}`);
  }

  /** `number [unit]`, matched longest-first: `1.` is the number 1 (the `.` is the next,
   * unknown, character) and `30sec` is `30s` followed by the identifier `ec`. */
  private number(start: number): Token {
    const text = this.text;
    const n = text.length;
    let i = start;
    while (i < n && isDigit(text[i])) i += 1;
    if (i + 1 < n && text[i] === '.' && isDigit(text[i + 1])) {
      i += 1;
      while (i < n && isDigit(text[i])) i += 1;
    }
    const literal = text.slice(start, i).join('');
    const value = Number(literal);
    const unit = UNITS_LONGEST_FIRST.find((u) => text.slice(i, i + u.length).join('') === u);
    if (unit === undefined) {
      this.i = i;
      return { kind: 'number', pos: start, text: literal, value };
    }
    this.i = i + unit.length;
    return {
      kind: 'duration',
      pos: start,
      text: text.slice(start, this.i).join(''),
      value: value * (UNIT_MS[unit] ?? 1),
    };
  }
}

// --- tree -----------------------------------------------------------------------------------

type Node =
  | { kind: 'leaf'; token: Token }
  | { kind: 'neg'; operand: Node }
  | { kind: 'binary'; op: string; pos: number; left: Node; right: Node };

class Parser {
  private readonly lexer: Lexer;
  private token: Token;
  private previousEnd = -1;
  private previousNumeric = false;

  constructor(text: readonly string[]) {
    this.lexer = new Lexer(text);
    this.token = this.lexer.next();
  }

  private advance(): Token {
    const token = this.token;
    this.previousEnd = this.lexer.i;
    this.previousNumeric = token.kind === 'number' || token.kind === 'duration';
    this.token = this.lexer.next();
    return token;
  }

  private unexpected(): ExprError {
    const token = this.token;
    if (token.kind === 'end') {
      const detail = token.pos === 0 ? 'empty expression' : 'unexpected end';
      return new ExprError('syntax', token.pos, detail);
    }
    if (token.kind === 'ident' && this.previousEnd === token.pos && this.previousNumeric) {
      return new ExprError(
        'syntax',
        token.pos,
        `unknown unit ${pyRepr1(token.text)} (use ms, s, m or h)`,
      );
    }
    return new ExprError('syntax', token.pos, `unexpected ${pyRepr1(token.text)}`);
  }

  private isOp(ops: string): boolean {
    return this.token.kind === 'op' && ops.includes(this.token.text);
  }

  parse(): Node {
    const node = this.expr();
    if (this.token.kind !== 'end') throw this.unexpected();
    return node;
  }

  private expr(): Node {
    let node = this.term();
    while (this.isOp('+-')) {
      const op = this.advance();
      node = { kind: 'binary', op: op.text, pos: op.pos, left: node, right: this.term() };
    }
    return node;
  }

  private term(): Node {
    let node = this.factor();
    while (this.isOp('*/')) {
      const op = this.advance();
      node = { kind: 'binary', op: op.text, pos: op.pos, left: node, right: this.factor() };
    }
    return node;
  }

  private factor(): Node {
    const token = this.token;
    if (token.kind === 'number' || token.kind === 'duration' || token.kind === 'ident') {
      this.advance();
      return { kind: 'leaf', token };
    }
    if (this.isOp('-')) {
      this.advance();
      return { kind: 'neg', operand: this.factor() };
    }
    if (this.isOp('(')) {
      this.advance();
      const node = this.expr();
      if (!this.isOp(')')) throw this.unexpected();
      this.advance();
      return node;
    }
    throw this.unexpected();
  }
}

/** `repr()` of token text: ASCII letters, digits, `_`, `.` and operators only, so quoting is
 * all it needs. */
const pyRepr1 = (text: string) => `'${text}'`;

// --- evaluation -----------------------------------------------------------------------------

type Value = [value: number, duration: boolean];

function bounded(value: number, duration: boolean, maxMs: number): Value {
  if (duration && Math.abs(value) > maxMs) throw new ExprError('too_long', 0, 'longer than 7 days');
  return [value, duration];
}

const typeName = (duration: boolean) => (duration ? 'duration' : 'number');

function evalNode(node: Node, variables: ReadonlyMap<string, number>, maxMs: number): Value {
  if (node.kind === 'leaf') {
    const token = node.token;
    if (token.kind === 'ident') {
      const ms = variables.get(token.text.toLowerCase());
      if (ms === undefined)
        throw new ExprError(
          'unknown_variable',
          token.pos,
          `unknown variable ${pyRepr1(token.text)}`,
        );
      return bounded(ms, true, maxMs);
    }
    return bounded(token.value, token.kind === 'duration', maxMs);
  }
  if (node.kind === 'neg') {
    const [value, duration] = evalNode(node.operand, variables, maxMs);
    return [-value, duration];
  }
  const [left, leftDur] = evalNode(node.left, variables, maxMs);
  const [right, rightDur] = evalNode(node.right, variables, maxMs);
  const op = node.op;
  if (op === '+' || op === '-') {
    if (leftDur !== rightDur)
      throw new ExprError('type', node.pos, `${typeName(leftDur)} ${op} ${typeName(rightDur)}`);
    return bounded(op === '+' ? left + right : left - right, leftDur, maxMs);
  }
  if (op === '*') {
    if (leftDur && rightDur) throw new ExprError('type', node.pos, 'duration * duration');
    return bounded(left * right, leftDur || rightDur, maxMs);
  }
  if (rightDur) throw new ExprError('type', node.pos, `${typeName(leftDur)} / duration`);
  if (right === 0) throw new ExprError('div_zero', node.pos, 'division by zero');
  return bounded(left / right, leftDur, maxMs);
}

export interface EvaluateOptions {
  /** Code points (the server's `max_expr_length`). */
  maxLength?: number;
}

/**
 * The whole ms `text` evaluates to over `variables` (name -> ms; names match
 * case-insensitively, as stored lowercase). Throws {@link ExprError} with the §2.3 code and
 * position.
 */
export function evaluate(
  text: string,
  variables: Readonly<Record<string, number>> | ReadonlyMap<string, number>,
  { maxLength = MAX_EXPR_LENGTH }: EvaluateOptions = {},
): number {
  const chars = Array.from(text);
  if (chars.length > maxLength)
    throw new ExprError('too_long', maxLength, `longer than ${String(maxLength)} characters`);
  const vars =
    variables instanceof Map
      ? variables
      : new Map(Object.entries(variables).map(([k, v]) => [k.toLowerCase(), v]));
  const tree = new Parser(chars).parse();
  const [value, duration] = evalNode(tree, vars, MAX_EXPR_MS);
  if (!duration)
    throw new ExprError('type', 0, 'the result is a number: add a unit (ms, s, m or h)');
  if (value < 0) throw new ExprError('negative', 0, 'the result is below 0');
  return Math.trunc(value) + 0; // + 0: never -0
}

export type Evaluation = { ok: true; ms: number } | { ok: false; error: ExprError };

/** {@link evaluate} as a value. */
export function tryEvaluate(
  text: string,
  variables: Readonly<Record<string, number>> | ReadonlyMap<string, number>,
  options?: EvaluateOptions,
): Evaluation {
  try {
    return { ok: true, ms: evaluate(text, variables, options) };
  } catch (e) {
    if (e instanceof ExprError) return { ok: false, error: e };
    throw e;
  }
}
