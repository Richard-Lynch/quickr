"""Duration format vectors: ``shared/fixtures/duration-format-vectors.json``.

Generated from :func:`app.services.run_fold.fmt_duration` (docs/specs/timers.md §11.1):
how every client shows a duration. The PWA and the iOS app (``fmtDuration``) must print the
same text for the same milliseconds. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites
the file; otherwise the committed file must match.
"""

from __future__ import annotations

from typing import Any

from app.services.run_fold import fmt_duration
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "duration-format-vectors.json"
GENERATOR_VERSION = 1

# name -> milliseconds
CASES: dict[str, int] = {
    "zero": 0,
    "just-under-a-second": 999,
    "one-second": 1000,
    "just-under-a-minute": 59_999,
    "one-minute": 60_000,
    "seven-forty-two": 462_000,
    "ten-minutes": 600_000,
    "just-under-an-hour": 3_599_999,
    "one-hour": 3_600_000,
    "one-hour-one-second": 3_601_000,
    "ten-hours": 36_000_000,
    "one-day": 86_400_000,
    "seven-days": 604_800_000,
    "negative-one": -1,
    "negative-minute": -60_000,
}


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_duration_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "semantics": [
                "fmtDuration(ms): s = floor(max(0, ms) / 1000) (truncated, never rounded); below one hour "
                "'m:ss', from one hour 'h:mm:ss' with unbounded hours; minutes and seconds two digits "
                "after the first field. docs/specs/timers.md §11.1.",
            ],
        },
        "cases": [{"name": name, "ms": ms, "expected": fmt_duration(ms)} for name, ms in CASES.items()],
    }


def test_duration_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_spec() -> None:
    """timers.md §13.1: 0, 999, 1000, 59 999, 60 000, 3 599 999, 3 600 000, 86 400 000, negative."""
    got = {ms: fmt_duration(ms) for ms in CASES.values()}
    assert got[0] == got[999] == got[-1] == got[-60_000] == "0:00"
    assert got[1000] == "0:01"
    assert got[59_999] == "0:59"
    assert got[60_000] == "1:00"
    assert got[462_000] == "7:42"
    assert got[3_599_999] == "59:59"
    assert got[3_600_000] == "1:00:00"
    assert got[86_400_000] == "24:00:00"
    assert got[604_800_000] == "168:00:00"
