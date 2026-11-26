"""Question configuration: the typed, config-driven heart of a topic.

Each question is a discriminated union on ``type``. Constraint validation
(min <= max, unique enum values, ...) happens here so the API, MCP server and
UI builder all share one source of truth. Every cross-field error is raised
with :func:`field_error`, so it is reported at the most specific field.

Stored versions are re-parsed with ``context={"stored": True}``: checks added
after data may already exist (label uniqueness, 64-bit bounds) are skipped
there, so historic configs always stay readable.
"""

from __future__ import annotations

import math
import re
from collections.abc import Sequence
from typing import Annotated, Any, Literal, Self

from pydantic import (
    AfterValidator,
    Field,
    StrictBool,
    StrictFloat,
    StrictInt,
    StrictStr,
    ValidationError,
    ValidationInfo,
    ValidatorFunctionWrapHandler,
    WrapValidator,
    model_validator,
)
from pydantic_core import PydanticCustomError

from app.schemas.base import StrictModel, field_error
from app.schemas.limits import (
    INT64_MAX,
    INT64_MIN,
    KEY_PATTERN,
    MAX_ALERTS,
    MAX_DECIMALS,
    MAX_ENUM_OPTIONS,
    MAX_EXPR_LENGTH,
    MAX_HELP_TEXT_LENGTH,
    MAX_LABEL_LENGTH,
    MAX_LAP_TYPES,
    MAX_QUESTIONS,
    MAX_SHORT_LABEL_LENGTH,
    MAX_STEPS,
    MAX_STR_LENGTH,
    MAX_UNIT_LENGTH,
    MAX_VAR_NAME_LENGTH,
    MAX_VARIABLE_MS,
    MAX_VARIABLES,
    RESERVED_VAR_NAMES,
    VAR_NAME_PATTERN,
)
from app.services import timer_expr

__all__ = ["KEY_PATTERN", "MAX_ENUM_OPTIONS", "MAX_QUESTIONS", "MAX_STR_LENGTH", "StrictModel"]

KEY_RE = re.compile(KEY_PATTERN)


def _check_key(v: str) -> str:
    if not KEY_RE.fullmatch(v):
        raise PydanticCustomError(
            "key_format",
            "must start with a lowercase letter and contain only lowercase letters, digits and "
            "underscores (at most 63 characters)",
        )
    return v


QuestionKey = Annotated[
    str,
    AfterValidator(_check_key),
    Field(
        json_schema_extra={"pattern": KEY_PATTERN},
        description="Stable machine key (lower snake_case); the identity of a question across versions.",
        examples=["hours_slept"],
    ),
]
Label = Annotated[str, Field(min_length=1, max_length=MAX_LABEL_LENGTH)]
HelpText = Annotated[str | None, Field(default=None, max_length=MAX_HELP_TEXT_LENGTH)]
Unit = Annotated[str | None, Field(default=None, max_length=MAX_UNIT_LENGTH)]


def _stored(info: ValidationInfo) -> bool:
    return isinstance(info.context, dict) and bool(info.context.get("stored"))


def _duplicate_indices(items: Sequence[str]) -> list[int]:
    """Indices of items equal to an earlier item."""
    seen: set[str] = set()
    out: list[int] = []
    for i, item in enumerate(items):
        if item in seen:
            out.append(i)
        seen.add(item)
    return out


class QuestionBase(StrictModel):
    key: QuestionKey
    label: Label
    help_text: HelpText = None
    required: StrictBool = True


class IntQuestion(QuestionBase):
    type: Literal["int"] = "int"
    min: StrictInt | None = Field(default=None, description="Inclusive lower bound.")
    max: StrictInt | None = Field(default=None, description="Inclusive upper bound.")
    unit: Unit = None

    @model_validator(mode="after")
    def _check_range(self, info: ValidationInfo) -> Self:
        if not _stored(info):
            for name in ("min", "max"):
                bound = getattr(self, name)
                if bound is not None and not INT64_MIN <= bound <= INT64_MAX:
                    raise field_error(name, "must fit in a signed 64-bit integer")
        if self.min is not None and self.max is not None and self.min > self.max:
            raise field_error("max", "max must be greater than or equal to min")
        return self


class DoubleQuestion(QuestionBase):
    type: Literal["double"] = "double"
    min: StrictFloat | StrictInt | None = Field(default=None, description="Inclusive lower bound.")
    max: StrictFloat | StrictInt | None = Field(default=None, description="Inclusive upper bound.")
    decimals: Annotated[
        StrictInt | None,
        Field(default=None, ge=0, le=MAX_DECIMALS, description="Display/input precision hint."),
    ] = None
    unit: Unit = None

    @model_validator(mode="after")
    def _check_range(self) -> Self:
        for name in ("min", "max"):
            bound = getattr(self, name)
            if bound is not None and not math.isfinite(bound):
                raise field_error(name, "must be a finite number")
        if self.min is not None and self.max is not None and self.min > self.max:
            raise field_error("max", "max must be greater than or equal to min")
        return self


class StrQuestion(QuestionBase):
    type: Literal["str"] = "str"
    min_length: Annotated[StrictInt, Field(ge=0, le=MAX_STR_LENGTH)] = 0
    max_length: Annotated[StrictInt, Field(ge=1, le=MAX_STR_LENGTH)] = 500
    multiline: StrictBool = False

    @model_validator(mode="after")
    def _check_lengths(self) -> Self:
        if self.min_length > self.max_length:
            raise field_error("max_length", "max_length must be greater than or equal to min_length")
        return self


class EnumOption(StrictModel):
    value: QuestionKey
    label: Label
    archived: StrictBool = Field(
        default=False,
        description="Archived options remain valid for historic data but are hidden from new entries.",
    )


class EnumQuestion(QuestionBase):
    type: Literal["enum"] = "enum"
    options: Annotated[list[EnumOption], Field(min_length=1, max_length=MAX_ENUM_OPTIONS)]
    multiple: StrictBool = Field(
        default=False,
        description="Allow selecting several options; the answer is then a list of option values.",
    )
    min_selected: StrictInt | None = Field(
        default=None, ge=1, description="Multi-select only: fewest options an answer may select."
    )
    max_selected: StrictInt | None = Field(
        default=None, ge=1, description="Multi-select only: most options an answer may select."
    )

    @model_validator(mode="after")
    def _check_options(self, info: ValidationInfo) -> Self:
        values = [o.value for o in self.options]
        for i in _duplicate_indices(values):
            raise field_error(f"options.{i}.value", f"duplicate option value '{values[i]}'")
        if not _stored(info):
            labels = [o.label.casefold() for o in self.options]
            for i in _duplicate_indices(labels):
                raise field_error(f"options.{i}.label", f"duplicate option label '{self.options[i].label}'")
        active = len(self.active_values())
        if active == 0:
            raise field_error("options", "at least one option must be active (not archived)")
        if not self.multiple:
            for name in ("min_selected", "max_selected"):
                if getattr(self, name) is not None:
                    raise field_error(name, f"{name} is only allowed when multiple is true")
            return self
        if self.min_selected is not None and self.min_selected > active:
            raise field_error(
                "min_selected", f"min_selected cannot exceed the number of active options ({active})"
            )
        if self.max_selected is not None and self.max_selected > active:
            raise field_error(
                "max_selected", f"max_selected cannot exceed the number of active options ({active})"
            )
        if (
            self.min_selected is not None
            and self.max_selected is not None
            and self.min_selected > self.max_selected
        ):
            raise field_error("max_selected", "max_selected must be greater than or equal to min_selected")
        return self

    def active_values(self) -> set[str]:
        return {o.value for o in self.options if not o.archived}

    def all_values(self) -> set[str]:
        return {o.value for o in self.options}


Question = Annotated[
    IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion,
    Field(discriminator="type"),
]
QuestionType = Literal["int", "double", "str", "enum"]


def _check_question_list(questions: list[Any]) -> list[Any]:
    keys = [q.key for q in questions]
    for i in _duplicate_indices(keys):
        raise field_error(f"{i}.key", f"duplicate question key '{keys[i]}'")
    labels = [q.label.casefold() for q in questions]
    for i in _duplicate_indices(labels):
        raise field_error(f"{i}.label", f"duplicate question label '{questions[i].label}'")
    return questions


QuestionList = Annotated[
    list[Question],
    Field(min_length=0, max_length=MAX_QUESTIONS),
    AfterValidator(_check_question_list),
]


class QuestionSet(StrictModel):
    """An ordered list of questions with cross-question invariants."""

    questions: QuestionList


ShortLabel = Annotated[str, Field(min_length=1, max_length=MAX_SHORT_LABEL_LENGTH)]
Expr = Annotated[
    str,
    Field(
        min_length=1,
        max_length=MAX_EXPR_LENGTH,
        description="An alert time over the timer's variables (timers2.md §2): `t/2`, `t+30s`, `1.5m`.",
        examples=["t/2"],
    ),
]

_VAR_NAME_INPUT_RE = re.compile(VAR_NAME_PATTERN.replace("a-z", "A-Za-z"))


def _check_var_name(v: str) -> str:
    if not _VAR_NAME_INPUT_RE.fullmatch(v):
        raise PydanticCustomError(
            "var_name_format",
            "must start with a letter and contain only letters, digits and underscores "
            f"(at most {MAX_VAR_NAME_LENGTH} characters)",
        )
    name = v.lower()
    if name in RESERVED_VAR_NAMES:
        raise PydanticCustomError(
            "var_name_reserved",
            "'{name}' is a unit (ms, s, m, h) and can't be a variable name",
            {"name": name},
        )
    return name


VarName = Annotated[
    str,
    AfterValidator(_check_var_name),
    Field(
        json_schema_extra={"pattern": _VAR_NAME_INPUT_RE.pattern},
        description="Case-insensitive on input, stored and returned lowercase; not a unit (ms, s, m, h).",
        examples=["t"],
    ),
]


class Variable(StrictModel):
    """A named duration that alert expressions refer to (``t``, ``rest``)."""

    name: VarName
    ms: Annotated[StrictInt, Field(ge=0, le=MAX_VARIABLE_MS)]


class Alert(StrictModel):
    """A cue that fires when its segment's active time reaches ``at_ms``."""

    key: QuestionKey
    label: ShortLabel
    at: Expr
    at_ms: StrictInt = Field(
        default=0,
        description="Output only: ``at`` evaluated over the timer's variables, in ms. A sent value "
        "is ignored.",
    )

    @model_validator(mode="before")
    @classmethod
    def _ignore_sent_at_ms(cls, data: Any) -> Any:
        if isinstance(data, dict) and "at_ms" in data:
            return {k: v for k, v in data.items() if k != "at_ms"}
        return data


Alerts = Annotated[list[Alert], Field(max_length=MAX_ALERTS, default_factory=list)]


class Step(StrictModel):
    """A named checkpoint of a timed topic. Its key is its identity across versions, in a
    namespace of its own (a step and a question may share a key) that it shares with the
    timer's lap types."""

    key: QuestionKey
    label: Label
    alerts: Alerts


class LapType(StrictModel):
    """A kind of lap: laps cycle through the timer's lap types in order (one renames laps, two
    or more alternate). Its key is its identity across versions, as a step's is."""

    key: QuestionKey
    label: ShortLabel
    alerts: Alerts


class Timer(StrictModel):
    """A version's timing: its steps, timed in this order (no steps makes a plain stopwatch),
    its lap types, and the variables its alerts refer to (timers2.md §1).

    Output is normalised: every list is present and each alert's ``at_ms`` is filled. The v1
    shape ``{steps: [{key, label}]}`` is accepted, stored ones included."""

    steps: Annotated[list[Step], Field(max_length=MAX_STEPS)]
    laps: Annotated[
        list[LapType],
        Field(max_length=MAX_LAP_TYPES, default_factory=list, description="None: laps are untyped."),
    ]
    variables: Annotated[list[Variable], Field(max_length=MAX_VARIABLES, default_factory=list)]

    @model_validator(mode="after")
    def _check(self) -> Self:
        step_keys = [s.key for s in self.steps]
        for i in _duplicate_indices(step_keys):
            raise field_error(f"steps.{i}.key", f"duplicate step key '{step_keys[i]}'")
        seen: set[str] = set()
        for i, lap in enumerate(self.laps):
            if lap.key in step_keys:
                raise field_error(f"laps.{i}.key", f"duplicate key '{lap.key}' (also a step)")
            if lap.key in seen:
                raise field_error(f"laps.{i}.key", f"duplicate lap type key '{lap.key}'")
            seen.add(lap.key)
        names = [v.name for v in self.variables]
        for i in _duplicate_indices(names):
            raise field_error(f"variables.{i}.name", f"duplicate variable name '{names[i]}'")
        owners: list[tuple[str, Sequence[Step | LapType]]] = [("steps", self.steps), ("laps", self.laps)]
        for path, items in owners:
            for i, owner in enumerate(items):
                keys = [a.key for a in owner.alerts]
                for j in _duplicate_indices(keys):
                    raise field_error(f"{path}.{i}.alerts.{j}.key", f"duplicate alert key '{keys[j]}'")
        variables = dict(zip(names, (v.ms for v in self.variables), strict=True))
        for path, items in owners:
            for i, owner in enumerate(items):
                for j, alert in enumerate(owner.alerts):
                    try:
                        alert.at_ms = timer_expr.evaluate(alert.at, variables)
                    except timer_expr.ExprError as exc:
                        raise field_error(f"{path}.{i}.alerts.{j}.at", str(exc)) from None
        return self


def _single_answer_error(v: object, handler: ValidatorFunctionWrapHandler) -> object:
    # One readable error instead of one per union member.
    try:
        return handler(v)
    except ValidationError:
        raise PydanticCustomError(
            "answer_type", "must be a number, a string, or a list of strings (multi-select)"
        ) from None


# Raw answer value as accepted from clients. Strict types: no "5" -> 5 coercion,
# and booleans are never accepted as ints. Lists answer multi-select enums.
AnswerValue = Annotated[
    StrictInt | StrictFloat | StrictStr | list[StrictStr],
    WrapValidator(_single_answer_error),
]
