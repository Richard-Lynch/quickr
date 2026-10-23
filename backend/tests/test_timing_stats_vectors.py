"""Timing stats vectors: ``shared/fixtures/timing-stats-vectors.json``.

Generated from ``app/services/timing_stats.py`` (docs/specs/timers.md §9.1): a topic's
versions and entries in, its timing stats out. The PWA's and the iOS app's timing chart
models check their ports against these, and ``getTopicTiming`` (T-STATS) must answer the
same for the same entries. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file;
otherwise the committed file must match.
"""

from __future__ import annotations

from typing import Any

from app.services import run_fold, timing_stats
from app.services.run_fold import Pause, Step
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "timing-stats-vectors.json"
GENERATOR_VERSION = 2

T0 = run_fold.parse_instant("2026-10-01T07:00:00Z")
DAY = 24 * 60 * 60 * 1000

SHOWER = Step("shower", "Shower")
BREAKFAST = Step("breakfast", "Breakfast")
DRESS = Step("dress", "Get dressed")
ROUTINE = [SHOWER, BREAKFAST, DRESS]


def entry_id(n: int) -> str:
    return f"0d000000-0000-4000-8000-{n:012d}"


def run(
    n: int,
    parts: list[tuple[Step | None, float]],
    *,
    skipped: tuple[str, ...] = (),
    pauses: tuple[tuple[int, int], ...] = (),
    steps: list[Step] | None = None,
) -> dict[str, Any]:
    """Entry ``n``, started on day ``n`` at T0: ``parts`` are (step or lap, seconds long, to the ms);
    ``pauses`` are (seconds from the start, seconds long). ``steps`` are the run version's steps
    (by default the steps it timed and skipped, so it is complete unless it skipped one)."""
    if steps is None:
        steps = [s for s, _ in parts if s is not None] + [Step(k, k) for k in skipped]
    start = T0 + n * DAY
    ends: list[tuple[Step | None, int]] = []
    at = start
    for step, seconds in parts:
        at += round(seconds * 1000)
        ends.append((step, at))
    timing = run_fold.make_timing(
        start,
        ends,
        skipped,
        [Pause(start + s * 1000, start + (s + d) * 1000) for s, d in pauses],
        steps=steps,
    )
    run_fold.check_timing(timing)
    return {
        "entry_id": entry_id(n),
        "captured_at": run_fold.format_instant(timing.ended_at),
        "timing": run_fold.timing_json(timing),
    }


def untimed(n: int) -> dict[str, Any]:
    return {"entry_id": entry_id(n), "captured_at": run_fold.format_instant(T0 + n * DAY), "timing": None}


def steps_json(steps: list[Step] | None) -> list[dict[str, str]] | None:
    return None if steps is None else [{"key": s.key, "label": s.label} for s in steps]


ONE_VERSION: dict[int, list[Step] | None] = {1: ROUTINE}
NO_STEPS: dict[int, list[Step] | None] = {1: []}

# name -> (versions, current version, entries)
CASES: dict[str, tuple[dict[int, list[Step] | None], int, list[dict[str, Any]]]] = {
    "empty": (ONE_VERSION, 1, []),
    "one-run": (ONE_VERSION, 1, [run(1, [(SHOWER, 240), (BREAKFAST, 600), (DRESS, 180)])]),
    "odd-median": (
        NO_STEPS,
        1,
        [run(1, [(None, 300)]), run(2, [(None, 100)]), run(3, [(None, 200)])],
    ),
    "even-median-floors": (
        NO_STEPS,
        1,
        [run(1, [(None, 300)]), run(2, [(None, 101)]), run(3, [(None, 200)]), run(4, [(None, 400)])],
    ),
    "even-median-floors-milliseconds": (
        NO_STEPS,
        1,
        [run(1, [(None, 0.001)]), run(2, [(None, 0.002)])],
    ),
    "skipped-steps": (
        ONE_VERSION,
        1,
        [
            run(1, [(SHOWER, 240), (BREAKFAST, 600), (DRESS, 180)]),
            run(2, [(BREAKFAST, 500), (DRESS, 100)], skipped=("shower",)),
            run(3, [(SHOWER, 200), (BREAKFAST, 700), (DRESS, 200)]),
            run(4, [(SHOWER, 300), (DRESS, 90)], skipped=("breakfast",)),
        ],
    ),
    "stopped-before-the-last-step": (
        ONE_VERSION,
        1,
        [
            run(1, [(SHOWER, 240), (BREAKFAST, 600)], steps=ROUTINE),
            run(2, [(SHOWER, 300), (BREAKFAST, 700), (DRESS, 100)], steps=ROUTINE),
        ],
    ),
    "all-runs-incomplete": (
        ONE_VERSION,
        1,
        [run(1, [(BREAKFAST, 500), (DRESS, 100)], skipped=("shower",))],
    ),
    "laps": (
        ONE_VERSION,
        1,
        [
            run(1, [(SHOWER, 240), (None, 30), (BREAKFAST, 600), (DRESS, 180), (None, 45)]),
            run(2, [(SHOWER, 200), (BREAKFAST, 500), (DRESS, 100)]),
            run(3, [(SHOWER, 210), (BREAKFAST, 520), (None, 10), (DRESS, 120)]),
        ],
    ),
    "pauses": (
        NO_STEPS,
        1,
        [
            run(1, [(None, 600)], pauses=((60, 120),)),
            run(2, [(None, 100), (None, 500)], pauses=((50, 100), (300, 7))),
            run(3, [(None, 400)]),
            run(4, [(None, 50)], pauses=((10, 0),)),
        ],
    ),
    "renamed-and-removed-steps": (
        {
            1: [Step("shower", "Shower"), Step("brekkie", "Brekkie"), Step("teeth", "Teeth")],
            2: [Step("brekkie", "Breakfast"), Step("shower", "Wash")],
            3: [Step("shower", "Wash"), Step("brekkie", "Breakfast")],
        },
        3,
        [
            run(
                1,
                [
                    (Step("shower", "Shower"), 240),
                    (Step("brekkie", "Brekkie"), 600),
                    (Step("teeth", "Teeth"), 90),
                ],
            ),
            run(2, [(Step("brekkie", "Breakfast"), 550), (Step("shower", "Wash"), 250)]),
            run(3, [(Step("shower", "Wash"), 230)], skipped=("brekkie",)),
            run(4, [(Step("ghost", "Gone"), 30)]),
        ],
    ),
    "versions-sort-as-numbers": (
        {2: [Step("shower", "Old label")], 10: [Step("shower", "New label")]},
        10,
        [run(1, [(Step("shower", "Old label"), 60)])],
    ),
    "timing-turned-off": (
        {1: ROUTINE, 2: None},
        2,
        [run(1, [(SHOWER, 240), (BREAKFAST, 600), (DRESS, 180)])],
    ),
    "untimed-entries-ignored": (
        NO_STEPS,
        1,
        [untimed(1), run(2, [(None, 100)]), untimed(3), run(4, [(None, 300)])],
    ),
    "series-order-by-captured-at": (
        NO_STEPS,
        1,
        [run(5, [(None, 100)]), run(2, [(None, 300)]), run(3, [(None, 200)])],
    ),
}


def to_entry(d: dict[str, Any]) -> timing_stats.TimedEntry:
    return timing_stats.TimedEntry(
        entry_id=d["entry_id"],
        captured_at=run_fold.parse_instant(d["captured_at"]),
        timing=None if d["timing"] is None else run_fold.timing_from_json(d["timing"]),
    )


def stats_json(t: timing_stats.TopicTiming) -> dict[str, Any]:
    return {
        "runs": t.runs,
        "complete_runs": t.complete_runs,
        "total": {"best_ms": t.total.best_ms, "median_ms": t.total.median_ms, "mean_ms": t.total.mean_ms},
        "steps": [
            {
                "key": s.key,
                "label": s.label,
                "current": s.current,
                "done": s.done,
                "skipped": s.skipped,
                "best_ms": s.best_ms,
                "median_ms": s.median_ms,
                "mean_ms": s.mean_ms,
            }
            for s in t.steps
        ],
        "laps": {
            "runs_with_laps": t.laps.runs_with_laps,
            "median_ms": t.laps.median_ms,
            "mean_ms": t.laps.mean_ms,
        },
        "paused": {"runs_with_pauses": t.paused.runs_with_pauses, "median_ms": t.paused.median_ms},
        "series": [
            {
                "entry_id": p.entry_id,
                "captured_at": run_fold.format_instant(p.captured_at),
                "started_at": run_fold.format_instant(p.started_at),
                "active_ms": p.active_ms,
                "paused_ms": p.paused_ms,
                "complete": p.complete,
                "steps": dict(p.steps),
            }
            for p in t.series
        ],
    }


def compute(name: str) -> timing_stats.TopicTiming:
    versions, current, entries = CASES[name]
    return timing_stats.timing_stats([to_entry(e) for e in entries], versions, current)


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_timing_stats_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "semantics": [
                "docs/specs/timers.md §9.1. Durations are integer milliseconds of active time. Entries "
                "with timing null are ignored entirely.",
                "complete = timing.complete (the version has no steps, or every step has a segment and none "
                "was skipped; computed when the timing is made). total.best_ms, "
                "median_ms and mean_ms are over complete runs' active_ms only; null when there are none.",
                "median: the middle value of the sorted values, or floor((a + b) / 2) of the two middle "
                "ones. mean: floor(sum / n).",
                "versions keys are version numbers as strings: order them as numbers. "
                "steps: every key seen in range (a segment's step, or in skipped); the current version's "
                "keys first in its step order, then the rest by key (code point order). done = runs with "
                "a segment for the key, skipped = runs that skipped it; best, median and mean over the "
                "done segments' active_ms, from every run (complete or not). label: the key's label in "
                "the latest version that has it, else its latest segment's label. current: the key is in "
                "the current version (versions[current_version], null when timing is off).",
                "laps: per run, lap_ms = sum of its lap segments' active_ms; runs_with_laps, median and "
                "mean over the runs with at least one lap segment.",
                "paused: runs_with_pauses = runs with paused_ms > 0 (a zero-length pause doesn't count); "
                "median of their paused_ms.",
                "series: one point per timed entry, by (captured_at, entry_id); steps maps each step "
                "segment's key to its active_ms.",
            ],
        },
        "cases": [
            {
                "name": name,
                "versions": {str(n): steps_json(s) for n, s in versions.items()},
                "current_version": current,
                "entries": entries,
                "expected": stats_json(compute(name)),
            }
            for name, (versions, current, entries) in CASES.items()
        ],
    }


def test_timing_stats_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_spec() -> None:
    """timers.md §13.1: empty; one run; even and odd medians; skipped steps; laps; pauses;
    renamed and removed steps across versions; untimed entries ignored."""
    empty = compute("empty")
    assert (empty.runs, empty.total.best_ms, empty.steps, empty.series) == (0, None, (), ())
    assert compute("one-run").total.median_ms == 1020_000
    assert compute("odd-median").total.median_ms == 200_000
    assert compute("even-median-floors").total.median_ms == 250_000
    assert compute("even-median-floors-milliseconds").total.median_ms == 1
    assert compute("even-median-floors").total.mean_ms == 250_250
    skipped = compute("skipped-steps")
    assert (skipped.runs, skipped.complete_runs, skipped.total.best_ms) == (4, 2, 1020_000)
    assert {s.key: (s.done, s.skipped) for s in skipped.steps} == {
        "shower": (3, 1),
        "breakfast": (3, 1),
        "dress": (4, 0),
    }
    assert compute("all-runs-incomplete").total.best_ms is None
    laps = compute("laps").laps
    assert (laps.runs_with_laps, laps.median_ms, laps.mean_ms) == (2, 42_500, 42_500)
    paused = compute("pauses").paused
    assert (paused.runs_with_pauses, paused.median_ms) == (2, 113_500)
    stopped_early = compute("stopped-before-the-last-step")
    assert (stopped_early.complete_runs, stopped_early.total.best_ms) == (1, 1100_000)
    assert compute("versions-sort-as-numbers").steps[0].label == "New label"
    renamed = compute("renamed-and-removed-steps").steps
    assert [(s.key, s.label, s.current) for s in renamed] == [
        ("shower", "Wash", True),
        ("brekkie", "Breakfast", True),
        ("ghost", "Gone", False),
        ("teeth", "Teeth", False),
    ]
    assert [s.current for s in compute("timing-turned-off").steps] == [False, False, False]
    assert compute("untimed-entries-ignored").runs == 2
    assert [p.entry_id for p in compute("series-order-by-captured-at").series] == [
        entry_id(2),
        entry_id(3),
        entry_id(5),
    ]
