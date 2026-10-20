"""Notification vectors: ``shared/fixtures/notification-vectors.json``.

Generated from ``app/services/notification.py``: the ``quick_log`` descriptor, the actions
it renders and their category id (docs/ios/specs/notifications.md §2.3, §4). The iOS app
registers categories from its local store with a Swift port, which must produce the same
descriptors, actions and ids from these inputs (spec test N1). ``QUICKR_UPDATE_VECTORS=1``
(``make vectors``) rewrites the file; otherwise the committed file must match.
"""

from __future__ import annotations

import dataclasses
import math
import struct
from typing import Any, Literal

from pydantic import TypeAdapter

from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, Question, StrQuestion
from app.services import notification
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "notification-vectors.json"
GENERATOR_VERSION = 2

SERVER_ID = "0b9e0000-0000-4000-8000-0000000000aa"
TOPIC_ID = "6f1c0000-0000-4000-8000-000000000001"

question_adapter: TypeAdapter[IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion] = TypeAdapter(
    Question
)


def enum(labels: list[str], key: str = "mood", label: str = "Mood", **kw: Any) -> dict[str, Any]:
    options = [{"value": f"o{i}", "label": text} for i, text in enumerate(labels)]
    return {"key": key, "label": label, "type": "enum", "options": options, **kw}


def numbered(n: int) -> list[str]:
    return [f"Option {i}" for i in range(n)]


def num(type_: str, key: str = "n", label: str = "N", **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": label, "type": type_, **kw}


LONG = "Ünïcödé label that is much longer than sixty-four characters, so it gets cut " * 2
NOTE = {"key": "note", "label": "Note", "type": "str", "required": False}

# name -> (questions, counts per option value, last answer, version)
CASES: dict[str, tuple[list[dict[str, Any]], dict[str, int], Any, int]] = {
    "ineligible-str": ([{**NOTE, "required": True}], {}, None, 1),
    "ineligible-two-required": ([enum(numbered(2)), num("int")], {}, None, 1),
    "ineligible-enum-7": ([enum(numbered(7))], {}, None, 1),
    "enum-1": ([enum(["Yes"])], {}, None, 1),
    "enum-4": ([enum(numbered(4))], {"o3": 9}, None, 1),
    "enum-4-with-optional-note": ([enum(numbered(4)), NOTE], {}, None, 2),
    "enum-5-unused": ([enum(numbered(5))], {}, None, 1),
    "enum-6-most-used": ([enum(numbered(6))], {"o5": 4, "o2": 4, "o4": 9, "o0": 1}, None, 3),
    "enum-6-unknown-and-archived-counts": (
        [
            {
                **enum(numbered(7)),
                "options": [
                    *enum(numbered(6))["options"],
                    {"value": "gone", "label": "Gone", "archived": True},
                ],
            }
        ],
        {"gone": 99, "removed": 50, "o1": 1},
        None,
        1,
    ),
    "enum-7-one-archived": (
        [
            {
                **enum(numbered(7)),
                "options": [{**o, "archived": o["value"] == "o0"} for o in enum(numbered(7))["options"]],
            }
        ],
        {"o0": 10},
        None,
        1,
    ),
    "enum-non-ascii": ([enum(["😴 Tired", "Café", "Café", "日本語"], label="Ärger")], {}, None, 1),
    "enum-truncated-labels": ([enum([LONG, "🌊" * 200], label=LONG)], {}, None, 1),
    "int-no-last": ([num("int", min=0, max=30)], {}, None, 1),
    "int-last": ([num("int", min=0, max=30, unit="glasses")], {}, 7, 4),
    "int-last-whole-double": ([num("int", unit="glasses")], {}, 7.0, 1),
    "int-last-out-of-bounds": ([num("int", min=0, max=5)], {}, 7, 1),
    "int-last-not-a-number": ([num("int")], {}, "7", 1),
    "int-last-big": ([num("int")], {}, 2**62, 1),
    # Integer bounds past 2**53, where a binary64 comparison can't tell 2**53 + 3 from 2**53 + 4.
    "int-max-big-accept": ([num("int", max=2**53 + 3)], {}, 2**53 + 3, 1),
    "int-max-big-reject": ([num("int", max=2**53 + 3)], {}, 2**53 + 4, 1),
    "int-min-big-accept": ([num("int", min=-(2**53 + 3))], {}, -(2**53 + 3), 1),
    "int-min-big-reject": ([num("int", min=-(2**53 + 3))], {}, -(2**53 + 4), 1),
    "double-no-last": ([num("double", min=0, max=24, decimals=1, unit="h")], {}, None, 1),
    "double-last": (
        [num("double", key="hours", label="Sleep", min=0, max=24, decimals=1, unit="h")],
        {},
        7.5,
        3,
    ),
    "double-last-padded": ([num("double", decimals=2, unit="kg")], {}, 70, 1),
    "double-last-more-digits-than-decimals": ([num("double", decimals=1)], {}, 7.25, 1),
    "double-last-midpoint": ([num("double", decimals=2, unit="€")], {}, 2.675, 1),
    "double-last-subnormal": ([num("double")], {}, 5e-324, 1),
    "double-decimals-0": ([num("double", decimals=0)], {}, 8.0, 1),
    "double-null-unit-null-decimals": ([num("double")], {}, 0.1 + 0.2, 1),
    "double-null-decimals-tiny": ([num("double")], {}, 1.5e-7, 1),
    "double-null-decimals-huge": ([num("double")], {}, 1e21, 1),
    "double-negative-zero": ([num("double", decimals=1)], {}, -0.0, 1),
    "double-empty-unit": ([num("double", unit="")], {}, 2.5, 1),
    "double-non-ascii-unit": ([num("double", label="Température", unit="°C", decimals=1)], {}, -3.5, 1),
    "double-truncated-label": ([num("double", label=LONG, unit="µ" * 32)], {}, 1.25, 1),
}

FMT: list[tuple[Literal["int", "double"], int | float]] = [
    ("int", 0),
    ("int", -42),
    ("int", 2**53 + 1),
    ("int", 2**63 - 1),
    ("int", -(2**63)),
    # Whole, signed zero, everyday values.
    ("double", 0.0),
    ("double", -0.0),
    ("double", 7.0),
    ("double", 7.5),
    ("double", 100.0),
    ("double", -123.456),
    ("double", 0.1),
    ("double", 0.1 + 0.2),
    ("double", 1 / 3),
    ("double", 2 / 3),
    # Near decimal rounding midpoints: never rounded, always the shortest round-trip form.
    ("double", 0.125),
    ("double", 2.675),
    ("double", math.nextafter(2.675, math.inf)),
    ("double", math.nextafter(2.675, -math.inf)),
    ("double", 1.005),
    ("double", 0.615),
    ("double", 8.345),
    ("double", 4.35),
    ("double", 123456789.125),
    ("double", 1e15 + 0.3),
    # Integers at the edge of binary64 precision.
    ("double", float(2**53)),
    ("double", float(2**53 + 2)),
    ("double", 9007199254740993.0),  # rounds to 2**53
    # Very large and very small magnitudes, subnormals.
    ("double", 1e16),
    ("double", 1e21),
    ("double", 1e22),
    ("double", 1e23),
    ("double", -1e300),
    ("double", 1.7976931348623157e308),
    ("double", 1e-7),
    ("double", 1.5e-7),
    ("double", 1e-10),
    ("double", 2.2250738585072014e-308),  # smallest normal
    ("double", 2.225073858507201e-308),  # largest subnormal
    ("double", 5e-324),  # smallest subnormal
    ("double", -5e-324),
]


def fmt_case(kind: Literal["int", "double"], value: int | float) -> dict[str, Any]:
    """A ``fmt`` vector; doubles also carry their exact bits, independent of JSON parsing."""
    bits = {"bits": struct.pack(">d", value).hex()} if kind == "double" else {}
    return {"kind": kind, "value": value, **bits, "expected": notification.fmt(kind, value)}


def action_json(action: notification.Action) -> dict[str, Any]:
    return {k: v for k, v in dataclasses.asdict(action).items() if v is not None}


def case(
    name: str, raw: list[dict[str, Any]], counts: dict[str, int], last: Any, version: int
) -> dict[str, Any]:
    questions = [question_adapter.validate_python(q) for q in raw]
    quick_log = notification.descriptor(questions, counts=counts, last=last)
    expected: dict[str, Any] = {"quick_log": None, "actions": [], "hash_input": None, "category_id": None}
    if quick_log is not None:
        actions = notification.actions(SERVER_ID, TOPIC_ID, version, quick_log)
        expected = {
            "quick_log": quick_log.model_dump(mode="json"),
            "actions": [action_json(a) for a in actions],
            "hash_input": notification.category_hash_input(actions),
            "category_id": notification.category_id(TOPIC_ID, actions),
        }
    expected["body_suffix"] = notification.more_suffix(quick_log)
    return {
        "name": name,
        "server_id": SERVER_ID,
        "topic_id": TOPIC_ID,
        "version": version,
        "questions": [q.model_dump(mode="json") for q in questions],
        "counts": counts,
        "last": last,
        "expected": expected,
    }


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_notification_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "max_label_length": notification.MAX_LABEL_LENGTH,
            "semantics": [
                "descriptor: quickLogFor(questions) decides eligibility (quicklog-vectors.json). Enum: "
                "{type: 'enum', key, label, options: [{value, label}], total_options}; with <= 4 active "
                "options all of them in question order, with 5-6 the 3 with the highest counts[value] "
                "(missing = 0), ties in question order. Number: {type: 'int'|'double', key, label, unit, "
                "min, max, decimals (null for int), last_value}.",
                "Labels (question and option) and units are cut to 64 Unicode scalars, the last one "
                "replaced by '…'. An empty unit is null.",
                "last_value: `last` (the latest numeric answer for the key, by captured_at then entry "
                "id) when the server would accept it as an answer to the question (type, bounds; a "
                "whole double counts as an int); else null. decimals is a display hint and never "
                "drops or rounds it. Ints stay ints, doubles are JSON doubles.",
                "actions: enum: one {kind: 'log', identifier: q1|server|topic|version|key|o|value, "
                "title: label} per option, then {kind: 'open', identifier: ...|m|, title: 'More…'} "
                "when total_options > options.length. Number: when last_value != null, {kind: 'log', "
                "identifier: ...|n|fmt(last), title: '✓ ' + fmt(last) + (unit ? ' ' + unit : '')}; "
                "then {kind: 'input', identifier: ...|i|, title: 'Other value…', "
                "text_input_button_title: 'Log', text_input_placeholder: unit ? 'Value in ' + unit : "
                "'Value'}.",
                "category_id: 'quickr.t.' + topic_id + '.' + the first 16 lowercase hex digits of "
                "sha256(UTF-8(NFC(hash_input))). hash_input = 'quickr-cat-v1' + for each action: "
                "U+001E + kind + U+001F + identifier + U+001F + title (+ U+001F + button title + "
                "U+001F + placeholder for 'input'). hash_input is listed already NFC-normalised.",
                "body_suffix: appended to the APNs alert body when options are cut: ' · {n} of "
                "{total} shown, More for all'.",
                "fmt(kind, value): int: base 10. double: the shortest decimal that round-trips to "
                "the same binary64 value (JS String(x), Python repr), written positionally (no "
                "exponent), with no trailing zeros or dot; '0' for both zeros. No rounding: decimals "
                "is not used. Always '.', no grouping. `bits` is the double's IEEE 754 big-endian "
                "hex, to build it without a JSON parser.",
            ],
        },
        "cases": [case(name, *spec) for name, spec in CASES.items()],
        "fmt": [fmt_case(kind, value) for kind, value in FMT],
    }


def test_notification_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_spec() -> None:
    """notifications.md §4.3: enums with 1, 4 and 6 options, numbers with and without a last
    value, null unit and decimals, non-ASCII labels, truncation."""
    cases = {c["name"]: c["expected"] for c in build()["cases"]}
    kinds = {(q["quick_log"] or {}).get("type") for q in cases.values()}
    assert kinds == {None, "enum", "int", "double"}
    assert len(cases["enum-1"]["actions"]) == 1
    assert len(cases["enum-4"]["actions"]) == 4
    assert [a["kind"] for a in cases["enum-6-most-used"]["actions"]] == ["log", "log", "log", "open"]
    assert cases["int-last"]["quick_log"]["last_value"] == 7
    assert cases["int-no-last"]["quick_log"]["last_value"] is None
    assert cases["double-null-unit-null-decimals"]["quick_log"]["unit"] is None
    assert cases["double-null-unit-null-decimals"]["quick_log"]["decimals"] is None
    assert cases["enum-truncated-labels"]["quick_log"]["label"].endswith("…")
    # Composed and decomposed "Café" are different labels but hash alike.
    titles = [a["title"] for a in cases["enum-non-ascii"]["actions"]]
    assert titles[1] != titles[2]
    assert cases["enum-non-ascii"]["hash_input"].count("Café") == 2
