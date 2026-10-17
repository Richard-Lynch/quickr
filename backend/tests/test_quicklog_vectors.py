"""Quick-log vectors: ``shared/fixtures/quicklog-vectors.json``.

Generated from ``app/services/quicklog.py``; ``frontend/src/lib/quickLog.vectors.test.ts``
asserts the TS ``quickLogFor`` / ``initialNumber`` agree on every case, and the Swift
port will do the same. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the
file; otherwise the committed file must match.
"""

from __future__ import annotations

import json
import struct
from typing import Any

import pytest
from pydantic import TypeAdapter

from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, Question, StrQuestion
from app.services.quicklog import (
    QUICK_CHIP_LIMIT,
    QuickLogChips,
    initial_number,
    js_number_string,
    quick_log_for,
)
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "quicklog-vectors.json"
GENERATOR_VERSION = 1

question_adapter: TypeAdapter[IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion] = TypeAdapter(
    Question
)


def enum(n: int, key: str = "mood", archived: tuple[int, ...] = (), **kw: Any) -> dict[str, Any]:
    options = [
        {"value": f"o{i}", "label": f"Option {i}", **({"archived": True} if i in archived else {})}
        for i in range(n)
    ]
    return {"key": key, "label": key.title(), "type": "enum", "options": options, **kw}


def num(type_: str, key: str = "n", **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": type_, **kw}


NOTE = {"key": "note", "label": "Note", "type": "str", "required": False}

ELIGIBILITY: dict[str, list[dict[str, Any]]] = {
    "empty": [],
    "enum-1": [enum(1)],
    "enum-4": [enum(4)],
    "enum-6": [enum(QUICK_CHIP_LIMIT)],
    "enum-7": [enum(QUICK_CHIP_LIMIT + 1)],
    "enum-7-one-archived": [enum(QUICK_CHIP_LIMIT + 1, archived=(0,))],
    "enum-7-middle-archived": [enum(QUICK_CHIP_LIMIT + 1, archived=(3,))],
    "enum-3-two-archived": [enum(3, archived=(0, 2))],
    "enum-multi": [enum(3, multiple=True)],
    "enum-multi-bounded": [enum(4, multiple=True, min_selected=1, max_selected=2)],
    "enum-optional": [enum(3, required=False)],
    "enum-with-optional-note": [enum(3), NOTE],
    "note-then-enum": [NOTE, enum(3)],
    "enum-and-int-required": [enum(3), num("int")],
    "optional-enum-required-int": [enum(3, required=False), num("int", min=0, max=10)],
    "int": [num("int", min=0, max=30)],
    "int-optional": [num("int", required=False)],
    "double": [num("double", min=0, max=24, decimals=1, unit="h")],
    "double-with-optional-int": [num("double"), num("int", key="m", required=False)],
    "str-required": [{**NOTE, "required": True}],
    "str-optional-only": [NOTE],
    "all-optional": [enum(3, required=False), num("int", required=False), NOTE],
    "two-numbers": [num("int"), num("double", key="m")],
}

# Last logged values, as JSON would carry them (null = never logged / unanswered).
LAST_VALUES: list[Any] = [
    None,
    0,
    7,
    7.0,
    7.5,
    -3,
    99,
    0.1 + 0.2,
    1e-6,
    1.5e-7,
    123456789012345680000.0,
    1e21,
    2**53 - 1,
    2**53,
    -0.0,
    2**53 + 2,
    2**53 + 4,
    -(2**53 + 4),
    "7",
    True,
    [7],
]

NUMBER_QUESTIONS: dict[str, dict[str, Any]] = {
    "int-0-30": num("int", min=0, max=30),
    "int-neg-min": num("int", min=-5),
    "int-unbounded": num("int"),
    "int-min-3": num("int", min=3, max=10),
    "int-max-neg": num("int", max=-1),
    "double-0-24": num("double", min=0, max=24, decimals=1),
    "double-min-half": num("double", min=0.5, max=10),
    "double-min-whole-float": num("double", min=2.0),
    "double-neg-min": num("double", min=-10.5, max=10),
    "double-tiny": num("double", min=1e-7),
    "double-unbounded": num("double"),
    # Integer bounds past 2**53 round when the client parses them as doubles:
    # 2**53 + 3 -> 2**53 + 4, 2**53 + 1 -> 2**53.
    "double-max-above-2^53": num("double", max=2**53 + 3),
    "double-min-above-2^53": num("double", min=2**53 + 1),
    "double-below-neg-2^53": num("double", min=-(2**53 + 3), max=-(2**53 + 1)),
    "int-max-above-2^53": num("int", min=0, max=2**53 + 3),
    "int-min-above-2^53": num("int", min=2**53 + 1),
    "int-max-safe": num("int", min=-(2**53 - 1), max=2**53 - 1),
}


def question(raw: dict[str, Any]) -> IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion:
    return question_adapter.validate_python(raw)


def descriptor(questions: list[dict[str, Any]]) -> dict[str, Any] | None:
    r = quick_log_for([question(q) for q in questions])
    if r is None:
        return None
    if isinstance(r, QuickLogChips):
        return {
            "kind": r.kind,
            "key": r.question.key,
            "options": [{"value": o.value, "label": o.label} for o in r.options],
        }
    return {"kind": r.kind, "key": r.question.key}


def build() -> dict[str, Any]:
    eligibility = []
    for name, raw in ELIGIBILITY.items():
        eligibility.append(
            {
                "name": name,
                "questions": [question(q).model_dump(mode="json") for q in raw],
                "expected": descriptor(raw),
            }
        )
    initial = []
    for name, spec in NUMBER_QUESTIONS.items():
        q = question(spec)
        assert isinstance(q, IntQuestion | DoubleQuestion)
        for last in LAST_VALUES:
            initial.append(
                {
                    "name": f"{name}/last={json.dumps(last)}",
                    "question": q.model_dump(mode="json"),
                    "last": last,
                    "expected": initial_number(q, last),
                }
            )
    return {
        "meta": {
            "generator": "backend/tests/test_quicklog_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "quick_chip_limit": QUICK_CHIP_LIMIT,
            "semantics": [
                "eligibility: quickLogFor(questions) -> null | {kind: 'chips', key, options: active "
                "options in order} | {kind: 'number', key}.",
                "initial: initialNumber(question, last) -> the text a number quick-log starts with: "
                "String(last) (JS Number::toString) when last is a number the question still accepts, "
                "else String(min) when min >= 0, else ''. Non-numbers (strings, booleans, lists, "
                "null) count as no last value.",
            ],
        },
        "eligibility": eligibility,
        "initial": initial,
    }


def test_quicklog_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


@pytest.mark.parametrize(
    ("x", "expected"),
    [
        (0, "0"),
        (-0.0, "0"),
        (7.0, "7"),
        (-3, "-3"),
        (0.1 + 0.2, "0.30000000000000004"),
        (1e-6, "0.000001"),
        (1.5e-7, "1.5e-7"),
        (1e-7, "1e-7"),
        (123456789012345680000.0, "123456789012345680000"),
        (1e21, "1e+21"),
        (1.5e300, "1.5e+300"),
        (5e-324, "5e-324"),
        (2**53, "9007199254740992"),
        (float("nan"), "NaN"),
        (float("-inf"), "-Infinity"),
    ],
)
def test_js_number_string(x: float, expected: str) -> None:
    assert js_number_string(x) == expected


def test_js_number_string_matches_v8() -> None:
    """Every case of ``jsnumber-vectors.json`` (V8's ``String(x)``, from
    ``frontend/scripts/gen-jsnumber-vectors.js``); the Swift port checks the same file."""
    doc = json.loads((FIXTURES_DIR / "jsnumber-vectors.json").read_text())
    assert len(doc["cases"]) > 5000
    mismatches = []
    for case in doc["cases"]:
        (x,) = struct.unpack(">d", bytes.fromhex(case["bits"]))
        if js_number_string(x) != case["string"]:
            mismatches.append((case["bits"], js_number_string(x), case["string"]))
    assert mismatches == []
