"""check_compatibility (pure, no DB)."""

from __future__ import annotations

from typing import Any

from pydantic import TypeAdapter

from app.schemas.api import CompatibilityReport
from app.schemas.questions import Question
from app.services.compat import check_compatibility

adapter: TypeAdapter[list[Question]] = TypeAdapter(list[Question])


def qs(*items: dict[str, Any]) -> list[Question]:
    return adapter.validate_python(list(items))


def i(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "int", **kw}


def d(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "double", **kw}


def s(key: str, **kw: Any) -> dict[str, Any]:
    return {"key": key, "label": key.title(), "type": "str", **kw}


def e(key: str, *values: str, archived: tuple[str, ...] = (), **kw: Any) -> dict[str, Any]:
    options = [{"value": v, "label": v.title(), "archived": v in archived} for v in values]
    return {"key": key, "label": key.title(), "type": "enum", "options": options, **kw}


def levels(report: CompatibilityReport, level: str) -> dict[str | None, str]:
    return {x.question_key: x.message for x in report.issues if x.level == level}


def kinds(report: CompatibilityReport) -> dict[str, str]:
    return {c.question_key: c.kind for c in report.changes}


def test_no_changes_is_an_error() -> None:
    v1 = qs(i("a"), s("b"))
    r = check_compatibility([v1], qs(i("a"), s("b")))
    assert not r.ok
    assert levels(r, "error") == {None: "no changes to publish"}
    assert r.changes == []


def test_next_version() -> None:
    v1, v2 = qs(i("a")), qs(i("a"), s("b"))
    assert check_compatibility([v1], v2).next_version == 2
    assert check_compatibility([v1, v2], qs(s("b"))).next_version == 3


def test_add_question() -> None:
    r = check_compatibility([qs(i("a"))], qs(i("a"), s("b"), s("c", required=False)))
    assert r.ok
    assert kinds(r) == {"b": "added", "c": "added"}
    # Only the required addition gets the info note.
    assert set(levels(r, "info")) == {"b"}


def test_remove_question_warns() -> None:
    r = check_compatibility([qs(i("a"), s("b"))], qs(i("a")))
    assert r.ok
    assert kinds(r) == {"b": "removed"}
    assert "historic answers are kept" in levels(r, "warning")["b"]


def test_type_change_is_error() -> None:
    r = check_compatibility([qs(i("a"))], qs(d("a")))
    assert not r.ok
    assert levels(r, "error")["a"] == "type cannot change (int -> double); use a new key"
    assert "a" not in kinds(r)


def test_type_change_detected_across_history() -> None:
    """A key removed in v2 and re-added in v3 with another type is still blocked."""
    v1, v2 = qs(i("a"), s("b")), qs(s("b"))
    r = check_compatibility([v1, v2], qs(s("b"), s("a")))
    assert not r.ok
    assert "type cannot change (int -> str)" in levels(r, "error")["a"]


def test_restore_removed_question() -> None:
    v1, v2 = qs(i("a", max=10), s("b")), qs(s("b"))
    r = check_compatibility([v1, v2], qs(s("b"), i("a", max=10, label="New label")))
    assert r.ok
    change = next(c for c in r.changes if c.question_key == "a")
    assert change.kind == "restored"
    assert change.details == ["label: A -> New label"]


def test_restore_compares_against_latest_prior_definition() -> None:
    v1 = qs(i("a", max=5), s("b"))
    v2 = qs(i("a", max=50), s("b"))
    v3 = qs(s("b"))
    r = check_compatibility([v1, v2, v3], qs(s("b"), i("a", max=50)))
    assert r.ok
    assert next(c for c in r.changes if c.question_key == "a").details == []


def test_restored_enum_cannot_drop_options() -> None:
    v1, v2 = qs(e("m", "x", "y"), s("b")), qs(s("b"))
    r = check_compatibility([v1, v2], qs(s("b"), e("m", "x")))
    assert not r.ok
    assert levels(r, "error")["m"] == "option 'y' cannot be removed; archive it instead"


def test_enum_option_removal_is_error() -> None:
    r = check_compatibility([qs(e("m", "x", "y", "z"))], qs(e("m", "x")))
    assert not r.ok
    errors = [x.message for x in r.issues if x.level == "error"]
    assert sorted(errors) == [
        "option 'y' cannot be removed; archive it instead",
        "option 'z' cannot be removed; archive it instead",
    ]


def test_enum_archive_add_relabel_reorder() -> None:
    r = check_compatibility(
        [qs(e("m", "x", "y"))],
        qs(
            {
                **e("m", "y", "x", "z", archived=("x",)),
                "options": [
                    {"value": "y", "label": "Why"},
                    {"value": "x", "label": "X", "archived": True},
                    {"value": "z", "label": "Z"},
                ],
            }
        ),
    )
    assert r.ok
    (change,) = r.changes
    assert change.kind == "modified"
    assert set(change.details) == {
        "option added: z",
        "option y label: Y -> Why",
        "option x archived",
        "options reordered",
    }


def test_enum_unarchive() -> None:
    r = check_compatibility([qs(e("m", "x", "y", archived=("y",)))], qs(e("m", "x", "y")))
    assert r.ok
    assert r.changes[0].details == ["option y unarchived"]


def test_question_reorder() -> None:
    r = check_compatibility([qs(i("a"), i("b"), i("c"))], qs(i("c"), i("a"), i("b")))
    assert r.ok
    assert [(c.kind, c.question_key) for c in r.changes] == [("reordered", "*")]


def test_reorder_ignores_added_and_removed() -> None:
    r = check_compatibility([qs(i("a"), i("b"), i("c"))], qs(i("new"), i("a"), i("c")))
    assert "*" not in kinds(r)


def test_tightened_numeric_range_warns() -> None:
    v1 = qs(i("a", min=0, max=10), d("b"))
    r = check_compatibility([v1], qs(i("a", min=1, max=10), d("b", max=3.5)))
    assert r.ok
    warnings = levels(r, "warning")
    assert set(warnings) == {"a", "b"}
    assert "range tightened" in warnings["a"]
    details = {c.question_key: c.details for c in r.changes}
    assert details["a"] == ["min: 0 -> 1"]
    assert details["b"] == ["max: none -> 3.5"]


def test_loosened_range_does_not_warn() -> None:
    r = check_compatibility([qs(i("a", min=0, max=10))], qs(i("a", min=-5)))
    assert r.ok
    assert levels(r, "warning") == {}
    assert r.changes[0].details == ["min: 0 -> -5", "max: 10 -> none"]


def test_double_specific_attrs() -> None:
    r = check_compatibility([qs(d("a", decimals=1, unit="kg"))], qs(d("a", decimals=2, unit="lb")))
    assert r.changes[0].details == ["unit: kg -> lb", "decimals: 1 -> 2"]


def test_str_length_tightened_warns() -> None:
    r = check_compatibility([qs(s("a", max_length=100))], qs(s("a", max_length=50, multiline=True)))
    assert r.ok
    assert "length limits tightened" in levels(r, "warning")["a"]
    assert r.changes[0].details == ["max_length: 100 -> 50", "multiline: False -> True"]


def test_now_required_warns() -> None:
    r = check_compatibility([qs(i("a", required=False))], qs(i("a")))
    assert r.ok
    assert "now required" in levels(r, "warning")["a"]
    assert r.changes[0].details == ["required: False -> True"]


def test_label_and_help_changes() -> None:
    r = check_compatibility([qs(i("a"))], qs(i("a", label="Alpha", help_text="Some help")))
    assert r.changes[0].details == ["label: A -> Alpha", "help_text: none -> Some help"]
    assert r.issues == []
