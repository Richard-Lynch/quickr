"""Question config validation (pure, no DB)."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import TypeAdapter, ValidationError

from app.schemas.questions import (
    DoubleQuestion,
    EnumQuestion,
    IntQuestion,
    Question,
    QuestionSet,
    StrQuestion,
)

question_adapter: TypeAdapter[Question] = TypeAdapter(Question)


def q(**kw: Any) -> Question:
    return question_adapter.validate_python({"key": "k", "label": "K", **kw})


def opts(*values: str, archived: tuple[str, ...] = ()) -> list[dict[str, Any]]:
    return [{"value": v, "label": v.title(), "archived": v in archived} for v in values]


def test_discriminates_on_type() -> None:
    assert isinstance(q(type="int"), IntQuestion)
    assert isinstance(q(type="double"), DoubleQuestion)
    assert isinstance(q(type="str"), StrQuestion)
    assert isinstance(q(type="enum", options=opts("a")), EnumQuestion)
    with pytest.raises(ValidationError):
        q(type="bool")


def test_defaults() -> None:
    s = q(type="str")
    assert isinstance(s, StrQuestion)
    assert (s.required, s.min_length, s.max_length, s.multiline, s.help_text) == (True, 0, 500, False, None)


@pytest.mark.parametrize("type_", ["int", "double"])
def test_numeric_min_greater_than_max_rejected(type_: str) -> None:
    with pytest.raises(ValidationError, match="min must be <= max"):
        q(type=type_, min=5, max=1)
    # Equal bounds are fine.
    assert q(type=type_, min=3, max=3).min == 3  # type: ignore[union-attr]


def test_double_accepts_int_and_float_bounds() -> None:
    d = q(type="double", min=0, max=1.5)
    assert isinstance(d, DoubleQuestion)
    assert (d.min, d.max) == (0, 1.5)


def test_double_bounds_must_be_finite() -> None:
    with pytest.raises(ValidationError):
        q(type="double", max=float("inf"))
    with pytest.raises(ValidationError):
        q(type="double", min=float("nan"))


def test_int_bounds_strict() -> None:
    with pytest.raises(ValidationError):
        q(type="int", min=1.5)
    with pytest.raises(ValidationError):
        q(type="int", min="1")
    with pytest.raises(ValidationError):
        q(type="int", max=True)


def test_double_decimals_range() -> None:
    assert q(type="double", decimals=2).decimals == 2  # type: ignore[union-attr]
    with pytest.raises(ValidationError):
        q(type="double", decimals=11)
    with pytest.raises(ValidationError):
        q(type="double", decimals=-1)


def test_str_length_rules() -> None:
    with pytest.raises(ValidationError, match="min_length must be <= max_length"):
        q(type="str", min_length=10, max_length=5)
    with pytest.raises(ValidationError):
        q(type="str", max_length=0)
    with pytest.raises(ValidationError):
        q(type="str", max_length=10_001)


def test_enum_rules() -> None:
    with pytest.raises(ValidationError, match="unique"):
        q(type="enum", options=opts("a", "a"))
    with pytest.raises(ValidationError, match="at least one enum option must be active"):
        q(type="enum", options=opts("a", "b", archived=("a", "b")))
    with pytest.raises(ValidationError):
        q(type="enum", options=[])
    with pytest.raises(ValidationError):  # option values follow the key pattern
        q(type="enum", options=[{"value": "Not Valid", "label": "x"}])
    e = q(type="enum", options=opts("a", "b", archived=("b",)))
    assert isinstance(e, EnumQuestion)
    assert e.active_values() == {"a"}
    assert e.all_values() == {"a", "b"}


@pytest.mark.parametrize("key", ["Hours", "1abc", "_x", "has-dash", "has space", "", "a" * 64, "ümlaut"])
def test_key_pattern_rejects(key: str) -> None:
    with pytest.raises(ValidationError):
        question_adapter.validate_python({"key": key, "label": "x", "type": "int"})


@pytest.mark.parametrize("key", ["a", "hours_slept", "x1_2", "a" * 63])
def test_key_pattern_accepts(key: str) -> None:
    assert question_adapter.validate_python({"key": key, "label": "x", "type": "int"}).key == key


def test_label_required_and_bounded() -> None:
    with pytest.raises(ValidationError):
        question_adapter.validate_python({"key": "k", "label": "", "type": "int"})
    with pytest.raises(ValidationError):  # whitespace is stripped first
        question_adapter.validate_python({"key": "k", "label": "   ", "type": "int"})
    with pytest.raises(ValidationError):
        question_adapter.validate_python({"key": "k", "label": "x" * 201, "type": "int"})


def test_extra_fields_forbidden() -> None:
    with pytest.raises(ValidationError):
        q(type="int", bogus=1)
    with pytest.raises(ValidationError):  # attribute belonging to another type
        q(type="int", max_length=3)


def test_required_is_strict_bool() -> None:
    assert q(type="int", required=False).required is False


def test_question_set_unique_keys() -> None:
    with pytest.raises(ValidationError, match="question keys must be unique"):
        QuestionSet.model_validate(
            {
                "questions": [
                    {"key": "a", "label": "A", "type": "int"},
                    {"key": "a", "label": "B", "type": "str"},
                ]
            }
        )


def test_question_set_bounds() -> None:
    with pytest.raises(ValidationError):
        QuestionSet.model_validate({"questions": []})
    many = [{"key": f"q{i}", "label": "x", "type": "int"} for i in range(101)]
    with pytest.raises(ValidationError):
        QuestionSet.model_validate({"questions": many})
    assert len(QuestionSet.model_validate({"questions": many[:100]}).questions) == 100
