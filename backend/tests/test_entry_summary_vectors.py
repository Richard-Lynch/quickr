"""Entry summary vectors: ``shared/fixtures/entry-summary-vectors.json``.

Generated from :func:`app.services.summary.entry_summary` (docs/specs/content-display.md
§1): the one-line summary of an entry every client shows (entry rows, tiles, widgets). The
PWA (``entrySummary.vectors.test.ts``) and the iOS app (``EntrySummaryVectorTests``) must
print the same text for the same answers, timing, questions and timer.
``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the committed
file must match.

The typed-lap cases of §1.3 use M1's ``TimingSegment.lap_type`` and ``Timer.laps``
(timers2.md §1, §3.2): the ``tiktok`` and ``renamed`` timer sets declare lap types.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
import regex
from pydantic import TypeAdapter

from app.schemas.api import AnswerOut, Timing, TimingPause, TimingSegment
from app.schemas.questions import Question, Timer
from app.services import summary
from app.services.run_fold import lap_label
from app.services.summary import ELLIPSIS, MAX_SUMMARY_LENGTH, SEPARATOR, entry_summary, graphemes
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "entry-summary-vectors.json"
GENERATOR_VERSION = 1

question_adapter: TypeAdapter[Any] = TypeAdapter(Question)
answer_adapter: TypeAdapter[Any] = TypeAdapter(AnswerOut)

T0 = datetime(2026, 10, 23, 8, 0, tzinfo=UTC)
# The whitespace a text answer collapses: Unicode White_Space, the set every port can spell.
WHITE_SPACE = [ord(c) for c in regex.findall(r"\p{White_Space}", "".join(map(chr, range(0x110000))))]
# Blank-looking code points no port treats as whitespace here (JS `\s` would strip U+FEFF;
# Python `str.split()` would split on U+001F).
LOOKALIKES = "\u200b\ufeff\u001f\u180e"
S = 1000  # one second in ms

WEIGHT = {"key": "weight", "label": "Weight", "type": "int", "unit": "kg"}
TEMP = {"key": "temp", "label": "Temp", "type": "double", "decimals": 1, "unit": "°C", "required": False}
DOSE = {"key": "dose", "label": "Dose", "type": "double", "required": False}
MOOD = {
    "key": "mood",
    "label": "Mood",
    "type": "enum",
    "required": False,
    "options": [
        {"value": "happy", "label": "Happy"},
        {"value": "meh", "label": "Meh"},
        {"value": "sad", "label": "Sad", "archived": True},
    ],
}
MOOD_MULTI = {
    "key": "mood",
    "label": "Mood",
    "type": "enum",
    "multiple": True,
    "required": False,
    "options": [
        {"value": "mild", "label": "Mild"},
        {"value": "tired", "label": "Tired"},
        {"value": "calm", "label": "Calm"},
    ],
}
NOTE = {"key": "note", "label": "Note", "type": "str", "required": False, "multiline": True}

QUESTION_SETS: dict[str, list[dict[str, Any]]] = {
    "none": [],
    "weight": [WEIGHT],
    "mood_multi": [MOOD_MULTI],
    "mixed": [WEIGHT, TEMP, DOSE, MOOD, NOTE],
}

STEP_LABELS = {"pour": "Pour", "drink": "Drink"}
# Lap type labels a segment is named after; `swim` and `walk` are declared by no timer set
# (a type a later version removed), so the summary falls back to the key.
LAP_TYPE_LABELS = {"run": "Run", "rest": "Rest", "cig": "Cig", "swim": "Swim", "walk": "Walk"}


def _lap_types(*keys: str) -> list[dict[str, str]]:
    return [{"key": k, "label": LAP_TYPE_LABELS[k]} for k in keys]


# `plain` and `stepped` have no lap types (v1's shape); `tiktok` alternates two and
# `renamed` renames laps (timers2.md §1).
TIMER_SETS: dict[str, dict[str, Any] | None] = {
    "none": None,
    "plain": {"steps": []},
    "stepped": {"steps": [{"key": k, "label": v} for k, v in STEP_LABELS.items()]},
    "tiktok": {"steps": [], "laps": _lap_types("run", "rest")},
    "renamed": {"steps": [], "laps": _lap_types("cig")},
}

# Every case content-display.md §1.3 lists, in its order.
SPEC_CASES = [
    "timing_only_no_laps",
    "timing_one_lap",
    "timing_three_laps",
    "timing_tiktok",
    "timing_renamed",
    "timing_mixed_typed_untyped",
    "timing_lap_type_not_in_timer",
    "timing_hour_plus",
    "timing_paused_ignored",
    "answers_int_unit",
    "answers_double_decimals",
    "answers_double_trailing_zeros",
    "answers_enum_single",
    "answers_enum_multi",
    "answers_enum_unknown_option",
    "answers_str_collapsed_whitespace",
    "answers_str_empty_skipped",
    "answers_missing_optional_skipped",
    "both_timing_then_answers",
    "order_follows_questions_not_answers",
    "question_without_answer_skipped",
    "long_truncated",
    "long_truncation_flag_pair",
    "long_truncation_keycap",
    "long_truncation_zwj_family",
    "long_truncation_combining_marks",
    "empty",
    "untimed_entry_of_timed_topic",
]


def a(key: str, value: int | float | str | list[str], type_: str | None = None) -> dict[str, Any]:
    """An ``AnswerOut`` as the wire carries it; the type follows the value unless given."""
    if type_ is None:
        match value:
            case list():
                type_ = "enum_list"
            case str():
                type_ = "str"
            case float():
                type_ = "double"
            case _:
                type_ = "int"
    return {"key": key, "type": type_, "value": value}


def enum(key: str, value: str) -> dict[str, Any]:
    return a(key, value, "enum")


def _overlap(start: int, end: int, pauses: list[tuple[int, int]]) -> int:
    return sum(max(0, min(end, p_end) - max(start, p_start)) for p_start, p_end in pauses)


def timing(parts: Sequence[tuple[str | None, int]], pauses: list[tuple[int, int]] | None = None) -> Timing:
    """A finished run from its segments: ``parts`` is each segment's key (a step key, a lap
    type key, or None for an untyped lap) and its wall duration in ms, in order; ``pauses``
    are ``(start, end)`` offsets from the run's start. A typed lap is labelled with its
    per-type ordinal ("Run 2"), an untyped one "Lap n"."""
    pauses = pauses or []
    segments: list[TimingSegment] = []
    at = 0
    seen: dict[str | None, int] = {}
    for key, duration in parts:
        step = key if key in STEP_LABELS else None
        lap_type = key if key in LAP_TYPE_LABELS else None
        if step is None:
            seen[lap_type] = seen.get(lap_type, 0) + 1
        if step is not None:
            label = STEP_LABELS[step]
        elif lap_type is not None:
            label = f"{LAP_TYPE_LABELS[lap_type]} {seen[lap_type]}"
        else:
            label = lap_label(seen[None])
        end = at + duration
        paused = _overlap(at, end, pauses)
        segments.append(
            TimingSegment(
                kind="lap" if step is None else "step",
                step=step,
                label=label,
                lap_type=lap_type,
                started_at=T0 + timedelta(milliseconds=at),
                ended_at=T0 + timedelta(milliseconds=end),
                active_ms=end - at - paused,
                paused_ms=paused,
            )
        )
        at = end
    paused_total = sum(end - start for start, end in pauses)
    return Timing(
        started_at=T0,
        ended_at=T0 + timedelta(milliseconds=at),
        active_ms=at - paused_total,
        paused_ms=paused_total,
        complete=True,
        edited=False,
        segments=segments,
        skipped=[],
        pauses=[
            TimingPause(start=T0 + timedelta(milliseconds=s), end=T0 + timedelta(milliseconds=e))
            for s, e in pauses
        ],
    )


TWELVE_FORTY = 760 * S
ONE_LAP = timing([(None, TWELVE_FORTY)])
THREE_LAPS = timing([(None, 300 * S), (None, 200 * S), (None, 260 * S)])

# Long notes that put a multi-code-point cluster at or over the cut. "Note: " is 6 clusters,
# so the line's 79th cluster is the note's 73rd and its 80th the note's 74th.
NOTE_PREFIX = "Note: "
FLAG = "🇬🇧"  # two regional indicators
KEYCAP = "1️⃣"  # digit, U+FE0F, U+20E3
FAMILY = "👨‍👩‍👧‍👦"  # four people joined by three U+200D
E_ACUTE = "é"  # base plus combining mark
LONG_NOTE = ("walked the dog " * 7).strip()  # 104 clusters
CUT_NOTE = NOTE_PREFIX + LONG_NOTE[:73] + ELLIPSIS  # the line ends inside "dog"


def case(
    name: str,
    questions: str,
    timer: str,
    answers: list[dict[str, Any]],
    t: Timing | None,
    expect: str,
) -> dict[str, Any]:
    """One vector; ``expect`` is the text §1.3 (or this file) names for it, asserted here."""
    qs = [question_adapter.validate_python(q) for q in QUESTION_SETS[questions]]
    tm = None if TIMER_SETS[timer] is None else Timer.model_validate(TIMER_SETS[timer])
    expected = entry_summary([answer_adapter.validate_python(x) for x in answers], t, qs, tm)
    assert expected == expect, f"{name}: {expected!r} != {expect!r}"
    return {
        "name": name,
        "questions": questions,
        "timer": timer,
        "answers": answers,
        "timing": None if t is None else t.model_dump(mode="json"),
        "expected": expected,
    }


def cases() -> list[dict[str, Any]]:
    stepped = timing([("pour", 300 * S), ("drink", 460 * S)])
    tiktok = timing([("run", 130 * S), ("rest", 120 * S)] * 2 + [("run", 130 * S), ("rest", 130 * S)])
    hour_plus = timing([(None, 3600 * S), (None, 123 * S)])
    paused = timing([(None, 400 * S), (None, 480 * S)], pauses=[(100 * S, 220 * S)])
    collapsed = "walked \n\n  the\t dog\r\n"
    unicode_ws = "\u00a0walked\u0085the\u2003\u3000dog\u2028"
    lookalikes = "a" + LOOKALIKES + "b"
    everything = [a("weight", 72), a("dose", 2.5), enum("mood", "happy"), a("note", "walked")]
    return [
        # --- the timing part (§1.2) ---
        case("timing_only_no_laps", "none", "stepped", [], stepped, "12:40"),
        case("timing_one_lap", "none", "plain", [], ONE_LAP, "12:40 · 1 lap"),
        case("timing_three_laps", "none", "plain", [], THREE_LAPS, "12:40 · 3 laps"),
        case("timing_tiktok", "none", "tiktok", [], tiktok, "12:40 · Run 3 · Rest 3"),
        case(
            "timing_renamed",
            "none",
            "renamed",
            [],
            timing([("cig", 60 * S), ("cig", 185 * S)]),
            "4:05 · Cig 2",
        ),
        # Untyped laps from before the version that added the types, then typed ones: the
        # untyped remainder comes last.
        case(
            "timing_mixed_typed_untyped",
            "none",
            "tiktok",
            [],
            timing([(None, 200 * S), (None, 160 * S), ("run", 150 * S), ("rest", 100 * S), ("run", 150 * S)]),
            "12:40 · Run 2 · Rest 1 · 2 laps",
        ),
        # The current timer no longer declares the run's lap types: the key is the label.
        case(
            "timing_lap_type_not_in_timer",
            "none",
            "plain",
            [],
            timing([("run", 300 * S), ("rest", 160 * S), ("run", 300 * S)]),
            "12:40 · run 2 · rest 1",
        ),
        # Declared types in the timer's order (not the run's), then undeclared ones as first seen.
        case(
            "timing_lap_types_declared_then_first_seen",
            "none",
            "renamed",
            [],
            timing(
                [("walk", 100 * S), ("cig", 200 * S), ("swim", 160 * S), ("cig", 200 * S), ("walk", 100 * S)]
            ),
            "12:40 · Cig 2 · walk 2 · swim 1",
        ),
        case(
            "timing_declared_order_not_run_order",
            "none",
            "tiktok",
            [],
            timing([("rest", 100 * S), ("run", 300 * S), ("rest", 60 * S), ("run", 300 * S)]),
            "12:40 · Run 2 · Rest 2",
        ),
        case(
            "timing_typed_laps_untimed_topic",
            "weight",
            "none",
            [a("weight", 72)],
            tiktok,
            "12:40 · run 3 · rest 3 · Weight: 72 kg",
        ),
        case("timing_hour_plus", "none", "plain", [], hour_plus, "1:02:03 · 2 laps"),
        case("timing_paused_ignored", "none", "plain", [], paused, "12:40 · 2 laps"),
        case(
            "timing_sub_second_truncated",
            "none",
            "plain",
            [],
            timing([(None, TWELVE_FORTY + 999)]),
            "12:40 · 1 lap",
        ),
        # --- answer_text (§1.2) ---
        case("answers_int_unit", "weight", "none", [a("weight", 72)], None, "Weight: 72 kg"),
        case("answers_int_no_grouping", "weight", "none", [a("weight", 12345)], None, "Weight: 12345 kg"),
        case("answers_double_decimals", "mixed", "none", [a("temp", 36.6)], None, "Temp: 36.6 °C"),
        case("answers_double_rounds_half_up", "mixed", "none", [a("temp", 36.65)], None, "Temp: 36.7 °C"),
        case("answers_double_negative", "mixed", "none", [a("temp", -0.25)], None, "Temp: -0.3 °C"),
        case("answers_double_trailing_zeros", "mixed", "none", [a("dose", 2.5)], None, "Dose: 2.5"),
        case("answers_double_integer_value", "mixed", "none", [a("dose", 2.0)], None, "Dose: 2"),
        case("answers_double_default_decimals", "mixed", "none", [a("dose", 2.34567)], None, "Dose: 2.346"),
        case("answers_double_no_grouping", "mixed", "none", [a("dose", 1234.5)], None, "Dose: 1234.5"),
        case("answers_enum_single", "mixed", "none", [enum("mood", "happy")], None, "Mood: Happy"),
        case("answers_enum_archived_option", "mixed", "none", [enum("mood", "sad")], None, "Mood: Sad"),
        case("answers_enum_unknown_option", "mixed", "none", [enum("mood", "grumpy")], None, "Mood: grumpy"),
        case(
            "answers_enum_multi",
            "mood_multi",
            "none",
            [a("mood", ["mild", "tired"])],
            None,
            "Mood: Mild, Tired",
        ),
        case(
            "answers_enum_multi_unknown_option",
            "mood_multi",
            "none",
            [a("mood", ["mild", "wired"])],
            None,
            "Mood: Mild, wired",
        ),
        case("answers_enum_multi_empty_skipped", "mood_multi", "none", [a("mood", [])], None, ""),
        case(
            "answers_str_collapsed_whitespace",
            "mixed",
            "none",
            [a("note", collapsed)],
            None,
            "Note: walked the dog",
        ),
        case(
            "answers_str_empty_skipped",
            "mixed",
            "none",
            [a("weight", 72), a("note", " \n\t ")],
            None,
            "Weight: 72 kg",
        ),
        case(
            "answers_str_unicode_whitespace",
            "mixed",
            "none",
            [a("note", unicode_ws)],
            None,
            "Note: walked the dog",
        ),
        case(
            "answers_str_unicode_whitespace_only_skipped",
            "mixed",
            "none",
            [a("note", "\u00a0\u0085\u3000")],
            None,
            "",
        ),
        case(
            "answers_str_lookalikes_kept",
            "mixed",
            "none",
            [a("note", lookalikes)],
            None,
            "Note: " + lookalikes,
        ),
        case("answers_missing_optional_skipped", "mixed", "none", [a("weight", 72)], None, "Weight: 72 kg"),
        # --- the line (§1.2) ---
        case(
            "both_timing_then_answers",
            "weight",
            "plain",
            [a("weight", 72)],
            THREE_LAPS,
            "12:40 · 3 laps · Weight: 72 kg",
        ),
        case(
            "order_follows_questions_not_answers",
            "mixed",
            "none",
            [a("note", "walked"), enum("mood", "happy"), a("weight", 72)],
            None,
            "Weight: 72 kg · Mood: Happy · Note: walked",
        ),
        case(
            "question_without_answer_skipped",
            "mixed",
            "none",
            [a("weight", 72), enum("mood", "happy")],
            None,
            "Weight: 72 kg · Mood: Happy",
        ),
        case(
            "answer_without_question_skipped",
            "weight",
            "none",
            [a("weight", 72), a("steps_count", 9000)],
            None,
            "Weight: 72 kg",
        ),
        case(
            "all_answers",
            "mixed",
            "plain",
            everything,
            ONE_LAP,
            "12:40 · 1 lap · Weight: 72 kg · Dose: 2.5 · Mood: Happy · Note: walked",
        ),
        # --- truncate (§1.2) ---
        case(
            "long_exactly_80_kept",
            "mixed",
            "none",
            [a("note", LONG_NOTE[:74])],
            None,
            NOTE_PREFIX + LONG_NOTE[:74],
        ),
        case("long_81_truncated", "mixed", "none", [a("note", LONG_NOTE[:73] + "xx")], None, CUT_NOTE),
        case("long_truncated", "mixed", "none", [a("note", LONG_NOTE)], None, CUT_NOTE),
        # The flag is the line's 80th cluster: dropped whole, never cut between its indicators.
        case(
            "long_truncation_flag_pair",
            "mixed",
            "none",
            [a("note", "x" * 73 + FLAG + "y" * 5)],
            None,
            NOTE_PREFIX + "x" * 73 + ELLIPSIS,
        ),
        # These are the 79th cluster: kept whole, where a code-point cut would split them.
        case(
            "long_truncation_keycap",
            "mixed",
            "none",
            [a("note", "x" * 72 + KEYCAP + "y" * 10)],
            None,
            NOTE_PREFIX + "x" * 72 + KEYCAP + ELLIPSIS,
        ),
        case(
            "long_truncation_zwj_family",
            "mixed",
            "none",
            [a("note", "x" * 72 + FAMILY + "y" * 10)],
            None,
            NOTE_PREFIX + "x" * 72 + FAMILY + ELLIPSIS,
        ),
        case(
            "long_truncation_combining_marks",
            "mixed",
            "none",
            [a("note", "x" * 72 + E_ACUTE + "y" * 10)],
            None,
            NOTE_PREFIX + "x" * 72 + E_ACUTE + ELLIPSIS,
        ),
        case(
            "long_truncation_with_timing",
            "mixed",
            "plain",
            [a("note", LONG_NOTE)],
            THREE_LAPS,
            ("12:40 · 3 laps · " + NOTE_PREFIX + LONG_NOTE)[: MAX_SUMMARY_LENGTH - 1] + ELLIPSIS,
        ),
        # --- nothing to say ---
        case("empty", "none", "none", [], None, ""),
        case("empty_untimed_entry_blank_note", "mixed", "plain", [a("note", "  ")], None, ""),
        case("untimed_entry_of_timed_topic", "weight", "plain", [a("weight", 72)], None, "Weight: 72 kg"),
    ]


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_entry_summary_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "max_length": MAX_SUMMARY_LENGTH,
            "separator": SEPARATOR,
            "whitespace": WHITE_SPACE,
            "semantics": [
                "entrySummary(answers, timing, questions, timer) (content-display.md §1.2): the timing "
                "part when timing is not null, then 'label: text' for each question of `questions` in "
                "that order whose answer has text, joined by meta.separator, then truncated. '' means "
                "nothing to say.",
                "Timing part: fmtDuration(active_ms) (duration-format-vectors.json); then, when the "
                "timing has lap segments (kind 'lap'): untyped laps as 'n lap' / 'n laps'; typed laps "
                "(segment.lap_type, M1) as '{label} {count}' per type in the timer's declared order "
                "then first seen, the type's key when the timer doesn't declare it, and the untyped "
                "remainder last as 'n lap(s)'. Pauses, steps and skipped steps are not shown.",
                "answer_text: int -> the integer, no thousands grouping, then ' unit' if the question "
                "has one; double -> at most `decimals` fraction digits (3 when null), rounded half away "
                "from zero from the number's shortest round-trip decimal (as Intl.NumberFormat and "
                "Swift's description), trailing zeros and a bare point dropped, no grouping, '.' as "
                "the decimal point, then the unit; enum -> the option's label, the raw value for an "
                "unknown option; enum_list -> labels joined by ', ', an empty list has no text; str -> "
                "runs of meta.whitespace (Unicode White_Space) collapsed to one space and trimmed, an empty "
                "result has no text. An "
                "answer whose key has no question is skipped; a question without an answer is skipped.",
                "truncate: lengths are extended grapheme clusters (UAX #29; Swift Character, "
                "Intl.Segmenter grapheme, Python regex \\X). A line of more than meta.max_length "
                "clusters keeps its first max_length - 1 clusters and appends U+2026; no word boundary, "
                "and a cluster is never split (flags, keycaps, ZWJ sequences, combining marks).",
                "cases[].questions / cases[].timer name an entry of question_sets / timer_sets: the "
                "entry's version's questions and the topic's current timer (null when untimed). "
                "cases[].answers are wire AnswerOut objects; cases[].timing is a wire Timing or null.",
                "meta.whitespace lists the code points answer_text collapses, exactly: not U+FEFF, "
                "U+200B, U+180E or U+001C..U+001F (answers_str_lookalikes_kept). The strings are not "
                "Unicode-normalised (long_truncation_combining_marks holds U+0065 U+0301).",
            ],
        },
        "question_sets": QUESTION_SETS,
        "timer_sets": {
            name: None if t is None else Timer.model_validate(t).model_dump(mode="json")
            for name, t in TIMER_SETS.items()
        },
        "cases": cases(),
    }


def test_entry_summary_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_spec() -> None:
    """Every case §1.3 names exists; names are unique."""
    names = [c["name"] for c in cases()]
    assert len(names) == len(set(names))
    missing = [n for n in SPEC_CASES if n not in names]
    assert not missing, f"§1.3 cases without a vector: {missing}"
    assert len(names) >= 20


@pytest.mark.parametrize("vector", cases(), ids=lambda c: str(c["name"]))
def test_no_line_exceeds_the_limit_and_no_cluster_is_split(
    vector: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    """Acceptance: at most 80 clusters, and a truncated line is the untruncated line's first
    79 clusters (so a cluster is never split) plus the ellipsis."""
    expected = vector["expected"]
    clusters = graphemes(expected)
    assert len(clusters) <= MAX_SUMMARY_LENGTH
    monkeypatch.setattr(summary, "MAX_SUMMARY_LENGTH", 10**9)
    qs = [question_adapter.validate_python(q) for q in QUESTION_SETS[vector["questions"]]]
    tm = None if TIMER_SETS[vector["timer"]] is None else Timer.model_validate(TIMER_SETS[vector["timer"]])
    t = None if vector["timing"] is None else Timing.model_validate(vector["timing"])
    full = entry_summary([answer_adapter.validate_python(x) for x in vector["answers"]], t, qs, tm)
    if len(graphemes(full)) > MAX_SUMMARY_LENGTH:
        assert clusters[-1] == ELLIPSIS
        assert len(clusters) == MAX_SUMMARY_LENGTH
        assert clusters[:-1] == graphemes(full)[: MAX_SUMMARY_LENGTH - 1]
    else:
        assert expected == full


def test_truncation_vectors_keep_clusters_whole() -> None:
    by_name = {c["name"]: c["expected"] for c in cases()}
    assert "\U0001f1ec" not in by_name["long_truncation_flag_pair"]  # no lone regional indicator
    assert by_name["long_truncation_keycap"].endswith(KEYCAP + ELLIPSIS)
    assert by_name["long_truncation_zwj_family"].endswith(FAMILY + ELLIPSIS)
    assert by_name["long_truncation_combining_marks"].endswith(E_ACUTE + ELLIPSIS)
    assert by_name["long_truncated"].endswith("do" + ELLIPSIS)  # inside a word, not at a boundary
    assert len(graphemes(by_name["long_exactly_80_kept"])) == MAX_SUMMARY_LENGTH
    assert ELLIPSIS not in by_name["long_exactly_80_kept"]
    assert [len(graphemes(v)) for v in (FLAG, KEYCAP, FAMILY, E_ACUTE)] == [1, 1, 1, 1]
