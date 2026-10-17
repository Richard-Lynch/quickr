"""Question-builder vectors: ``shared/fixtures/builder-vectors.json``.

What the server decides about the question configs a client builds, so the iOS builder
(``QuickrCore/Builder``) can prove it agrees without a network:

* ``questions[]``: a draft question list (strings, as the builder edits them) and the
  locations where ``QuestionSet`` rejects it (``schemas/questions.py``), so the client's
  draft validation accepts exactly what the server accepts and flags the field the server
  names.
* ``compat[]``: ``check_compatibility`` reports (``services/compat.py``) for the local
  pre-check that warns before ``versions/check``.
* ``slugs[]``: ``slugify`` (``services/topics.py``), which the builder pre-fills.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the committed
file must match.
"""

from __future__ import annotations

from typing import Any

from pydantic import TypeAdapter, ValidationError

from app.schemas.base import error_loc
from app.schemas.questions import Question, QuestionSet
from app.services.compat import check_compatibility
from app.services.topics import slugify
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "builder-vectors.json"
GENERATOR_VERSION = 1

adapter: TypeAdapter[list[Question]] = TypeAdapter(list[Question])

# --------------------------------------------------------------------------------------
# questions[]: drafts -> server verdict
# --------------------------------------------------------------------------------------

DRAFT_DEFAULTS: dict[str, dict[str, Any]] = {
    "int": {},
    "double": {"decimals": "1"},
    "str": {"min_length": "0", "max_length": "500"},
    "enum": {"options": [{"value": "yes", "label": "Yes"}, {"value": "no", "label": "No"}]},
}


def draft(type_: str, key: str = "q", label: str = "Q", **kw: Any) -> dict[str, Any]:
    """A builder draft: every constraint is the text of its input field."""
    base: dict[str, Any] = {
        "type": type_,
        "key": key,
        "label": label,
        "help_text": "",
        "required": True,
        "min": "",
        "max": "",
        "unit": "",
        "decimals": "",
        "min_length": "",
        "max_length": "",
        "multiline": False,
        "options": [],
        "multiple": False,
        "min_selected": "",
        "max_selected": "",
    }
    return {**base, **DRAFT_DEFAULTS[type_], **kw}


def opt(value: str, label: str | None = None, archived: bool = False) -> dict[str, Any]:
    return {"value": value, "label": value.title() if label is None else label, "archived": archived}


def number(text: str) -> int | float | None:
    """The JSON number a client sends for a constraint field ('' = not set)."""
    if text == "":
        return None
    try:
        return int(text)
    except ValueError:
        f = float(text)
    # Swift's JSONEncoder writes a whole double below 1e16 without a fraction or exponent.
    return int(f) if f.is_integer() and abs(f) < 1e16 else f


def request_json(d: dict[str, Any]) -> dict[str, Any]:
    """The question a client sends for a draft (selection limits only when multiple)."""
    q: dict[str, Any] = {
        "type": d["type"],
        "key": d["key"],
        "label": d["label"],
        "help_text": d["help_text"] or None,
        "required": d["required"],
    }
    match d["type"]:
        case "int" | "double":
            q |= {"min": number(d["min"]), "max": number(d["max"]), "unit": d["unit"] or None}
            if d["type"] == "double":
                q["decimals"] = number(d["decimals"])
        case "str":
            q |= {"multiline": d["multiline"]}
            for name in ("min_length", "max_length"):
                if d[name] != "":
                    q[name] = number(d[name])
        case "enum":
            q |= {"options": d["options"], "multiple": d["multiple"]}
            if d["multiple"]:
                q |= {"min_selected": number(d["min_selected"]), "max_selected": number(d["max_selected"])}
    return q


def server_errors(drafts: list[dict[str, Any]]) -> list[str]:
    """Dotted locations (relative to the question list) where the server rejects it."""
    try:
        QuestionSet.model_validate({"questions": [request_json(d) for d in drafts]})
    except ValidationError as exc:
        locs = {".".join(str(p) for p in error_loc(e["loc"], e.get("ctx"))[1:]) for e in exc.errors()}
        return sorted(locs)
    return []


WS = {
    f"U+{c:04X}": chr(c)
    for c in (
        0x85,
        0xA0,
        0x2028,
        0x3000,
        # Python str.isspace() but not Unicode White_Space: pydantic keeps them.
        0x1C,
        0x1F,
        # JS trim() strips it; pydantic doesn't.
        0xFEFF,
        0x200B,
    )
}

QUESTION_CASES: dict[str, list[dict[str, Any]]] = {
    "int/plain": [draft("int", min="0", max="10", unit="h")],
    "int/min-gt-max": [draft("int", min="5", max="1")],
    "int/min-eq-max": [draft("int", min="5", max="5")],
    "int/fraction": [draft("int", min="1.5")],
    "int/exponent-whole": [draft("int", max="1e3")],
    "int/int64-max": [draft("int", max="9223372036854775807")],
    "int/int64-overflow": [draft("int", max="9223372036854775808")],
    "int/int64-underflow": [draft("int", min="-9223372036854775809")],
    "int/above-js-safe": [draft("int", max="9007199254740993")],
    "double/plain": [draft("double", min="0", max="24.5", decimals="2", unit="kg")],
    "double/min-gt-max": [draft("double", min="2", max="1.5")],
    "double/decimals-max": [draft("double", decimals="10")],
    "double/decimals-over": [draft("double", decimals="11")],
    "double/decimals-negative": [draft("double", decimals="-1")],
    "double/decimals-fraction": [draft("double", decimals="1.5")],
    "double/no-decimals": [draft("double", decimals="")],
    "str/defaults": [draft("str")],
    "str/min-gt-max": [draft("str", min_length="10", max_length="5")],
    "str/max-zero": [draft("str", max_length="0")],
    "str/max-limit": [draft("str", max_length="10000")],
    "str/max-over-limit": [draft("str", max_length="10001")],
    "str/min-over-limit": [draft("str", min_length="10001", max_length="10000")],
    "str/min-over-default-max": [draft("str", min_length="600", max_length="")],
    "str/negative-min": [draft("str", min_length="-1")],
    "key/upper": [draft("int", key="Bad")],
    "key/digit-first": [draft("int", key="1a")],
    "key/63": [draft("int", key="a" * 63)],
    "key/64": [draft("int", key="a" * 64)],
    "key/empty": [draft("int", key="")],
    "key/padded": [draft("int", key="  ok_key  ")],
    "key/non-ascii": [draft("int", key="café")],
    "label/empty": [draft("int", label="")],
    "label/blank": [draft("int", label="   ")],
    "label/200": [draft("int", label="x" * 200)],
    "label/201": [draft("int", label="x" * 201)],
    "label/200-emoji": [draft("int", label="😀" * 200)],
    "label/201-emoji": [draft("int", label="😀" * 201)],
    "label/padded-200": [draft("int", label="  " + "x" * 200 + "  ")],
    "help/1000": [draft("int", help_text="h" * 1000)],
    "help/1001": [draft("int", help_text="h" * 1001)],
    "unit/32": [draft("int", unit="u" * 32)],
    "unit/33": [draft("int", unit="u" * 33)],
    "enum/plain": [draft("enum")],
    "enum/no-options": [draft("enum", options=[])],
    "enum/all-archived": [draft("enum", options=[opt("a", archived=True), opt("b", archived=True)])],
    "enum/one-active": [draft("enum", options=[opt("a", archived=True), opt("b")])],
    "enum/duplicate-value": [draft("enum", options=[opt("a", "A"), opt("a", "B")])],
    "enum/duplicate-label-case": [draft("enum", options=[opt("a", "Good"), opt("b", "GOOD")])],
    "enum/duplicate-label-casefold": [draft("enum", options=[opt("a", "Straße"), opt("b", "STRASSE")])],
    "enum/bad-value": [draft("enum", options=[opt("Bad value", "A")])],
    "enum/empty-value": [draft("enum", options=[opt("", "A")])],
    "enum/empty-label": [draft("enum", options=[opt("a", "")])],
    "enum/200-options": [draft("enum", options=[opt(f"o{i}") for i in range(200)])],
    "enum/201-options": [draft("enum", options=[opt(f"o{i}") for i in range(201)])],
    "multi/plain": [
        draft(
            "enum", multiple=True, options=[opt("a"), opt("b"), opt("c")], min_selected="1", max_selected="3"
        )
    ],
    "multi/min-gt-max": [
        draft(
            "enum", multiple=True, options=[opt("a"), opt("b"), opt("c")], min_selected="3", max_selected="2"
        )
    ],
    "multi/min-zero": [draft("enum", multiple=True, options=[opt("a"), opt("b")], min_selected="0")],
    "multi/max-over-active": [
        draft("enum", multiple=True, options=[opt("a", archived=True), opt("b"), opt("c")], max_selected="3")
    ],
    "multi/min-over-active": [draft("enum", multiple=True, options=[opt("a"), opt("b")], min_selected="3")],
    "multi/fraction": [draft("enum", multiple=True, options=[opt("a"), opt("b")], max_selected="1.5")],
    "single/limits-dropped": [draft("enum", options=[opt("a"), opt("b")], min_selected="2")],
    "list/two": [draft("int", key="a", label="A"), draft("str", key="b", label="B")],
    "list/duplicate-key": [draft("int", key="a", label="A"), draft("str", key="a", label="B")],
    "list/duplicate-label": [draft("int", key="a", label="Mood"), draft("str", key="b", label=" MOOD ")],
    "list/duplicate-label-casefold": [
        draft("int", key="a", label="Straße"),
        draft("str", key="b", label="strasse"),
    ],
    "list/empty": [],
    "list/100": [draft("int", key=f"q{i}", label=f"Q{i}") for i in range(100)],
    "list/101": [draft("int", key=f"q{i}", label=f"Q{i}") for i in range(101)],
}
for tag, ch in WS.items():
    QUESTION_CASES[f"ws/label-only-{tag}"] = [draft("int", label=ch)]
    QUESTION_CASES[f"ws/key-padded-{tag}"] = [draft("int", key=f"{ch}k{ch}")]
    QUESTION_CASES[f"ws/label-200-padded-{tag}"] = [draft("int", label=ch + "x" * 200)]
    QUESTION_CASES[f"ws/option-label-only-{tag}"] = [draft("enum", options=[opt("a", ch)])]
    QUESTION_CASES[f"ws/duplicate-label-{tag}"] = [
        draft("int", key="a", label="Mood"),
        draft("str", key="b", label=f"Mood{ch}"),
    ]


def question_cases() -> list[dict[str, Any]]:
    return [
        {"name": name, "drafts": drafts, "expected": {"errors": server_errors(drafts)}}
        for name, drafts in QUESTION_CASES.items()
    ]


# --------------------------------------------------------------------------------------
# compat[]: history + proposed -> report
# --------------------------------------------------------------------------------------


def _clean_doubles(q: dict[str, Any]) -> dict[str, Any]:
    """Whole double bounds below 1e16 as ints, as Swift's JSONEncoder sends them."""
    if q.get("type") == "double":
        for name in ("min", "max"):
            v = q.get(name)
            if isinstance(v, float) and v.is_integer() and abs(v) < 1e16:
                q[name] = int(v)
    return q


def qs(*items: dict[str, Any]) -> list[dict[str, Any]]:
    return [_clean_doubles(dict(x)) for x in items]


def i(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "int", **kw}


def d(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "double", **kw}


def s(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "str", **kw}


def e(key: str, *values: str, archived: tuple[str, ...] = (), **kw: Any) -> dict[str, Any]:
    options = [{"value": v, "label": v.title(), "archived": v in archived} for v in values]
    return {"key": key, "label": key.title(), "type": "enum", "options": options, **kw}


COMPAT_CASES: dict[str, tuple[list[list[dict[str, Any]]], list[dict[str, Any]]]] = {
    "no-changes": ([qs(i("a"), s("b"))], qs(i("a"), s("b"))),
    "add-required-and-optional": ([qs(i("a"))], qs(i("a"), s("b"), s("c", required=False))),
    "remove": ([qs(i("a"), s("b"))], qs(i("a"))),
    "type-change": ([qs(i("a"))], qs(d("a"))),
    "type-change-across-history": ([qs(i("a"), s("b")), qs(s("b"))], qs(s("b"), s("a"))),
    "restore": ([qs(i("a", max=10), s("b")), qs(s("b"))], qs(s("b"), i("a", max=10, label="New label"))),
    "restore-latest-prior": (
        [qs(i("a", max=5), s("b")), qs(i("a", max=50), s("b")), qs(s("b"))],
        qs(s("b"), i("a", max=50)),
    ),
    "restore-enum-drops-option": ([qs(e("m", "x", "y"), s("b")), qs(s("b"))], qs(s("b"), e("m", "x"))),
    "enum-remove-options": ([qs(e("m", "x", "y", "z"))], qs(e("m", "x"))),
    "enum-archive-add-relabel-reorder": (
        [qs(e("m", "x", "y"))],
        qs(
            {
                **e("m"),
                "options": [
                    {"value": "y", "label": "Why"},
                    {"value": "x", "label": "X", "archived": True},
                    {"value": "z", "label": "Z"},
                ],
            }
        ),
    ),
    "enum-unarchive": ([qs(e("m", "x", "y", archived=("y",)))], qs(e("m", "x", "y"))),
    "reorder": ([qs(i("a"), i("b"), i("c"))], qs(i("c"), i("a"), i("b"))),
    "reorder-ignores-added-removed": ([qs(i("a"), i("b"), i("c"))], qs(i("new"), i("a"), i("c"))),
    "range-tightened": ([qs(i("a", min=0, max=10), d("b"))], qs(i("a", min=1, max=10), d("b", max=3.5))),
    "range-loosened": ([qs(i("a", min=0, max=10))], qs(i("a", min=-5))),
    "range-upper-tightened": ([qs(d("a", min=0.5, max=10))], qs(d("a", min=0.5, max=9.75))),
    "double-float-formats": ([qs(d("a", min=1e-05, max=0.1))], qs(d("a", min=1e-06, max=1e20))),
    "double-attrs": ([qs(d("a", decimals=1, unit="kg"))], qs(d("a", decimals=2, unit="lb"))),
    "str-tightened": ([qs(s("a", max_length=100))], qs(s("a", max_length=50, multiline=True))),
    "str-min-tightened": ([qs(s("a"))], qs(s("a", min_length=1))),
    "str-loosened": ([qs(s("a", min_length=2, max_length=100))], qs(s("a", min_length=1, max_length=200))),
    "now-required": ([qs(i("a", required=False))], qs(i("a"))),
    "now-optional": ([qs(i("a"))], qs(i("a", required=False))),
    "label-and-help": ([qs(i("a"))], qs(i("a", label="Alpha", help_text="Some help"))),
    "help-removed": ([qs(i("a", help_text="Old"))], qs(i("a"))),
    "single-to-multiple": ([qs(e("f", "a", "b"))], qs(e("f", "a", "b", multiple=True, max_selected=2))),
    "multiple-to-single": ([qs(e("f", "a", "b", multiple=True))], qs(e("f", "a", "b"))),
    "multiple-to-single-restored": (
        [qs(e("f", "a", multiple=True), i("x")), qs(i("x"))],
        qs(i("x"), e("f", "a")),
    ),
    "selection-tightened": (
        [qs(e("f", "a", "b", "c", multiple=True, max_selected=3))],
        qs(e("f", "a", "b", "c", multiple=True, max_selected=2, min_selected=1)),
    ),
    "selection-loosened": (
        [qs(e("f", "a", "b", "c", multiple=True, max_selected=3))],
        qs(e("f", "a", "b", "c", multiple=True)),
    ),
    "selection-max-added": (
        [qs(e("f", "a", "b", "c", multiple=True))],
        qs(e("f", "a", "b", "c", multiple=True, max_selected=2)),
    ),
    "many-at-once": (
        [qs(i("a"), s("b", required=False), e("c", "x", "y")), qs(i("a"), e("c", "x", "y"), d("gone"))],
        qs(
            e("c", "y", "x", "w", archived=("x",), label="Choice"),
            s("b"),
            i("fresh", required=False),
            i("a", min=1),
        ),
    ),
}


def compat_case(
    name: str, history: list[list[dict[str, Any]]], proposed: list[dict[str, Any]]
) -> dict[str, Any]:
    h = [adapter.validate_python(v) for v in history]
    p = adapter.validate_python(proposed)
    r = check_compatibility(h, p)
    # Python iterates option sets in hash order: sort what isn't ordered by the questions.
    issues = sorted(
        ({"level": x.level, "question_key": x.question_key, "message": x.message} for x in r.issues),
        key=lambda x: (x["level"], x["question_key"] or "", x["message"]),
    )
    changes = [
        {"kind": c.kind, "question_key": c.question_key, "details": sorted(c.details)} for c in r.changes
    ]
    return {
        "name": name,
        "history": [[q.model_dump(mode="json") for q in v] for v in h],
        "proposed": [q.model_dump(mode="json") for q in p],
        "expected": {"ok": r.ok, "next_version": r.next_version, "issues": issues, "changes": changes},
    }


# --------------------------------------------------------------------------------------
# slugs[]
# --------------------------------------------------------------------------------------

SLUG_INPUTS = [
    "Sleep Log — 2026",
    "  --Hello__World-- ",
    "Café au lait",
    "Straße",
    "İstanbul",
    "".join(chr(0xFF00 + ord(c) - 0x20) for c in "Fullwidth"),
    "ﬁsh ﬂags",
    "½ marathon",
    "日本語",
    "😀 mood",
    "!!!",
    "",
    "x" * 70,
    "a" * 63 + "-b",
    "a" * 63 + " " + "b" * 10,
    "Ⅻ chapter",
    "Ångström",
]


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_builder_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "semantics": [
                "questions[].drafts: builder drafts, every constraint the text of its field; the "
                "request sends numbers parsed from that text and selection limits only when multiple.",
                "questions[].expected.errors: sorted dotted locations (relative to the question list) "
                "where QuestionSet rejects it; [] = accepted.",
                "compat[].expected: check_compatibility's report. issues are sorted by (level, "
                "question_key, message) and each change's details are sorted, because Python visits "
                "option sets in hash order.",
                "compat questions are full API shapes; whole double bounds below 1e16 are ints, as "
                "Swift's JSONEncoder sends them.",
                "slugs[]: services/topics.py slugify ('topic' when nothing is left).",
            ],
        },
        "questions": question_cases(),
        "compat": [compat_case(name, h, p) for name, (h, p) in COMPAT_CASES.items()],
        "slugs": [{"input": x, "expected": slugify(x)} for x in SLUG_INPUTS],
    }


def test_builder_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))
