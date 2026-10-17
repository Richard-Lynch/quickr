"""Quick-log descriptor for a topic version. Pure functions: no DB, no clock.

A port of ``frontend/src/lib/quickLog.ts`` (``quickLogFor`` / ``initialNumber``),
kept in lockstep with it by ``shared/fixtures/quicklog-vectors.json``: the vectors
are generated from this module and the frontend test suite asserts the TS
implementation agrees on every one.

Rule: the version has exactly one *required* question, and it is
 - a single-select enum with 1-6 active options -> its active options as chips, or
 - an int/double -> a number stepper prefilled by :func:`initial_number`.
Optional questions are ignored (a quick-log leaves them unanswered). Anything
else -- several required questions, a multi-select, text, only optional
questions -- logs through the record screen.
"""

from __future__ import annotations

import math
import re
from collections.abc import Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

from app.schemas.questions import DoubleQuestion, EnumOption, EnumQuestion, IntQuestion, StrQuestion

# Most options shown as chips (more need the record screen's select).
QUICK_CHIP_LIMIT = 6
# Number.MAX_SAFE_INTEGER: the client rejects larger whole numbers.
_MAX_SAFE_INTEGER = 2**53 - 1

# The client's input grammar (frontend/src/lib/answerSchema.ts).
_INT_RE = re.compile(r"[+-]?\d+", re.ASCII)
_NUM_RE = re.compile(r"[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?", re.ASCII)

AnyQuestion = IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion
NumericQuestion = IntQuestion | DoubleQuestion


@dataclass(frozen=True, slots=True)
class QuickLogChips:
    question: EnumQuestion
    options: tuple[EnumOption, ...]
    kind: Literal["chips"] = "chips"


@dataclass(frozen=True, slots=True)
class QuickLogNumber:
    question: NumericQuestion
    kind: Literal["number"] = "number"


QuickLog = QuickLogChips | QuickLogNumber


def quick_log_for(questions: Sequence[AnyQuestion]) -> QuickLog | None:
    required = [q for q in questions if q.required]
    if len(required) != 1:
        return None
    q = required[0]
    if isinstance(q, EnumQuestion):
        if q.multiple:
            return None
        options = tuple(o for o in q.options if not o.archived)
        if not 0 < len(options) <= QUICK_CHIP_LIMIT:
            return None
        return QuickLogChips(question=q, options=options)
    if isinstance(q, IntQuestion | DoubleQuestion):
        return QuickLogNumber(question=q)
    return None


def initial_number(q: NumericQuestion, last: object) -> str:
    """Starting text for a number quick-log: the last value while it is still valid,
    else the question's minimum when that is >= 0, else blank."""
    if isinstance(last, int | float) and not isinstance(last, bool):
        s = js_number_string(last)
        if _valid_number_input(q, s):
            return s
    if q.min is not None and q.min >= 0:
        return js_number_string(q.min)
    return ""


def _valid_number_input(q: NumericQuestion, raw: str) -> bool:
    """Whether the client would accept ``raw`` typed into ``q``'s number input."""
    s = raw.strip()
    if isinstance(q, IntQuestion):
        if not _INT_RE.fullmatch(s):
            return False
        n = float(int(s))  # Number(s)
        if abs(n) > _MAX_SAFE_INTEGER:
            return False
    else:
        if not _NUM_RE.fullmatch(s):
            return False
        n = float(s.replace(",", ".", 1))
        if not math.isfinite(n):
            return False
    # Bounds reach the client as JSON numbers, i.e. doubles: integer bounds beyond
    # 2**53 round, so compare as floats like the client does.
    if q.min is not None and n < float(q.min):
        return False
    return not (q.max is not None and n > float(q.max))


def js_number_string(x: float) -> str:
    """``String(x)`` for a JS number: ECMAScript ``Number::toString`` (radix 10).

    Shortest round-trip digits (as ``repr``), positional notation for exponents
    in [-7, 21), else ``1.5e-7`` / ``1e+21``. Whole floats print without ``.0``.
    """
    x = float(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0:
        return "0"  # -0 too
    if x < 0:
        return "-" + js_number_string(-x)
    t = Decimal(repr(x)).normalize().as_tuple()
    assert isinstance(t.exponent, int)
    digits = "".join(map(str, t.digits))
    k = len(digits)
    n = t.exponent + k  # x = 0.digits * 10**n
    if k <= n <= 21:
        return digits + "0" * (n - k)
    if 0 < n <= 21:
        return f"{digits[:n]}.{digits[n:]}"
    if -6 < n <= 0:
        return "0." + "0" * -n + digits
    e = n - 1
    mantissa = digits if k == 1 else f"{digits[0]}.{digits[1:]}"
    return f"{mantissa}e{'+' if e >= 0 else '-'}{abs(e)}"
