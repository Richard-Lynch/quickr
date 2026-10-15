"""validate_answers (pure, no DB)."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import TypeAdapter

from app.errors import InvalidAnswers
from app.schemas.api import AnswerMap
from app.schemas.questions import AnswerValue, Question
from app.services.answers import TypedAnswer, validate_answers

questions_adapter: TypeAdapter[list[Question]] = TypeAdapter(list[Question])
answer_map_adapter: TypeAdapter[dict[str, AnswerValue | None]] = TypeAdapter(AnswerMap)

QUESTIONS = questions_adapter.validate_python(
    [
        {"key": "count", "label": "Count", "type": "int", "min": 0, "max": 10},
        {"key": "weight", "label": "Weight", "type": "double", "min": 0.5, "max": 2.5},
        {"key": "note", "label": "Note", "type": "str", "min_length": 2, "max_length": 5},
        {
            "key": "mood",
            "label": "Mood",
            "type": "enum",
            "options": [
                {"value": "good", "label": "Good"},
                {"value": "bad", "label": "Bad"},
                {"value": "meh", "label": "Meh", "archived": True},
            ],
        },
        {"key": "extra", "label": "Extra", "type": "int", "required": False},
    ]
)

VALID: dict[str, AnswerValue | None] = {"count": 3, "weight": 1.5, "note": "hey", "mood": "good"}


def issues(answers: dict[str, Any], **kw: Any) -> dict[str, str]:
    with pytest.raises(InvalidAnswers) as exc:
        validate_answers(QUESTIONS, answers, **kw)
    return {str(i.loc[1]): i.message for i in exc.value.errors}


def by_key(typed: list[TypedAnswer]) -> dict[str, TypedAnswer]:
    return {t.key: t for t in typed}


def test_valid_answers_typed() -> None:
    typed = by_key(validate_answers(QUESTIONS, VALID))
    assert set(typed) == {"count", "weight", "note", "mood"}
    assert typed["count"] == TypedAnswer("count", "int", 0, value_int=3)
    assert typed["weight"] == TypedAnswer("weight", "double", 1, value_double=1.5)
    assert typed["note"] == TypedAnswer("note", "str", 2, value_str="hey")
    assert typed["mood"] == TypedAnswer("mood", "enum", 3, value_str="good")


def test_positions_follow_question_order() -> None:
    typed = validate_answers(QUESTIONS, {**VALID, "extra": 1})
    assert [t.position for t in typed] == [0, 1, 2, 3, 4]


def test_int_given_as_whole_float() -> None:
    t = by_key(validate_answers(QUESTIONS, {**VALID, "count": 5.0}))["count"]
    assert t.value_int == 5
    assert type(t.value_int) is int


def test_int_rejects_fraction_string_and_bool() -> None:
    assert issues({**VALID, "count": 5.5})["count"] == "must be an integer"
    assert issues({**VALID, "count": "5"})["count"] == "must be an integer"
    assert issues({**VALID, "count": True})["count"] == "must be an integer"


def test_int_bounds() -> None:
    assert issues({**VALID, "count": -1})["count"] == "must be >= 0"
    assert issues({**VALID, "count": 11})["count"] == "must be <= 10"
    for edge in (0, 10):
        assert by_key(validate_answers(QUESTIONS, {**VALID, "count": edge}))["count"].value_int == edge


def test_int_outside_int64_rejected() -> None:
    # Unbounded int question: values must still fit the BIGINT column.
    assert "range" in issues({**VALID, "extra": 2**63})["extra"]
    assert "range" in issues({**VALID, "extra": -(2**63) - 1})["extra"]
    assert "range" in issues({**VALID, "extra": 1e300})["extra"]
    ok = validate_answers(QUESTIONS, {**VALID, "extra": 2**63 - 1})
    assert by_key(ok)["extra"].value_int == 2**63 - 1


def test_double_accepts_int_and_checks_bounds() -> None:
    t = by_key(validate_answers(QUESTIONS, {**VALID, "weight": 2}))["weight"]
    assert t.value_double == 2.0
    assert isinstance(t.value_double, float)
    assert issues({**VALID, "weight": 0.4})["weight"] == "must be >= 0.5"
    assert issues({**VALID, "weight": 2.6})["weight"] == "must be <= 2.5"


def test_double_rejects_non_numbers() -> None:
    assert issues({**VALID, "weight": "1.5"})["weight"] == "must be a number"
    assert issues({**VALID, "weight": False})["weight"] == "must be a number"
    assert issues({**VALID, "weight": float("nan")})["weight"] == "must be finite"
    assert issues({**VALID, "weight": float("inf")})["weight"] == "must be finite"


def test_str_lengths_and_type() -> None:
    assert issues({**VALID, "note": "x"})["note"] == "must be at least 2 characters"
    assert issues({**VALID, "note": "toolong"})["note"] == "must be at most 5 characters"
    assert issues({**VALID, "note": 12})["note"] == "must be a string"


def test_str_is_trimmed() -> None:
    assert by_key(validate_answers(QUESTIONS, {**VALID, "note": "  hey  "}))["note"].value_str == "hey"


def test_str_rejects_nul() -> None:
    # Postgres text cannot hold NUL bytes; must be a validation error, not a 500.
    assert "invalid" in issues({**VALID, "note": "a\x00b"})["note"]


def test_blank_string_counts_as_missing() -> None:
    assert issues({**VALID, "note": "   "})["note"] == "required"
    assert issues({**VALID, "mood": ""})["mood"] == "required"


def test_required_and_optional() -> None:
    errs = issues({})
    assert errs == dict.fromkeys(("count", "weight", "note", "mood"), "required")
    assert issues({**VALID, "count": None})["count"] == "required"
    # Optional: absent, null and blank are all fine and produce no answer.
    for extra in ({}, {"extra": None}):
        assert "extra" not in by_key(validate_answers(QUESTIONS, {**VALID, **extra}))


def test_unknown_keys_reported() -> None:
    errs = issues({**VALID, "nope": 1})
    assert errs == {"nope": "unknown question"}


def test_all_problems_reported_at_once() -> None:
    errs = issues({"count": 99, "weight": "x", "note": "a", "mood": "nope", "zzz": 1})
    assert set(errs) == {"count", "weight", "note", "mood", "zzz"}
    assert errs["mood"] == "must be one of: bad, good"  # archived options not advertised


def test_enum_type_and_archived() -> None:
    assert issues({**VALID, "mood": 1})["mood"] == "must be one of the option values"
    assert issues({**VALID, "mood": "meh"})["mood"] == "option is archived"


def test_enum_allowed_archived() -> None:
    typed = validate_answers(
        QUESTIONS, {**VALID, "mood": "meh"}, allowed_archived={"mood": frozenset({"meh"})}
    )
    assert by_key(typed)["mood"].value_str == "meh"
    # Allowance is per key and per value.
    assert (
        issues({**VALID, "mood": "meh"}, allowed_archived={"mood": frozenset({"bad"})})["mood"]
        == "option is archived"
    )
    assert (
        issues({**VALID, "mood": "meh"}, allowed_archived={"other": frozenset({"meh"})})["mood"]
        == "option is archived"
    )


def test_error_locations() -> None:
    with pytest.raises(InvalidAnswers) as exc:
        validate_answers(QUESTIONS, {**VALID, "count": 100})
    assert exc.value.status_code == 422
    assert exc.value.code == "invalid_answers"
    assert [i.loc for i in exc.value.errors] == [["answers", "count"]]


def test_answer_map_is_strict() -> None:
    """The request-level AnswerMap never coerces: '5' stays a string, true is rejected."""
    parsed = answer_map_adapter.validate_json('{"a": "5", "b": 5, "c": 5.5, "d": null}')
    assert parsed == {"a": "5", "b": 5, "c": 5.5, "d": None}
    assert type(parsed["b"]) is int
    with pytest.raises(ValueError, match=r"must be a number, a string, or a list of strings"):
        answer_map_adapter.validate_json('{"a": true}')
    with pytest.raises(ValueError, match="must start with a lowercase letter"):
        answer_map_adapter.validate_json('{"Bad Key": 1}')
