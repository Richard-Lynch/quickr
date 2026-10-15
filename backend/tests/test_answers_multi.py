"""validate_answers for multi-select enum questions (pure, no DB)."""

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

OPTIONS = [
    {"value": "caffeine", "label": "Caffeine"},
    {"value": "screen", "label": "Screens"},
    {"value": "stress", "label": "Stress"},
    {"value": "alcohol", "label": "Alcohol", "archived": True},
]


def questions(**enum: Any) -> list[Question]:
    return questions_adapter.validate_python(
        [{"key": "factors", "label": "Factors", "type": "enum", "options": OPTIONS, "multiple": True, **enum}]
    )


def errors(qs: list[Question], answers: dict[str, Any], **kw: Any) -> list[tuple[list[str | int], str]]:
    with pytest.raises(InvalidAnswers) as exc:
        validate_answers(qs, answers, **kw)
    return [(i.loc, i.message) for i in exc.value.errors]


def test_list_stored_in_option_order() -> None:
    typed = validate_answers(questions(), {"factors": ["stress", " caffeine "]})
    assert typed == [TypedAnswer("factors", "enum", 0, value_list=("caffeine", "stress"))]


def test_single_value_rejected_for_multiple() -> None:
    assert errors(questions(), {"factors": "caffeine"}) == [
        (["answers", "factors"], "must be a list of option values (this question is multi-select)")
    ]


def test_list_rejected_for_single_select() -> None:
    qs = questions_adapter.validate_python(
        [{"key": "mood", "label": "Mood", "type": "enum", "options": OPTIONS[:2]}]
    )
    assert errors(qs, {"mood": ["caffeine"]}) == [
        (["answers", "mood"], "must be a single option value (this question is not multi-select)")
    ]


def test_unknown_duplicate_and_archived_values_located_per_item() -> None:
    assert errors(questions(), {"factors": ["caffeine", "nope", "caffeine", "alcohol"]}) == [
        (["answers", "factors", 1], "'nope' is not an option; choose from: caffeine, screen, stress"),
        (["answers", "factors", 2], "'caffeine' is selected more than once"),
        (["answers", "factors", 3], "option 'alcohol' is archived"),
    ]


def test_archived_values_allowed_when_already_held() -> None:
    typed = validate_answers(
        questions(), {"factors": ["alcohol", "screen"]}, allowed_archived={"factors": frozenset({"alcohol"})}
    )
    assert typed[0].value_list == ("screen", "alcohol")


@pytest.mark.parametrize("empty", [[], None])
def test_empty_selection_is_unanswered(empty: list[str] | None) -> None:
    assert errors(questions(), {"factors": empty}) == [(["answers", "factors"], "required")]
    assert validate_answers(questions(required=False), {"factors": empty}) == []


def test_min_and_max_selected() -> None:
    qs = questions(min_selected=2, max_selected=2)
    assert errors(qs, {"factors": ["screen"]}) == [(["answers", "factors"], "select at least 2 options")]
    assert errors(qs, {"factors": ["screen", "stress", "caffeine"]}) == [
        (["answers", "factors"], "select at most 2 options")
    ]
    assert validate_answers(qs, {"factors": ["screen", "stress"]})[0].value_list == ("screen", "stress")


def test_optional_question_still_enforces_min_when_answered() -> None:
    qs = questions(required=False, min_selected=2)
    assert errors(qs, {"factors": ["screen"]}) == [(["answers", "factors"], "select at least 2 options")]


def test_max_one_message_is_singular() -> None:
    assert errors(questions(max_selected=1), {"factors": ["screen", "stress"]}) == [
        (["answers", "factors"], "select at most 1 option")
    ]


def test_wrong_item_types_rejected_at_request_level() -> None:
    with pytest.raises(ValueError, match="list of strings"):
        answer_map_adapter.validate_python({"factors": [1, 2]})
    assert answer_map_adapter.validate_python({"factors": ["a"]}) == {"factors": ["a"]}
