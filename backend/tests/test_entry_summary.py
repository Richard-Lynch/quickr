"""The entry summary line (docs/specs/content-display.md §1.2): one test per rule of the
timing part (typed laps included), ``answer_text`` and ``truncate`` (the vectors pin the
whole line: ``test_entry_summary_vectors.py``)."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from pydantic import TypeAdapter

from app.schemas.api import AnswerOut, Timing, TimingSegment
from app.schemas.questions import Question, Timer
from app.services import summary
from app.services.summary import (
    ELLIPSIS,
    MAX_SUMMARY_LENGTH,
    answer_text,
    entry_summary,
    graphemes,
    timing_summary,
    truncate,
)

question_adapter: TypeAdapter[Any] = TypeAdapter(Question)
answer_adapter: TypeAdapter[Any] = TypeAdapter(AnswerOut)
T0 = datetime(2026, 10, 23, 8, 0, tzinfo=UTC)


def q(**fields: Any) -> Any:
    return question_adapter.validate_python({"key": "k", "label": "K", **fields})


def ans(value: Any, type_: str) -> Any:
    return answer_adapter.validate_python({"key": "k", "type": type_, "value": value})


def lap_timing(*active_ms: int) -> Timing:
    """A run of untyped laps, one per duration, with no pauses."""
    segments: list[TimingSegment] = []
    at = 0
    for i, ms in enumerate(active_ms, start=1):
        segments.append(
            TimingSegment(
                kind="lap",
                step=None,
                label=f"Lap {i}",
                started_at=T0 + timedelta(milliseconds=at),
                ended_at=T0 + timedelta(milliseconds=at + ms),
                active_ms=ms,
                paused_ms=0,
            )
        )
        at += ms
    return Timing(
        started_at=T0,
        ended_at=T0 + timedelta(milliseconds=at),
        active_ms=at,
        paused_ms=0,
        complete=True,
        edited=False,
        segments=segments,
        skipped=[],
        pauses=[],
    )


# --- the timing part -------------------------------------------------------------------


def test_timing_part_is_the_active_duration() -> None:
    t = lap_timing(760_000).model_copy(update={"segments": [], "paused_ms": 120_000})
    assert timing_summary(t, None) == "12:40"


def test_untyped_laps_are_counted_with_the_plural() -> None:
    assert timing_summary(lap_timing(760_000), None) == "12:40 · 1 lap"
    assert (
        timing_summary(lap_timing(300_000, 460_000), Timer(steps=[], laps=[], variables=[]))
        == "12:40 · 2 laps"
    )


def test_step_segments_are_not_laps() -> None:
    t = lap_timing(300_000, 460_000)
    steps = [s.model_copy(update={"kind": "step", "step": "pour", "label": "Pour"}) for s in t.segments]
    assert timing_summary(t.model_copy(update={"segments": steps}), None) == "12:40"
    mixed = t.model_copy(update={"segments": [steps[0], t.segments[1]]})
    assert timing_summary(mixed, None) == "12:40 · 1 lap"


def _typed(laps: list[str | None], declared: list[tuple[str, str]] | None) -> str:
    """The timing part of a 12:40 run whose lap segments carry ``laps`` as their
    ``lap_type``, under a timer declaring ``declared`` lap types (None: untimed now)."""
    t = lap_timing(*[10_000] * len(laps)).model_copy(update={"active_ms": 760_000})
    t = t.model_copy(
        update={
            "segments": [s.model_copy(update={"lap_type": k}) for s, k in zip(t.segments, laps, strict=True)]
        }
    )
    timer = None
    if declared is not None:
        timer = Timer.model_validate({"steps": [], "laps": [{"key": k, "label": v} for k, v in declared]})
    return timing_summary(t, timer)


def test_typed_laps_are_counted_per_type_in_declared_order() -> None:
    declared = [("run", "Run"), ("rest", "Rest")]
    assert _typed(["rest", "run", "run", "rest", "run", "rest"], declared) == "12:40 · Run 3 · Rest 3"


def test_typed_laps_keep_the_keys_declaration_order_then_first_seen() -> None:
    declared = [("run", "Run"), ("rest", "Rest")]
    assert _typed(["cool", "rest", "warm", "run"], declared) == "12:40 · Run 1 · Rest 1 · cool 1 · warm 1"


def test_lap_type_the_timer_no_longer_declares_shows_its_key() -> None:
    assert _typed(["cig", "cig"], [("run", "Run")]) == "12:40 · cig 2"
    assert _typed(["cig", "cig"], None) == "12:40 · cig 2"


def test_untyped_remainder_follows_the_typed_counts() -> None:
    assert _typed(["run", None, "run", None, None], [("run", "Run")]) == "12:40 · Run 2 · 3 laps"
    assert _typed(["run", None], [("run", "Run")]) == "12:40 · Run 1 · 1 lap"


# --- answer_text -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("question", "answer", "expected"),
    [
        (q(type="int"), ans(72, "int"), "72"),
        (q(type="int", unit="kg"), ans(72, "int"), "72 kg"),
        (q(type="int"), ans(1_234_567, "int"), "1234567"),
        (q(type="int"), ans(-3, "int"), "-3"),
        (q(type="double"), ans(2.5, "double"), "2.5"),
        (q(type="double"), ans(2.0, "double"), "2"),
        (q(type="double"), ans(2.34567, "double"), "2.346"),
        (q(type="double", decimals=1, unit="°C"), ans(36.65, "double"), "36.7 °C"),
        (q(type="double", decimals=0), ans(2.5, "double"), "3"),
        (q(type="double", decimals=0), ans(-2.5, "double"), "-3"),
        (q(type="double", decimals=2), ans(1.005, "double"), "1.01"),
        (q(type="double"), ans(1234.5, "double"), "1234.5"),
        (q(type="double"), ans(1e21, "double"), "1000000000000000000000"),
        (q(type="double"), ans(0.0001, "double"), "0"),
        (q(type="double"), ans(5, "int"), "5"),
        (q(type="int"), ans(72.0, "double"), "72"),
    ],
)
def test_numbers(question: Any, answer: Any, expected: str) -> None:
    assert answer_text(question, answer) == expected


OPTIONS = [{"value": "mild", "label": "Mild"}, {"value": "tired", "label": "Tired"}]


def test_enum_single_shows_the_label_or_the_raw_value() -> None:
    e = q(type="enum", options=OPTIONS)
    assert answer_text(e, ans("mild", "enum")) == "Mild"
    assert answer_text(e, ans("grumpy", "enum")) == "grumpy"


def test_enum_list_joins_labels_and_skips_an_empty_selection() -> None:
    e = q(type="enum", options=OPTIONS, multiple=True)
    assert answer_text(e, ans(["mild", "tired"], "enum_list")) == "Mild, Tired"
    assert answer_text(e, ans(["tired", "odd"], "enum_list")) == "Tired, odd"
    assert answer_text(e, ans([], "enum_list")) is None
    # A question that switched between single and multi keeps its old answers' shape.
    assert answer_text(e, ans("mild", "enum")) == "Mild"
    assert answer_text(q(type="enum", options=OPTIONS), ans(["mild"], "enum_list")) == "Mild"


def test_str_collapses_whitespace_and_skips_blank() -> None:
    s = q(type="str")
    assert answer_text(s, ans("  walked \n the\t\tdog ", "str")) == "walked the dog"
    assert answer_text(s, ans(" \n ", "str")) is None
    assert answer_text(s, ans("", "str")) is None


def test_str_whitespace_is_unicode_white_space_exactly() -> None:
    """The one set Swift (`isWhitespace`) and JS (`\\p{White_Space}`) share: not Python's
    `str.split()` (U+001C..U+001F) and not JS `\\s` (U+FEFF)."""
    s = q(type="str")
    assert answer_text(s, ans("\u00a0a\u0085b\u2003\u3000c\u2028", "str")) == "a b c"
    assert answer_text(s, ans("\u1680\u200a\u202f\u205f", "str")) is None
    for kept in ("\u200b", "\ufeff", "\u180e", "\u001c", "\u001f"):
        assert answer_text(s, ans(f"a{kept}b", "str")) == f"a{kept}b"


def test_mismatched_shapes_have_no_text() -> None:
    assert answer_text(q(type="int"), ans("72", "str")) is None
    assert answer_text(q(type="str"), ans(72, "int")) is None
    assert answer_text(q(type="enum", options=OPTIONS), ans(1, "int")) is None


# --- the line ------------------------------------------------------------------------


def test_line_is_timing_then_answers_in_question_order() -> None:
    questions = [
        question_adapter.validate_python({"key": "w", "label": "Weight", "type": "int", "unit": "kg"}),
        question_adapter.validate_python({"key": "n", "label": "Note", "type": "str"}),
    ]
    answers = [
        answer_adapter.validate_python({"key": "n", "type": "str", "value": "walked"}),
        answer_adapter.validate_python({"key": "gone", "type": "int", "value": 1}),
        answer_adapter.validate_python({"key": "w", "type": "int", "value": 72}),
    ]
    assert (
        entry_summary(answers, lap_timing(760_000), questions, None)
        == "12:40 · 1 lap · Weight: 72 kg · Note: walked"
    )
    assert (
        entry_summary(answers, None, questions, Timer(steps=[], laps=[], variables=[]))
        == "Weight: 72 kg · Note: walked"
    )
    assert entry_summary(answers[:1], None, questions[:1], None) == ""
    assert entry_summary([], None, [], None) == ""


# --- truncate --------------------------------------------------------------------------


def test_truncate_keeps_79_clusters_and_appends_the_ellipsis() -> None:
    line = "ab " * 40  # 120 clusters, boundaries inside and between words
    cut = truncate(line)
    assert cut == line[:79] + ELLIPSIS
    assert len(graphemes(cut)) == MAX_SUMMARY_LENGTH
    assert truncate("x" * 80) == "x" * 80
    assert truncate("x" * 81) == "x" * 79 + ELLIPSIS
    assert truncate("") == ""


@pytest.mark.parametrize(
    "cluster",
    ["🇬🇧", "1️⃣", "👨‍👩‍👧‍👦", "é", "👍🏽", "🏳️‍🌈"],
    ids=["flag", "keycap", "zwj-family", "combining", "skin-tone", "zwj-flag"],
)
def test_truncate_never_splits_a_cluster(cluster: str) -> None:
    assert graphemes(cluster) == [cluster]
    for position in range(76, 82):  # the cluster straddles or sits beside the cut
        line = "x" * position + cluster + "y" * 10
        cut = truncate(line)
        assert len(graphemes(cut)) == MAX_SUMMARY_LENGTH
        kept = graphemes(cut)[:-1]
        assert kept == graphemes(line)[: MAX_SUMMARY_LENGTH - 1]
        assert cluster in cut or cluster not in "".join(kept)


def test_module_constants_match_the_spec() -> None:
    assert summary.MAX_SUMMARY_LENGTH == 80
    assert summary.SEPARATOR == " · "
    assert summary.ELLIPSIS == "…"
    assert summary.DEFAULT_DECIMALS == 3
