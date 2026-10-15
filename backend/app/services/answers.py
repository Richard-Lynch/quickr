"""Validate raw answer maps against a topic version's question config."""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from app.errors import InvalidAnswers
from app.schemas.api import FieldIssue
from app.schemas.questions import (
    AnswerValue,
    DoubleQuestion,
    EnumQuestion,
    IntQuestion,
    Question,
    StrQuestion,
)

# Answers are stored in a BIGINT column.
INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1


@dataclass(frozen=True, slots=True)
class TypedAnswer:
    key: str
    type: str
    position: int
    value_int: int | None = None
    value_double: float | None = None
    value_str: str | None = None


def _check_int(q: IntQuestion, v: AnswerValue) -> tuple[int | None, str | None]:
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    if not isinstance(v, int) or isinstance(v, bool):
        return None, "must be an integer"
    if not INT64_MIN <= v <= INT64_MAX:
        return None, "out of range for a 64-bit integer"
    if q.min is not None and v < q.min:
        return None, f"must be >= {q.min}"
    if q.max is not None and v > q.max:
        return None, f"must be <= {q.max}"
    return v, None


def _check_double(q: DoubleQuestion, v: AnswerValue) -> tuple[float | None, str | None]:
    if isinstance(v, bool) or not isinstance(v, int | float):
        return None, "must be a number"
    f = float(v)
    if not math.isfinite(f):
        return None, "must be finite"
    if q.min is not None and f < q.min:
        return None, f"must be >= {q.min}"
    if q.max is not None and f > q.max:
        return None, f"must be <= {q.max}"
    return f, None


def _check_str(q: StrQuestion, v: str) -> str | None:
    if "\x00" in v:
        return "contains an invalid NUL character"
    if len(v) < q.min_length:
        return f"must be at least {q.min_length} characters"
    if len(v) > q.max_length:
        return f"must be at most {q.max_length} characters"
    return None


def validate_answers(
    questions: Sequence[Question],
    answers: Mapping[str, AnswerValue | None],
    *,
    allowed_archived: Mapping[str, str] | None = None,
) -> list[TypedAnswer]:
    """Return typed answers or raise InvalidAnswers with every problem found.

    ``allowed_archived`` maps question key -> an archived enum value that is
    permitted anyway (used when editing an entry that already holds it).
    """
    by_key = {q.key: q for q in questions}
    issues: list[FieldIssue] = []
    typed: list[TypedAnswer] = []

    for key in answers:
        if key not in by_key:
            issues.append(FieldIssue(loc=["answers", key], message="unknown question"))

    for pos, q in enumerate(questions):
        raw = answers.get(q.key)
        if isinstance(raw, str):
            raw = raw.strip()
            if raw == "":
                raw = None
        if raw is None:
            if q.required:
                issues.append(FieldIssue(loc=["answers", q.key], message="required"))
            continue

        err: str | None = None
        match q:
            case IntQuestion():
                iv, err = _check_int(q, raw)
                if iv is not None:
                    typed.append(TypedAnswer(q.key, "int", pos, value_int=iv))
            case DoubleQuestion():
                dv, err = _check_double(q, raw)
                if dv is not None:
                    typed.append(TypedAnswer(q.key, "double", pos, value_double=dv))
            case StrQuestion():
                if not isinstance(raw, str):
                    err = "must be a string"
                else:
                    err = _check_str(q, raw)
                    if err is None:
                        typed.append(TypedAnswer(q.key, "str", pos, value_str=raw))
            case EnumQuestion():
                if not isinstance(raw, str):
                    err = "must be one of the option values"
                elif raw not in q.all_values():
                    err = f"must be one of: {', '.join(sorted(q.active_values()))}"
                elif raw not in q.active_values() and (allowed_archived or {}).get(q.key) != raw:
                    err = "option is archived"
                else:
                    typed.append(TypedAnswer(q.key, "enum", pos, value_str=raw))
        if err is not None:
            issues.append(FieldIssue(loc=["answers", q.key], message=err))

    if issues:
        raise InvalidAnswers("one or more answers are invalid", issues)
    return typed
