"""Question config validation (pure, no DB): every constraint, with its exact location."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import TypeAdapter, ValidationError

from app.schemas.base import issues_from
from app.schemas.questions import (
    DoubleQuestion,
    EnumQuestion,
    IntQuestion,
    Question,
    QuestionSet,
    StrQuestion,
)
from app.services.topics import parse_questions

question_adapter: TypeAdapter[Question] = TypeAdapter(Question)


def q(**kw: Any) -> Question:
    return question_adapter.validate_python({"key": "k", "label": "K", **kw})


def opts(*values: str, archived: tuple[str, ...] = ()) -> list[dict[str, Any]]:
    return [{"value": v, "label": v.title(), "archived": v in archived} for v in values]


def problems(payload: dict[str, Any]) -> list[tuple[list[str | int], str]]:
    """(loc, message) of every error for a one-question set, as clients see them."""
    with pytest.raises(ValidationError) as exc:
        QuestionSet.model_validate({"questions": [{"key": "k", "label": "K", **payload}]})
    return [(i.loc, i.message) for i in issues_from(exc.value)]


def problem(payload: dict[str, Any]) -> tuple[list[str | int], str]:
    found = problems(payload)
    assert len(found) == 1, found
    return found[0]


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
    e = q(type="enum", options=opts("a"))
    assert isinstance(e, EnumQuestion)
    assert (e.multiple, e.min_selected, e.max_selected) == (False, None, None)


# --- question base -----------------------------------------------------------


@pytest.mark.parametrize("key", ["Hours", "1abc", "_x", "has-dash", "has space", "", "a" * 64, "ümlaut"])
def test_key_pattern_rejects(key: str) -> None:
    loc, msg = problem({"key": key, "type": "int"})
    assert loc == ["questions", 0, "key"]
    assert msg.startswith("must start with a lowercase letter")


@pytest.mark.parametrize("key", ["a", "hours_slept", "x1_2", "a" * 63])
def test_key_pattern_accepts(key: str) -> None:
    assert question_adapter.validate_python({"key": key, "label": "x", "type": "int"}).key == key


def test_label_required_and_bounded() -> None:
    assert problem({"type": "int", "label": ""})[0] == ["questions", 0, "label"]
    assert problem({"type": "int", "label": "   "})[0] == ["questions", 0, "label"]  # stripped first
    assert problem({"type": "int", "label": "x" * 201})[0] == ["questions", 0, "label"]


def test_help_and_unit_length() -> None:
    assert problem({"type": "int", "help_text": "x" * 1001})[0] == ["questions", 0, "help_text"]
    assert problem({"type": "int", "unit": "x" * 33})[0] == ["questions", 0, "unit"]
    assert problem({"type": "double", "unit": "x" * 33})[0] == ["questions", 0, "unit"]


def test_extra_fields_forbidden() -> None:
    assert problem({"type": "int", "bogus": 1})[0] == ["questions", 0, "bogus"]
    # An attribute belonging to another type.
    assert problem({"type": "int", "max_length": 3})[0] == ["questions", 0, "max_length"]


def test_required_is_strict_bool() -> None:
    assert q(type="int", required=False).required is False


# --- int / double --------------------------------------------------------------


@pytest.mark.parametrize("type_", ["int", "double"])
def test_numeric_min_greater_than_max(type_: str) -> None:
    assert problem({"type": type_, "min": 5, "max": 1}) == (
        ["questions", 0, "max"],
        "max must be greater than or equal to min",
    )
    assert q(type=type_, min=3, max=3).min == 3  # type: ignore[union-attr]


def test_int_bounds_within_int64() -> None:
    assert problem({"type": "int", "min": -(2**63) - 1}) == (
        ["questions", 0, "min"],
        "must fit in a signed 64-bit integer",
    )
    assert problem({"type": "int", "max": 2**63})[0] == ["questions", 0, "max"]
    assert q(type="int", min=-(2**63), max=2**63 - 1).max == 2**63 - 1  # type: ignore[union-attr]


def test_int_bounds_strict() -> None:
    assert problem({"type": "int", "min": 1.5})[0] == ["questions", 0, "min"]
    assert problem({"type": "int", "min": "1"})[0] == ["questions", 0, "min"]
    assert problem({"type": "int", "max": True})[0] == ["questions", 0, "max"]


def test_double_accepts_int_and_float_bounds() -> None:
    d = q(type="double", min=0, max=1.5)
    assert isinstance(d, DoubleQuestion)
    assert (d.min, d.max) == (0, 1.5)


def test_double_bounds_must_be_finite() -> None:
    assert problem({"type": "double", "max": float("inf")}) == (
        ["questions", 0, "max"],
        "must be a finite number",
    )
    assert problem({"type": "double", "min": float("nan")}) == (
        ["questions", 0, "min"],
        "must be a finite number",
    )


def test_double_decimals_range() -> None:
    assert q(type="double", decimals=2).decimals == 2  # type: ignore[union-attr]
    assert problem({"type": "double", "decimals": 11})[0] == ["questions", 0, "decimals"]
    assert problem({"type": "double", "decimals": -1})[0] == ["questions", 0, "decimals"]


# --- str -------------------------------------------------------------------------


def test_str_length_rules() -> None:
    assert problem({"type": "str", "min_length": 10, "max_length": 5}) == (
        ["questions", 0, "max_length"],
        "max_length must be greater than or equal to min_length",
    )
    assert problem({"type": "str", "max_length": 0})[0] == ["questions", 0, "max_length"]
    assert problem({"type": "str", "max_length": 10_001})[0] == ["questions", 0, "max_length"]
    assert problem({"type": "str", "min_length": -1})[0] == ["questions", 0, "min_length"]
    assert problem({"type": "str", "min_length": 10_001, "max_length": 10_000})[0] == [
        "questions",
        0,
        "min_length",
    ]
    assert q(type="str", min_length=10_000, max_length=10_000).max_length == 10_000  # type: ignore[union-attr]


# --- enum ------------------------------------------------------------------------


def test_enum_options_required() -> None:
    assert problem({"type": "enum", "options": []})[0] == ["questions", 0, "options"]
    many = [{"value": f"o{i}", "label": f"O{i}"} for i in range(201)]
    assert problem({"type": "enum", "options": many})[0] == ["questions", 0, "options"]


def test_enum_option_value_pattern() -> None:
    loc, msg = problem({"type": "enum", "options": [{"value": "Not Valid", "label": "x"}]})
    assert loc == ["questions", 0, "options", 0, "value"]
    assert msg.startswith("must start with a lowercase letter")


def test_enum_unique_values() -> None:
    assert problem({"type": "enum", "options": opts("a", "b", "a")}) == (
        ["questions", 0, "options", 2, "value"],
        "duplicate option value 'a'",
    )


def test_enum_unique_labels_case_insensitive() -> None:
    options = [{"value": "a", "label": "Good"}, {"value": "b", "label": "GOOD"}]
    assert problem({"type": "enum", "options": options}) == (
        ["questions", 0, "options", 1, "label"],
        "duplicate option label 'GOOD'",
    )


def test_enum_needs_an_active_option() -> None:
    assert problem({"type": "enum", "options": opts("a", "b", archived=("a", "b"))}) == (
        ["questions", 0, "options"],
        "at least one option must be active (not archived)",
    )
    e = q(type="enum", options=opts("a", "b", archived=("b",)))
    assert isinstance(e, EnumQuestion)
    assert e.active_values() == {"a"}
    assert e.all_values() == {"a", "b"}


@pytest.mark.parametrize("field", ["min_selected", "max_selected"])
def test_enum_selection_limits_need_multiple(field: str) -> None:
    assert problem({"type": "enum", "options": opts("a", "b"), field: 1}) == (
        ["questions", 0, field],
        f"{field} is only allowed when multiple is true",
    )


def test_enum_selection_limits() -> None:
    base = {"type": "enum", "options": opts("a", "b", "c", archived=("c",)), "multiple": True}
    ok = q(**{**base, "min_selected": 1, "max_selected": 2})
    assert isinstance(ok, EnumQuestion)
    assert (ok.multiple, ok.min_selected, ok.max_selected) == (True, 1, 2)
    assert problem({**base, "min_selected": 2, "max_selected": 1}) == (
        ["questions", 0, "max_selected"],
        "max_selected must be greater than or equal to min_selected",
    )
    # Only active options count.
    assert problem({**base, "max_selected": 3}) == (
        ["questions", 0, "max_selected"],
        "max_selected cannot exceed the number of active options (2)",
    )
    assert problem({**base, "min_selected": 3})[0] == ["questions", 0, "min_selected"]
    assert problem({**base, "min_selected": 0})[0] == ["questions", 0, "min_selected"]
    assert problem({**base, "max_selected": 0})[0] == ["questions", 0, "max_selected"]


# --- question set ------------------------------------------------------------------


def test_question_set_unique_keys() -> None:
    with pytest.raises(ValidationError) as exc:
        QuestionSet.model_validate(
            {
                "questions": [
                    {"key": "a", "label": "A", "type": "int"},
                    {"key": "b", "label": "B", "type": "int"},
                    {"key": "a", "label": "C", "type": "str"},
                ]
            }
        )
    assert [(i.loc, i.message) for i in issues_from(exc.value)] == [
        (["questions", 2, "key"], "duplicate question key 'a'")
    ]


def test_question_set_unique_labels_case_insensitive() -> None:
    with pytest.raises(ValidationError) as exc:
        QuestionSet.model_validate(
            {
                "questions": [
                    {"key": "a", "label": "Mood", "type": "int"},
                    {"key": "b", "label": "mood", "type": "int"},
                ]
            }
        )
    assert [(i.loc, i.message) for i in issues_from(exc.value)] == [
        (["questions", 1, "label"], "duplicate question label 'mood'")
    ]


def test_question_set_bounds() -> None:
    with pytest.raises(ValidationError):
        QuestionSet.model_validate({"questions": []})
    many = [{"key": f"q{i}", "label": f"Q{i}", "type": "int"} for i in range(101)]
    with pytest.raises(ValidationError):
        QuestionSet.model_validate({"questions": many})
    assert len(QuestionSet.model_validate({"questions": many[:100]}).questions) == 100


def test_stored_configs_skip_newer_checks() -> None:
    """Versions stored before label uniqueness / int64 checks existed still parse."""
    stored: list[dict[str, Any]] = [
        {"type": "int", "key": "a", "label": "Same", "max": 2**64},
        {
            "type": "enum",
            "key": "b",
            "label": "same",
            "options": [*opts("x", "y"), {"value": "z", "label": "X"}],
        },
    ]
    parsed = parse_questions(stored)
    assert [p.key for p in parsed] == ["a", "b"]
    # Core invariants are still enforced.
    with pytest.raises(ValidationError):
        parse_questions([{"type": "int", "key": "a", "label": "A", "min": 2, "max": 1}])
