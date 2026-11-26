"""Timing stats vectors: ``shared/fixtures/timing-stats-vectors.json``.

Generated from ``app/services/timing_stats.py`` (docs/specs/timers.md §9.1, timers2.md §7.4):
a topic's versions (each one's timer: steps and lap types) and entries in, its timing stats
out. The PWA's and the iOS app's timing chart
models check their ports against these, and ``getTopicTiming`` (T-STATS) must answer the
same for the same entries. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file;
otherwise the committed file must match.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from app.schemas.questions import Timer as Timer_v2
from app.services import run_fold, timing_stats
from app.services.run_fold import LapType, Pause, Step, Timer
from tests.spec_cases import timing_stats_v3_cases
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "timing-stats-vectors.json"
GENERATOR_VERSION = 3

T0 = run_fold.parse_instant("2026-10-01T07:00:00Z")
DAY = 24 * 60 * 60 * 1000

SHOWER = Step("shower", "Shower")
BREAKFAST = Step("breakfast", "Breakfast")
DRESS = Step("dress", "Get dressed")
ROUTINE = [SHOWER, BREAKFAST, DRESS]
CIG = LapType("cig", "Cig")
RUN, REST = LapType("run", "Run"), LapType("rest", "Rest")


def entry_id(n: int) -> str:
    return f"0d000000-0000-4000-8000-{n:012d}"


def run(
    n: int,
    parts: list[tuple[Step | None, float]],
    *,
    skipped: tuple[str, ...] = (),
    pauses: tuple[tuple[int, int], ...] = (),
    steps: list[Step] | None = None,
    laps: Sequence[LapType] = (),
) -> dict[str, Any]:
    """Entry ``n``, started on day ``n`` at T0: ``parts`` are (step or lap, seconds long, to the ms);
    ``pauses`` are (seconds from the start, seconds long). ``steps`` are the run version's steps
    (by default the steps it timed and skipped, so it is complete unless it skipped one);
    ``laps`` its lap types, which type and label its laps (timers2.md §3.2)."""
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
        timer=Timer(steps, laps),
    )
    run_fold.check_timing(timing)
    return {
        "entry_id": entry_id(n),
        "captured_at": run_fold.format_instant(timing.ended_at),
        "timing": run_fold.timing_json(timing),
    }


def untimed(n: int) -> dict[str, Any]:
    return {"entry_id": entry_id(n), "captured_at": run_fold.format_instant(T0 + n * DAY), "timing": None}


def timer_json(timer: Timer | None) -> dict[str, Any] | None:
    """A version's timer as a topic version serves it: the normalised ``Timer`` v2 output."""
    if timer is None:
        return None
    sent = {
        "steps": [{"key": s.key, "label": s.label} for s in timer.steps],
        "laps": [{"key": t.key, "label": t.label} for t in timer.laps],
    }
    out: dict[str, Any] = Timer_v2.model_validate(sent).model_dump(mode="json")
    return out


def to_timer(d: dict[str, Any] | None) -> Timer | None:
    if d is None:
        return None
    return Timer(
        steps=[Step(s["key"], s["label"]) for s in d["steps"]],
        laps=[LapType(t["key"], t["label"]) for t in d["laps"]],
    )


def steps_only(**versions: list[Step] | None) -> dict[int, Timer | None]:
    return {int(n[1:]): None if s is None else Timer(s) for n, s in versions.items()}


ONE_VERSION = steps_only(v1=ROUTINE)
NO_STEPS = steps_only(v1=[])
RENAMED = Timer(laps=(CIG,))
TIKTOK = Timer(laps=(RUN, REST))

# name -> (versions, current version, entries)
CASES: dict[str, tuple[dict[int, Timer | None], int, list[dict[str, Any]]]] = {
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
        steps_only(
            v1=[Step("shower", "Shower"), Step("brekkie", "Brekkie"), Step("teeth", "Teeth")],
            v2=[Step("brekkie", "Breakfast"), Step("shower", "Wash")],
            v3=[Step("shower", "Wash"), Step("brekkie", "Breakfast")],
        ),
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
        steps_only(v2=[Step("shower", "Old label")], v10=[Step("shower", "New label")]),
        10,
        [run(1, [(Step("shower", "Old label"), 60)])],
    ),
    "timing-turned-off": (
        steps_only(v1=ROUTINE, v2=None),
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
    "series-tie-on-captured-at-by-entry-id": (
        NO_STEPS,
        1,
        # Both end at day 3 + 100 s; listed with the higher id first.
        [run(3, [(None, 100)]), run(2, [(None, 24 * 60 * 60 + 100)])],
    ),
    # timers2.md §7.4: lap types
    "lap_types_one": (
        {1: RENAMED},
        1,
        [
            run(1, [(None, 30), (None, 50), (None, 40)], laps=RENAMED.laps),
            run(2, [(None, 20)], laps=RENAMED.laps),
        ],
    ),
    "lap_types_cycle": (
        {1: TIKTOK},
        1,
        [
            run(1, [(None, 60), (None, 20), (None, 70), (None, 25), (None, 65)], laps=TIKTOK.laps),
            run(2, [(None, 55), (None, 30)], laps=TIKTOK.laps, pauses=((10, 5),)),
        ],
    ),
    "lap_types_renamed_across_versions": (
        {
            1: Timer(laps=(LapType("cig", "Ciggie"), LapType("vape", "Vape"))),
            2: Timer(laps=(LapType("cig", "Cig"),)),
            3: Timer(laps=(LapType("puff", "Puff"), LapType("cig", "Cigarette"))),
        },
        3,
        [
            run(1, [(None, 10), (None, 20)], laps=(LapType("cig", "Ciggie"), LapType("vape", "Vape"))),
            run(2, [(None, 15)], laps=(LapType("cig", "Cig"),)),
            run(3, [(None, 5), (None, 25)], laps=(LapType("puff", "Puff"), LapType("cig", "Cigarette"))),
        ],
    ),
    "lap_types_untyped_mixed": (
        {1: Timer(), 2: Timer(steps=(SHOWER,), laps=(LapType("shower_lap", "Rinse"),)), 3: TIKTOK},
        3,
        [
            run(1, [(None, 40), (None, 50)]),  # untyped laps: only the v1 `laps` bucket
            run(2, [(SHOWER, 200), (None, 30)], laps=(LapType("shower_lap", "Rinse"),)),
            run(3, [(None, 60), (None, 10)], laps=TIKTOK.laps),
        ],
    ),
    "lap_types_in_series": (
        {1: TIKTOK, 2: Timer(steps=(Step("run", "Run step"),))},
        2,
        [
            run(1, [(None, 60), (None, 20), (None, 70)], laps=TIKTOK.laps),
            # A step whose key equals a lap type's: keyed separately (timers2.md §7.4).
            run(2, [(Step("run", "Run step"), 90), (None, 15)]),
            run(3, [(None, 45), (None, 35)], laps=TIKTOK.laps),
        ],
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
        "lap_types": [
            {
                "key": lt.key,
                "label": lt.label,
                "laps": lt.laps,
                "best_ms": lt.best_ms,
                "median_ms": lt.median_ms,
                "mean_ms": lt.mean_ms,
            }
            for lt in t.lap_types
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
                "lap_types": dict(p.lap_types),
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
                "docs/specs/timers.md §9.1 and timers2.md §7.4 (lap types). Durations are integer "
                "milliseconds of active time. Entries "
                "with timing null are ignored entirely.",
                "complete = timing.complete (the version has no steps, or every step has a segment and none "
                "was skipped; computed when the timing is made). total.best_ms, "
                "median_ms and mean_ms are over complete runs' active_ms only; null when there are none.",
                "median: the middle value of the sorted values, or floor((a + b) / 2) of the two middle "
                "ones. mean: floor(sum / n).",
                "versions keys are version numbers as strings: order them as numbers; each value is "
                "that version's timer (a normalised Timer v2), or null when timing is off. "
                "steps: every key seen in range (a segment's step, or in skipped); the current version's "
                "keys first in its step order, then the rest by key (code point order). done = runs with "
                "a segment for the key, skipped = runs that skipped it; best, median and mean over the "
                "done segments' active_ms, from every run (complete or not). label: the key's label in "
                "the latest version that has it, else its latest segment's label. current: the key is in "
                "the current version (versions[current_version], null when timing is off).",
                "lap_types: one row per lap-type key with a lap segment in range (segment.lap_type), the "
                "current version's lap types first in its order, then the rest by key; label from the "
                "latest version that has the key; laps = the count of its lap segments over every timed "
                "run; best, median and mean over those segments' active_ms. Untyped laps (lap_type null) "
                "count only toward `laps`. Lap-type and step buckets are keyed separately: a lap type "
                "whose key equals a step's never joins that step's row, nor the other way round.",
                "laps: per run, lap_ms = sum of its lap segments' active_ms; runs_with_laps, median and "
                "mean over the runs with at least one lap segment.",
                "paused: runs_with_pauses = runs with paused_ms > 0 (a zero-length pause doesn't count); "
                "median of their paused_ms.",
                "series: one point per timed entry, by (captured_at, entry_id); steps maps each step "
                "segment's key to its active_ms; lap_types maps each lap type to the sum of its lap "
                "segments' "
                "active_ms in that run (untyped laps left out).",
            ],
        },
        "cases": [
            {
                "name": name,
                "versions": {str(n): timer_json(t) for n, t in versions.items()},
                "current_version": current,
                "entries": entries,
                "expected": stats_json(compute(name)),
            }
            for name, (versions, current, entries) in CASES.items()
        ],
    }


def test_timing_stats_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_timers2() -> None:
    """timers2.md §7.4: every v3 case the spec names is present (the list is read from the
    spec) and the generator is at version 3."""
    built = build()
    names = {c["name"] for c in built["cases"]}
    missing = [name for name in timing_stats_v3_cases() if name not in names]
    assert not missing, missing
    assert built["meta"]["generator_version"] == 3


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
    tie = compute("series-tie-on-captured-at-by-entry-id").series
    assert tie[0].captured_at == tie[1].captured_at
    assert [p.entry_id for p in tie] == [entry_id(2), entry_id(3)]


def test_v3_vectors_do_what_their_names_say() -> None:
    """timers2.md §7.4, one assert group per case."""

    def rows(name: str) -> list[tuple[str, str, int, int | None, int | None, int | None]]:
        return [(t.key, t.label, t.laps, t.best_ms, t.median_ms, t.mean_ms) for t in compute(name).lap_types]

    assert rows("lap_types_one") == [("cig", "Cig", 4, 20_000, 35_000, 35_000)]
    assert compute("lap_types_one").laps.runs_with_laps == 2  # the v1 bucket is unchanged
    assert rows("lap_types_cycle") == [
        ("run", "Run", 4, 50_000, 62_500, 61_250),  # active time: run 2's first lap was paused 5 s
        ("rest", "Rest", 3, 20_000, 25_000, 25_000),
    ]
    assert [(k, label, n) for k, label, n, *_ in rows("lap_types_renamed_across_versions")] == [
        ("puff", "Puff", 1),  # the current version's types first
        ("cig", "Cigarette", 3),  # its label from the latest version that has it
        ("vape", "Vape", 1),  # then historic ones by key
    ]
    mixed = compute("lap_types_untyped_mixed")
    assert [t.key for t in mixed.lap_types] == ["run", "rest", "shower_lap"]
    assert sum(t.laps for t in mixed.lap_types) == 3  # run 1's two untyped laps are not in a type
    assert mixed.laps.runs_with_laps == 3
    series = compute("lap_types_in_series")
    assert [(dict(p.steps), dict(p.lap_types)) for p in series.series] == [
        ({}, {"run": 130_000, "rest": 20_000}),
        ({"run": 90_000}, {}),
        ({}, {"run": 45_000, "rest": 35_000}),
    ]
    assert [(s.key, s.label, s.done) for s in series.steps] == [("run", "Run step", 1)]  # keyed separately
    assert [(t.key, t.laps) for t in series.lap_types] == [("rest", 2), ("run", 3)]
