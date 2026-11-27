"""Timing stats v3 (docs/specs/timers2.md §7.4): ``lap_types[]`` and ``SeriesPoint.lap_types``,
one test per rule. ``test_timing_stats.py`` keeps the v1 rules (timers.md §9.1)."""

from __future__ import annotations

from app.services import run_fold, timing_stats
from app.services.run_fold import LapType, Pause, Step, Timer
from app.services.timing_stats import LapTypeStats, TimedEntry

S = 1000
A, B = Step("a", "Alpha"), Step("b", "Beta")
CIG = LapType("cig", "Cig")
RUN_, REST = LapType("run", "Run"), LapType("rest", "Rest")
UNTYPED = Timer()
RENAMED = Timer(laps=(CIG,))
TIKTOK = Timer(laps=(RUN_, REST))


def entry(
    n: int, parts: list[tuple[Step | None, int]], timer: Timer, pauses: int | None = None
) -> TimedEntry:
    """Entry ``n`` starting at n hours on ``timer``; ``parts`` are (step or lap, seconds), laps
    typed by their ordinal (§3.2); one pause of ``pauses`` seconds at the start."""
    start = n * 3600 * S
    ends, at = [], start
    for step, seconds in parts:
        at += seconds * S
        ends.append((step, at))
    t = run_fold.make_timing(
        start, ends, (), [] if pauses is None else [Pause(start, start + pauses * S)], timer=timer
    )
    return TimedEntry(entry_id=f"e{n}", captured_at=t.ended_at, timing=t)


def stats(
    *entries: TimedEntry, versions: dict[int, Timer | None] | None = None, current: int = 1
) -> timing_stats.TopicTiming:
    return timing_stats.timing_stats(entries, versions or {1: TIKTOK}, current)


def test_one_lap_type_counts_and_summarises_its_segments() -> None:
    result = stats(
        entry(1, [(None, 10), (None, 30)], RENAMED), entry(2, [(None, 20)], RENAMED), versions={1: RENAMED}
    )
    assert result.lap_types == (
        LapTypeStats(key="cig", label="Cig", laps=3, best_ms=10 * S, median_ms=20 * S, mean_ms=20 * S),
    )
    # The v1 bucket is unchanged: per run, the sum of its lap segments.
    assert result.laps == timing_stats.LapStats(runs_with_laps=2, median_ms=30 * S, mean_ms=30 * S)


def test_lap_types_in_a_cycle_are_separate_buckets_in_the_versions_order() -> None:
    result = stats(entry(1, [(None, 10), (None, 4), (None, 12), (None, 6)], TIKTOK))
    assert [(t.key, t.label, t.laps, t.best_ms, t.median_ms, t.mean_ms) for t in result.lap_types] == [
        ("run", "Run", 2, 10 * S, 11 * S, 11 * S),
        ("rest", "Rest", 2, 4 * S, 5 * S, 5 * S),
    ]
    assert result.series[0].lap_types == {"run": 22 * S, "rest": 10 * S}


def test_labels_come_from_the_latest_version_with_the_key_and_historic_types_follow_by_key() -> None:
    v1 = Timer(laps=(LapType("cig", "Ciggie"), LapType("zz", "Last")))
    v2 = Timer(laps=(LapType("puff", "Puff"), LapType("cig", "Cig")))
    v3 = Timer(laps=(LapType("puff", "Puff"),))
    result = stats(
        entry(1, [(None, 10), (None, 20)], v1),
        entry(2, [(None, 30), (None, 40)], v2),
        entry(3, [(None, 50)], v3),
        versions={1: v1, 2: v2, 3: v3},
        current=3,
    )
    assert [(t.key, t.label, t.laps) for t in result.lap_types] == [
        ("puff", "Puff", 2),  # the current version's types first
        ("cig", "Cig", 2),  # then historic ones by key, labelled by the latest version that has them
        ("zz", "Last", 1),
    ]


def test_untyped_laps_contribute_only_to_laps() -> None:
    result = stats(
        entry(1, [(None, 10)], UNTYPED),
        entry(2, [(None, 20)], TIKTOK),
        versions={1: UNTYPED, 2: TIKTOK},
        current=2,
    )
    assert result.laps.runs_with_laps == 2
    assert [(t.key, t.laps) for t in result.lap_types] == [("run", 1)]
    assert [p.lap_types for p in result.series] == [{}, {"run": 20 * S}]


def test_a_topic_without_lap_types_answers_an_empty_list() -> None:
    result = stats(entry(1, [(A, 10), (None, 5)], Timer(steps=(A,))), versions={1: Timer(steps=(A,))})
    assert result.lap_types == ()
    assert result.series[0].lap_types == {}
    assert result.series[0].steps == {"a": 10 * S}


def test_lap_type_and_step_buckets_are_keyed_separately() -> None:
    old = Timer(steps=(Step("run", "Run step"),))
    new = Timer(laps=(LapType("run", "Run"),))
    result = stats(
        entry(1, [(Step("run", "Run step"), 10)], old),
        entry(2, [(None, 20), (None, 30)], new),
        versions={1: old, 2: new},
        current=2,
    )
    assert [(s.key, s.label, s.done, s.best_ms, s.current) for s in result.steps] == [
        ("run", "Run step", 1, 10 * S, False)
    ]
    assert [(t.key, t.label, t.laps, t.best_ms) for t in result.lap_types] == [("run", "Run", 2, 20 * S)]
    assert [(p.steps, p.lap_types) for p in result.series] == [({"run": 10 * S}, {}), ({}, {"run": 50 * S})]


def test_lap_type_durations_are_active_time() -> None:
    result = stats(entry(1, [(None, 10), (None, 20)], TIKTOK, pauses=4))
    assert [(t.key, t.best_ms) for t in result.lap_types] == [("run", 6 * S), ("rest", 20 * S)]
    assert result.series[0].lap_types == {"run": 6 * S, "rest": 20 * S}


def test_only_lap_types_seen_in_range_are_listed() -> None:
    result = stats(entry(1, [(None, 10)], TIKTOK))  # one lap: Run 1 only
    assert [t.key for t in result.lap_types] == ["run"]


def test_timing_turned_off_keeps_historic_lap_types() -> None:
    result = stats(entry(1, [(None, 10)], RENAMED), versions={1: RENAMED, 2: None}, current=2)
    assert [(t.key, t.label) for t in result.lap_types] == [("cig", "Cig")]
