"""Shared schema plumbing: the strict base model, the error envelope, and
field-precise validation errors.

Cross-field validators raise :func:`field_error`, which carries
``ctx={"field": "<dotted.path>"}``. :func:`error_loc` appends that path to the
error's location, so ``min > max`` on question 0 is reported at
``["questions", 0, "max"]`` rather than at the question as a whole. It also
drops the union discriminator tags pydantic inserts (``["questions", 0, "int",
"max"]`` -> ``["questions", 0, "max"]``), so locations always mirror the JSON
the client sent.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from pydantic_core import PydanticCustomError


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        str_strip_whitespace=True,
        # Output schemas mark defaulted fields required -> non-optional TS types.
        json_schema_serialization_defaults_required=True,
    )


class FieldIssue(StrictModel):
    loc: list[str | int]
    message: str


class Problem(StrictModel):
    """Error envelope for every 4xx response."""

    code: str = Field(examples=["not_found"])
    detail: str
    errors: list[FieldIssue] = []


def field_error(field: str, message: str, error_type: str = "constraint") -> PydanticCustomError:
    """A validation error located at ``field`` (dotted path, relative to the validated object).

    ``message`` is used verbatim (braces are escaped so it is never treated as a template).
    """
    template = message.replace("{", "{{").replace("}", "}}")
    return PydanticCustomError(error_type, template, {"field": field})


# Discriminator values pydantic inserts into locations of tagged unions.
_QUESTION_TAGS = frozenset({"int", "double", "str", "enum"})
_SCHEDULE_TAGS = frozenset({"daily", "interval"})


def _is_union_tag(prev: str | int | None, seg: str | int) -> bool:
    if not isinstance(seg, str):
        return False
    if isinstance(prev, int) and seg in _QUESTION_TAGS:  # questions[i].<type>
        return True
    return prev == "schedule" and seg in _SCHEDULE_TAGS


def _split_path(path: str) -> list[str | int]:
    return [int(p) if p.isdigit() else p for p in path.split(".") if p]


def error_loc(loc: Sequence[Any], ctx: Mapping[str, Any] | None = None) -> list[str | int]:
    """Client-facing location for one pydantic error (see module docstring)."""
    out: list[str | int] = []
    for seg in loc:
        if not isinstance(seg, str | int):
            continue
        if _is_union_tag(out[-1] if out else None, seg):
            continue
        out.append(seg)
    field = (ctx or {}).get("field")
    if isinstance(field, str):
        out.extend(_split_path(field))
    return out


def error_message(msg: str) -> str:
    return msg.removeprefix("Value error, ")


def issues_from(exc: ValidationError, prefix: Sequence[str | int] = ()) -> list[FieldIssue]:
    return [
        FieldIssue(loc=[*prefix, *error_loc(e["loc"], e.get("ctx"))], message=error_message(e["msg"]))
        for e in exc.errors()
    ]


def describe_issues(issues: Sequence[FieldIssue]) -> str:
    return "; ".join(f"{'.'.join(str(p) for p in i.loc)}: {i.message}" for i in issues)
