"""Question configuration: the typed, config-driven heart of a topic.

Each question is a discriminated union on ``type``. Constraint validation
(min <= max, unique enum values, ...) happens here so the API, MCP server and
UI builder all share one source of truth.
"""

from __future__ import annotations

import math
import re
from typing import Annotated, Literal, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictFloat,
    StrictInt,
    StrictStr,
    model_validator,
)

KEY_PATTERN = r"^[a-z][a-z0-9_]{0,62}$"
KEY_RE = re.compile(KEY_PATTERN)

# Hard ceilings so a config can never request something unreasonable.
MAX_STR_LENGTH = 10_000
MAX_QUESTIONS = 100
MAX_ENUM_OPTIONS = 200

QuestionKey = Annotated[
    str,
    Field(
        pattern=KEY_PATTERN,
        description="Stable machine key (lower snake_case); the identity of a question across versions.",
        examples=["hours_slept"],
    ),
]
Label = Annotated[str, Field(min_length=1, max_length=200)]
HelpText = Annotated[str | None, Field(default=None, max_length=1000)]


class StrictModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        str_strip_whitespace=True,
        # Output schemas mark defaulted fields required -> non-optional TS types.
        json_schema_serialization_defaults_required=True,
    )


class QuestionBase(StrictModel):
    key: QuestionKey
    label: Label
    help_text: HelpText = None
    required: bool = True


class IntQuestion(QuestionBase):
    type: Literal["int"] = "int"
    min: StrictInt | None = Field(default=None, description="Inclusive lower bound.")
    max: StrictInt | None = Field(default=None, description="Inclusive upper bound.")
    unit: Annotated[str | None, Field(default=None, max_length=32)] = None

    @model_validator(mode="after")
    def _check_range(self) -> Self:
        if self.min is not None and self.max is not None and self.min > self.max:
            raise ValueError("min must be <= max")
        return self


class DoubleQuestion(QuestionBase):
    type: Literal["double"] = "double"
    min: StrictFloat | StrictInt | None = Field(default=None, description="Inclusive lower bound.")
    max: StrictFloat | StrictInt | None = Field(default=None, description="Inclusive upper bound.")
    decimals: Annotated[
        int | None,
        Field(default=None, ge=0, le=10, description="Display/input precision hint."),
    ] = None
    unit: Annotated[str | None, Field(default=None, max_length=32)] = None

    @model_validator(mode="after")
    def _check_range(self) -> Self:
        for bound in (self.min, self.max):
            if bound is not None and not math.isfinite(bound):
                raise ValueError("bounds must be finite")
        if self.min is not None and self.max is not None and self.min > self.max:
            raise ValueError("min must be <= max")
        return self


class StrQuestion(QuestionBase):
    type: Literal["str"] = "str"
    min_length: Annotated[int, Field(ge=0, le=MAX_STR_LENGTH)] = 0
    max_length: Annotated[int, Field(ge=1, le=MAX_STR_LENGTH)] = 500
    multiline: bool = False

    @model_validator(mode="after")
    def _check_lengths(self) -> Self:
        if self.min_length > self.max_length:
            raise ValueError("min_length must be <= max_length")
        return self


class EnumOption(StrictModel):
    value: QuestionKey
    label: Label
    archived: bool = Field(
        default=False,
        description="Archived options remain valid for historic data but are hidden from new entries.",
    )


class EnumQuestion(QuestionBase):
    type: Literal["enum"] = "enum"
    options: Annotated[list[EnumOption], Field(min_length=1, max_length=MAX_ENUM_OPTIONS)]

    @model_validator(mode="after")
    def _check_options(self) -> Self:
        values = [o.value for o in self.options]
        if len(values) != len(set(values)):
            raise ValueError("enum option values must be unique")
        if all(o.archived for o in self.options):
            raise ValueError("at least one enum option must be active")
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


class QuestionSet(StrictModel):
    """An ordered list of questions with cross-question invariants."""

    questions: Annotated[list[Question], Field(min_length=1, max_length=MAX_QUESTIONS)]

    @model_validator(mode="after")
    def _unique(self) -> Self:
        keys = [q.key for q in self.questions]
        if len(keys) != len(set(keys)):
            raise ValueError("question keys must be unique")
        return self


# Raw answer value as accepted from clients. Strict types: no "5" -> 5 coercion,
# and booleans are never accepted as ints.
AnswerValue = StrictInt | StrictFloat | StrictStr
