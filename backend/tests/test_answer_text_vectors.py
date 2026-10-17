"""Answer text vectors: ``shared/fixtures/answer-text-vectors.json``.

How the server normalises and accepts text and choice answers (``services/answers.py``):
Python ``str.strip()`` (whose whitespace differs from JS ``trim``: it strips U+001C-U+001F
and U+0085, but not U+FEFF), lengths in code points, and NUL. Each case carries the
message the clients show when the server would reject the value, so the PWA
(``frontend/src/lib/answerText.vectors.test.ts``) and iOS (``AnswerTextVectorTests``)
assert the same acceptance, stored value and message. ``QUICKR_UPDATE_VECTORS=1``
(``make vectors``) rewrites the file; otherwise the committed file must match.
"""

from __future__ import annotations

import sys
from typing import Any

from pydantic import TypeAdapter

from app.errors import InvalidAnswers
from app.schemas.questions import EnumQuestion, Question, StrQuestion
from app.services.answers import validate_answers
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "answer-text-vectors.json"
GENERATOR_VERSION = 1

question_adapter: TypeAdapter[Any] = TypeAdapter(Question)

# Every code point Python's str.strip() removes.
PY_WHITESPACE = [c for c in range(sys.maxunicode + 1) if chr(c).isspace()]
# JS trim() also removes U+FEFF; U+180E and U+200B look blank but neither strips them.
LOOKALIKES = [0xFEFF, 0x180E, 0x200B]

QUESTIONS: dict[str, dict[str, Any]] = {
    "required": {"key": "t", "label": "T", "type": "str"},
    "min2-max4": {"key": "t", "label": "T", "type": "str", "min_length": 2, "max_length": 4},
    "max1": {"key": "t", "label": "T", "type": "str", "min_length": 0, "max_length": 1},
    "optional": {"key": "t", "label": "T", "type": "str", "required": False},
    "choice": {
        "key": "t",
        "label": "T",
        "type": "enum",
        "options": [{"value": "good", "label": "Good"}, {"value": "meh", "label": "Meh"}],
    },
    "multi": {
        "key": "t",
        "label": "T",
        "type": "enum",
        "multiple": True,
        "required": False,
        "options": [{"value": "a", "label": "A"}, {"value": "b", "label": "B"}],
    },
}


def cps(s: str) -> list[int]:
    return [ord(c) for c in s]


def client_message(q: StrQuestion | EnumQuestion, raw: str | list[str]) -> str | None:
    """The PWA's message for an input the server would reject (None when it accepts it)."""
    if isinstance(q, EnumQuestion) and q.multiple:
        assert isinstance(raw, list)
        picked = list(dict.fromkeys(v.strip() for v in raw if v.strip()))
        if not picked:
            return "Pick at least one" if q.required else None
        if any(v not in q.all_values() for v in picked):
            return "Pick from the options"
        return None
    assert isinstance(raw, str)
    value = raw.strip()
    if not value:
        return "Required" if q.required else None
    if isinstance(q, EnumQuestion):
        return None if value in q.all_values() else "Pick one of the options"
    if "\x00" in value:
        return "Remove the invalid character"
    if len(value) < q.min_length:
        return f"At least {q.min_length} characters ({len(value)} so far)"
    if len(value) > q.max_length:
        return f"At most {q.max_length} characters ({len(value)} entered)"
    return None


def case(name: str, spec: str, raw: str | list[str]) -> dict[str, Any]:
    q = question_adapter.validate_python(QUESTIONS[spec])
    out: dict[str, Any] = {"name": name, "question": q.model_dump(mode="json")}
    out["raw"] = [cps(v) for v in raw] if isinstance(raw, list) else cps(raw)
    message = client_message(q, raw)
    try:
        typed = validate_answers([q], {q.key: raw})
    except InvalidAnswers:
        assert message is not None, f"{name}: the server rejects it but the client message is None"
        out["expected"] = {"ok": False, "message": message}
        return out
    assert message is None, f"{name}: the server accepts it but the client says {message!r}"
    if not typed:
        out["expected"] = {"ok": True, "value": None}
    elif typed[0].value_list is not None:
        out["expected"] = {"ok": True, "value": [cps(v) for v in typed[0].value_list]}
    else:
        assert typed[0].value_str is not None
        out["expected"] = {"ok": True, "value": cps(typed[0].value_str)}
    return out


def build() -> dict[str, Any]:
    cases: list[dict[str, Any]] = []
    for c in PY_WHITESPACE + LOOKALIKES:
        ch = chr(c)
        tag = f"U+{c:04X}"
        cases += [
            case(f"required/{tag}", "required", ch),
            case(f"min2/a{tag}", "min2-max4", "a" + ch),
            case(f"optional/{tag}ab{tag}", "optional", ch + "ab" + ch),
            case(f"choice/{tag}good", "choice", ch + "good"),
            case(f"multi/{tag}a,b{tag}", "multi", [ch + "a", "b" + ch]),
        ]
    cases += [
        case("emoji/one-below-min", "min2-max4", "😀"),
        case("emoji/two", "min2-max4", "😀😀"),
        case("emoji/four", "min2-max4", "😀😀😀😀"),
        case("emoji/five-above-max", "min2-max4", "😀😀😀😀😀"),
        case("emoji/max1-one", "max1", "😀"),
        case("emoji/max1-two", "max1", "😀😀"),
        case("combining/e+acute-is-two", "min2-max4", "é"),
        case("nul/inside", "min2-max4", "a\x00b"),
        case("nul/alone", "required", "\x00"),
        case("plain/trimmed", "min2-max4", "  ab  "),
    ]
    return {
        "meta": {
            "generator": "backend/tests/test_answer_text_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "python_whitespace": PY_WHITESPACE,
            "semantics": [
                "Strings are arrays of Unicode code points (raw input and stored value).",
                "raw: what the user typed: one string, or a list of picked values for a multi-select.",
                "expected: {ok: true, value} where value is what the server stores (null = "
                "unanswered), or {ok: false, message} with the client's message.",
                "Text and choice values are stripped with Python str.strip() (python_whitespace), "
                "lengths count code points, and NUL is rejected.",
            ],
        },
        "cases": cases,
    }


def test_answer_text_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))
