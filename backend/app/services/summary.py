"""The entry summary line (docs/specs/content-display.md §1): one line of at most
:data:`MAX_SUMMARY_LENGTH` grapheme clusters describing an entry, timing first, then
``label: value`` per answered question, joined by ``" · "``.

This is the reference. The PWA (``src/lib/entrySummary.ts``) and the iOS app
(``QuickrCore/Entries/EntrySummary.swift``) port it and are pinned to the same text by
``shared/fixtures/entry-summary-vectors.json`` (``tests/test_entry_summary_vectors.py``).
"""

from __future__ import annotations

from collections.abc import Sequence
from decimal import ROUND_HALF_UP, Context, Decimal
from typing import Any

import regex

from app.schemas.api import (
    AnswerOut,
    DoubleAnswer,
    EnumAnswer,
    EnumListAnswer,
    IntAnswer,
    StrAnswer,
    Timing,
    TimingSegment,
)
from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, Question, StrQuestion, Timer
from app.services.run_fold import fmt_duration

MAX_SUMMARY_LENGTH = 80
SEPARATOR = " · "
ELLIPSIS = "…"
DEFAULT_DECIMALS = 3

# Wide enough for any double's digits (up to ~309 before the point) plus the fraction.
_DECIMAL = Context(prec=400, rounding=ROUND_HALF_UP)


def entry_summary(
    answers: Sequence[AnswerOut],
    timing: Timing | None,
    questions: Sequence[Question],
    timer: Timer | None,
) -> str:
    """§1.2: the timing part (if timed), then ``label: text`` for each of the entry's
    version's ``questions`` in their order (a key without a question is skipped, and so is
    an answer without text), joined by :data:`SEPARATOR` and truncated. ``""`` means
    "nothing to say"; callers show their own fallback."""
    parts: list[str] = []
    if timing is not None:
        parts.append(timing_summary(timing, timer))
    by_key = {a.key: a for a in answers}
    for q in questions:
        a = by_key.get(q.key)
        if a is None:
            continue
        text = answer_text(q, a)
        if text:
            parts.append(f"{q.label}: {text}")
    return truncate(SEPARATOR.join(parts))


def timing_summary(timing: Timing, timer: Timer | None) -> str:
    """``"12:40"``, ``"12:40 · 3 laps"`` or, with typed laps, ``"12:40 · Run 3 · Rest 3"``:
    the active duration, then the lap segments counted by type in the timer's declared
    order (then first seen), the untyped remainder last. Pauses, steps and skips are not
    shown."""
    text = fmt_duration(timing.active_ms)
    laps = [s for s in timing.segments if s.kind == "lap"]
    if not laps:
        return text
    typed = [t for t in (_lap_type(s) for s in laps) if t]
    if not typed:
        return f"{text}{SEPARATOR}{_laps(len(laps))}"
    labels = dict(_declared_lap_types(timer))
    keys = [k for k in labels if k in typed]
    keys += [k for k in dict.fromkeys(typed) if k not in labels]
    for k in keys:
        text += f"{SEPARATOR}{labels.get(k, k)} {typed.count(k)}"
    untyped = len(laps) - len(typed)
    if untyped:
        text += f"{SEPARATOR}{_laps(untyped)}"
    return text


def answer_text(question: Question, answer: AnswerOut) -> str | None:
    """One answer as display text, or None when there is nothing to show for it (an empty
    selection, a blank string, or an answer whose shape doesn't fit the question)."""
    match question, answer:
        case IntQuestion(), IntAnswer() | DoubleAnswer():
            return _with_unit(_number(answer.value, 0), question.unit)
        case DoubleQuestion(), IntAnswer() | DoubleAnswer():
            decimals = DEFAULT_DECIMALS if question.decimals is None else question.decimals
            return _with_unit(_number(answer.value, decimals), question.unit)
        case EnumQuestion(), EnumAnswer():
            return _option_label(question, answer.value)
        case EnumQuestion(), EnumListAnswer():
            # A single-select that became multi-select keeps its old answers and the other
            # way round, so an enum question takes both shapes.
            return ", ".join(_option_label(question, v) for v in answer.value) or None
        case StrQuestion(), StrAnswer():
            return " ".join(answer.value.split()) or None
        case _:
            return None


def graphemes(text: str) -> list[str]:
    """The extended grapheme clusters of ``text`` (UAX #29): the unit every client counts
    in (Swift ``Character``, JS ``Intl.Segmenter``)."""
    return regex.findall(r"\X", text)


def truncate(line: str) -> str:
    """Keep the first ``MAX_SUMMARY_LENGTH - 1`` clusters and append ``…`` when the line
    has more than :data:`MAX_SUMMARY_LENGTH`; no word boundary, and never inside a cluster
    (a flag, a keycap, a ZWJ sequence or a base with combining marks stays whole)."""
    clusters = graphemes(line)
    if len(clusters) <= MAX_SUMMARY_LENGTH:
        return line
    return "".join(clusters[: MAX_SUMMARY_LENGTH - 1]) + ELLIPSIS


def _number(value: int | float, decimals: int) -> str:
    """``value`` with at most ``decimals`` fraction digits, rounded half away from zero
    from its shortest round-trip decimal (what ``String(x)``/``repr`` print, and what
    ``Intl.NumberFormat`` rounds from), trailing zeros dropped, no thousands grouping."""
    if isinstance(value, int):
        return str(value)
    rounded = Decimal(repr(value)).quantize(Decimal(1).scaleb(-decimals), context=_DECIMAL)
    text = f"{rounded:f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


def _with_unit(text: str, unit: str | None) -> str:
    return f"{text} {unit}" if unit else text


def _option_label(question: EnumQuestion, value: str) -> str:
    return next((o.label for o in question.options if o.value == value), value)


def _laps(n: int) -> str:
    return f"{n} lap" if n == 1 else f"{n} laps"


# Lap types are M1's (timers2.md: `TimingSegment.lap_type`, `Timer.laps`). Until that
# stack lands the attributes don't exist, so they are read dynamically; M4-STATS turns
# these into plain attribute access when it adds the typed vectors.
def _lap_type(segment: TimingSegment) -> str | None:
    lap_type: str | None = getattr(segment, "lap_type", None)
    return lap_type


def _declared_lap_types(timer: Timer | None) -> list[tuple[str, str]]:
    """``(key, label)`` of the timer's lap types in declared order; empty when untimed."""
    laps: Sequence[Any] = getattr(timer, "laps", ()) if timer is not None else ()
    return [(lt.key, lt.label) for lt in laps]
