"""Validate raw answer maps against a topic version's question config."""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from app.errors import InvalidAnswers
from app.schemas.api import FieldIssue
from app.schemas.limits import INT64_MAX, INT64_MIN
from app.schemas.questions import (
    AnswerValue,
    DoubleQuestion,
    EnumQuestion,
    IntQuestion,
    Question,
    StrQuestion,
)


@dataclass(frozen=True, slots=True)
class TypedAnswer:
    key: str
    type: str
    position: int
    value_int: int | None = None
    value_double: float | None = None
    value_str: str | None = None
    value_list: tuple[str, ...] | None = None


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


def _check_option(q: EnumQuestion, v: str, held: frozenset[str]) -> str | None:
    if v not in q.all_values():
        return f"'{v}' is not an option; choose from: {', '.join(sorted(q.active_values()))}"
    if v not in q.active_values() and v not in held:
        return f"option '{v}' is archived"
    return None


def _check_single_enum(
    q: EnumQuestion, v: AnswerValue, held: frozenset[str]
) -> tuple[str | None, str | None]:
    if isinstance(v, list):
        return None, "must be a single option value (this question is not multi-select)"
    if not isinstance(v, str):
        return None, "must be one of the option values"
    if v not in q.all_values():
        return None, f"must be one of: {', '.join(sorted(q.active_values()))}"
    if v not in q.active_values() and v not in held:
        return None, "option is archived"
    return v, None


def _plural(n: int) -> str:
    return f"{n} option" + ("" if n == 1 else "s")


def _check_multi_enum(
    q: EnumQuestion, values: list[str], held: frozenset[str]
) -> tuple[tuple[str, ...] | None, list[tuple[list[str | int], str]]]:
    """Validate a non-empty selection. Returns (values in option order, [(sub-loc, message)])."""
    errs: list[tuple[list[str | int], str]] = []
    for i, v in enumerate(values):
        if v in values[:i]:
            errs.append(([i], f"'{v}' is selected more than once"))
            continue
        err = _check_option(q, v, held)
        if err is not None:
            errs.append(([i], err))
    if errs:
        return None, errs
    n = len(values)
    lo = max(1 if q.required else 0, q.min_selected or 0)
    if n < lo:
        errs.append(([], f"select at least {_plural(lo)}"))
    if q.max_selected is not None and n > q.max_selected:
        errs.append(([], f"select at most {_plural(q.max_selected)}"))
    if errs:
        return None, errs
    order = {o.value: i for i, o in enumerate(q.options)}
    return tuple(sorted(values, key=order.__getitem__)), []


def _normalise(raw: AnswerValue | None) -> AnswerValue | None:
    """Strip strings; blank strings and empty selections mean unanswered."""
    if isinstance(raw, str):
        return raw.strip() or None
    if isinstance(raw, list):
        return [v.strip() for v in raw] or None
    return raw


def _validate_one(
    q: Question, raw: AnswerValue, pos: int, held: frozenset[str]
) -> tuple[TypedAnswer | None, list[tuple[list[str | int], str]]]:
    """Typed answer for one non-empty value, or [(sub-loc, message)] problems."""
    match q:
        case IntQuestion():
            iv, err = _check_int(q, raw)
            if iv is not None:
                return TypedAnswer(q.key, "int", pos, value_int=iv), []
        case DoubleQuestion():
            dv, err = _check_double(q, raw)
            if dv is not None:
                return TypedAnswer(q.key, "double", pos, value_double=dv), []
        case StrQuestion():
            if not isinstance(raw, str):
                err = "must be a string"
            else:
                err = _check_str(q, raw)
                if err is None:
                    return TypedAnswer(q.key, "str", pos, value_str=raw), []
        case EnumQuestion() if q.multiple:
            if not isinstance(raw, list):
                err = "must be a list of option values (this question is multi-select)"
            else:
                lv, sub = _check_multi_enum(q, raw, held)
                if lv is not None:
                    return TypedAnswer(q.key, "enum", pos, value_list=lv), []
                return None, sub
        case EnumQuestion():
            sv, err = _check_single_enum(q, raw, held)
            if sv is not None:
                return TypedAnswer(q.key, "enum", pos, value_str=sv), []
    return None, [([], err or "invalid value")]


def validate_answers(
    questions: Sequence[Question],
    answers: Mapping[str, AnswerValue | None],
    *,
    allowed_archived: Mapping[str, frozenset[str]] | None = None,
) -> list[TypedAnswer]:
    """Return typed answers or raise InvalidAnswers with every problem found.

    ``allowed_archived`` maps question key -> archived enum values that are
    permitted anyway (used when editing an entry that already holds them).
    """
    by_key = {q.key: q for q in questions}
    allowed = allowed_archived or {}
    issues = [FieldIssue(loc=["answers", k], message="unknown question") for k in answers if k not in by_key]
    typed: list[TypedAnswer] = []

    for pos, q in enumerate(questions):
        raw = _normalise(answers.get(q.key))
        if raw is None:
            if q.required:
                issues.append(FieldIssue(loc=["answers", q.key], message="required"))
            continue
        answer, problems = _validate_one(q, raw, pos, allowed.get(q.key, frozenset()))
        if answer is not None:
            typed.append(answer)
        issues.extend(FieldIssue(loc=["answers", q.key, *loc], message=m) for loc, m in problems)

    if issues:
        raise InvalidAnswers("one or more answers are invalid", issues)
    return typed
