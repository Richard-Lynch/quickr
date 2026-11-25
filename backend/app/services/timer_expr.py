"""Alert expressions (docs/specs/timers2.md §2): ``t/2``, ``t+30s``, ``1.5m``.

The reference implementation; the PWA (``lib/runs/timerExpr.ts``) and iOS (``TimerExpr.swift``)
ports replay ``shared/fixtures/timer-expr-vectors.json`` (generator
``tests/test_timer_expr_vectors.py``), whose ``meta.semantics`` states every rule below.

Grammar (§2.1)::

    expr     := term { ('+' | '-') term }
    term     := factor { ('*' | '/') factor }
    factor   := duration | number | ident | '(' expr ')' | '-' factor
    duration := number unit          unit := 'ms' | 's' | 'm' | 'h'
    number   := digit { digit } [ '.' digit { digit } ]
    ident    := letter { letter | digit | '_' }

Evaluation runs in three stages and reports the first error it meets:

1. the text is at most :data:`MAX_LENGTH` code points (``too_long`` at 64);
2. the whole text parses (``syntax`` at the leftmost offending character; tokens are read lazily,
   so an unknown character after a parse error is never reached);
3. the tree evaluates on doubles in evaluation order: the left operand, the right operand, then
   the operator's checks (``type``, then ``div_zero``, then ``too_long`` when a duration's
   magnitude exceeds :data:`MAX_MS`; literals and variables are checked as they are read). Last,
   on the untruncated result: a number is ``type`` at 0, below 0 is ``negative`` at 0. The result
   is truncated toward zero to whole ms.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

MAX_LENGTH = 64  # characters (Unicode code points) of an expression
MAX_MS = 7 * 24 * 3_600_000  # 7 days: the bound on the result and on every duration on the way

UNIT_MS: dict[str, float] = {"ms": 1.0, "s": 1_000.0, "m": 60_000.0, "h": 3_600_000.0}

ErrorCode = Literal["syntax", "unknown_variable", "type", "negative", "too_long", "div_zero"]

_WHITESPACE = frozenset(" \t\r\n")
_DIGITS = frozenset("0123456789")
_LETTERS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
_IDENT = _LETTERS | _DIGITS | {"_"}
_OPERATORS = frozenset("+-*/()")


class ExprError(ValueError):
    """An expression that does not evaluate: ``code`` (§2.3), ``pos`` (a 0-based code-point
    offset) and a human ``detail``. ``str()`` is the 422 message of timers2.md §1.3."""

    def __init__(self, code: ErrorCode, pos: int, detail: str) -> None:
        super().__init__(f"{code} at {pos}: {detail}")
        self.code: ErrorCode = code
        self.pos = pos
        self.detail = detail


# --- tokens -----------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Token:
    kind: Literal["number", "duration", "ident", "op", "end"]
    pos: int
    text: str = ""
    value: float = 0.0


class _Lexer:
    """Reads one token at a time, so the leftmost error is the one reported."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.i = 0

    def next(self) -> _Token:
        text, n = self.text, len(self.text)
        while self.i < n and text[self.i] in _WHITESPACE:
            self.i += 1
        start = self.i
        if start == n:
            return _Token("end", start)
        c = text[start]
        if c in _DIGITS:
            return self._number(start)
        if c in _LETTERS:
            i = start + 1
            while i < n and text[i] in _IDENT:
                i += 1
            self.i = i
            return _Token("ident", start, text[start:i])
        if c in _OPERATORS:
            self.i = start + 1
            return _Token("op", start, c)
        raise ExprError("syntax", start, f"unknown character {c!r}")

    def _number(self, start: int) -> _Token:
        text, n = self.text, len(self.text)
        i = start
        while i < n and text[i] in _DIGITS:
            i += 1
        if i < n and text[i] == ".":
            if i + 1 >= n or text[i + 1] not in _DIGITS:
                raise ExprError("syntax", i, "a '.' must be followed by a digit")
            i += 1
            while i < n and text[i] in _DIGITS:
                i += 1
        literal = text[start:i]
        value = float(literal)
        if i < n and text[i] in _LETTERS:
            unit_start = i
            while i < n and text[i] in _LETTERS:
                i += 1
            unit = text[unit_start:i]
            if unit not in UNIT_MS:
                raise ExprError("syntax", unit_start, f"unknown unit {unit!r} (use ms, s, m or h)")
            self.i = i
            return _Token("duration", start, text[start:i], value * UNIT_MS[unit])
        self.i = i
        return _Token("number", start, literal, value)


# --- tree -------------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Leaf:
    token: _Token


@dataclass(frozen=True, slots=True)
class _Neg:
    operand: _Node


@dataclass(frozen=True, slots=True)
class _Binary:
    op: str
    pos: int
    left: _Node
    right: _Node


_Node = _Leaf | _Neg | _Binary


class _Parser:
    def __init__(self, text: str) -> None:
        self.lexer = _Lexer(text)
        self.token = self.lexer.next()

    def advance(self) -> _Token:
        token = self.token
        self.token = self.lexer.next()
        return token

    def unexpected(self) -> ExprError:
        token = self.token
        if token.kind == "end":
            detail = "empty expression" if token.pos == 0 else "unexpected end"
            return ExprError("syntax", token.pos, detail)
        return ExprError("syntax", token.pos, f"unexpected {token.text!r}")

    def is_op(self, ops: str) -> bool:
        return self.token.kind == "op" and self.token.text in ops

    def parse(self) -> _Node:
        node = self.expr()
        if self.token.kind != "end":
            raise self.unexpected()
        return node

    def expr(self) -> _Node:
        node = self.term()
        while self.is_op("+-"):
            op = self.advance()
            node = _Binary(op.text, op.pos, node, self.term())
        return node

    def term(self) -> _Node:
        node = self.factor()
        while self.is_op("*/"):
            op = self.advance()
            node = _Binary(op.text, op.pos, node, self.factor())
        return node

    def factor(self) -> _Node:
        token = self.token
        if token.kind in ("number", "duration", "ident"):
            self.advance()
            return _Leaf(token)
        if self.is_op("-"):
            self.advance()
            return _Neg(self.factor())
        if self.is_op("("):
            self.advance()
            node = self.expr()
            if not self.is_op(")"):
                raise self.unexpected()
            self.advance()
            return node
        raise self.unexpected()


# --- evaluation -------------------------------------------------------------------------------


def _bounded(value: float, duration: bool) -> tuple[float, bool]:
    if duration and abs(value) > MAX_MS:
        raise ExprError("too_long", 0, "longer than 7 days")
    return value, duration


def _type_name(duration: bool) -> str:
    return "duration" if duration else "number"


def _eval(node: _Node, variables: Mapping[str, int]) -> tuple[float, bool]:
    """``(value, is_duration)``; durations are ms."""
    if isinstance(node, _Leaf):
        token = node.token
        if token.kind == "ident":
            ms = variables.get(token.text.lower())
            if ms is None:
                raise ExprError("unknown_variable", token.pos, f"unknown variable {token.text!r}")
            return _bounded(float(ms), True)
        return _bounded(token.value, token.kind == "duration")
    if isinstance(node, _Neg):
        value, duration = _eval(node.operand, variables)
        return -value, duration
    left, left_dur = _eval(node.left, variables)
    right, right_dur = _eval(node.right, variables)
    op = node.op
    if op in "+-":
        if left_dur != right_dur:
            raise ExprError("type", node.pos, f"{_type_name(left_dur)} {op} {_type_name(right_dur)}")
        return _bounded(left + right if op == "+" else left - right, left_dur)
    if op == "*":
        if left_dur and right_dur:
            raise ExprError("type", node.pos, "duration * duration")
        return _bounded(left * right, left_dur or right_dur)
    if right_dur:
        raise ExprError("type", node.pos, f"{_type_name(left_dur)} / duration")
    if right == 0:
        raise ExprError("div_zero", node.pos, "division by zero")
    return _bounded(left / right, left_dur)


def evaluate(text: str, variables: Mapping[str, int]) -> int:
    """The whole ms ``text`` evaluates to over ``variables`` (lowercase name -> ms, as stored).

    Raises :class:`ExprError` with the §2.3 code and position.
    """
    if len(text) > MAX_LENGTH:
        raise ExprError("too_long", MAX_LENGTH, f"longer than {MAX_LENGTH} characters")
    tree = _Parser(text).parse()
    value, duration = _eval(tree, variables)
    if not duration:
        raise ExprError("type", 0, "the result is a number: add a unit (ms, s, m or h)")
    if value < 0:
        raise ExprError("negative", 0, "the result is below 0")
    return math.trunc(value)
