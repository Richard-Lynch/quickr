"""Timing stats (docs/specs/timers.md §9.1): one test per rule. The vector cases in
``test_timing_stats_vectors.py`` pin the same rules for the ports."""

from __future__ import annotations

from app.services import run_fold, timing_stats
from app.services.run_fold import Pause, Step
from app.services.timing_stats import TimedEntry

A, B = Step("a", "Alpha"), Step("b", "Beta")
S = 1000


def entry(
    n: int,
    parts: list[tuple[Step | None, int]],
    skipped: tuple[str, ...] = (),
    pauses: int | None = None,
    steps: list[Step] | None = None,
) -> TimedEntry:
    """Entry ``n`` starting at n hours; ``parts`` are (step or lap, seconds); one pause of
    ``pauses`` seconds at the start. ``steps`` are the version's (by default the ones timed or
    skipped)."""
    if steps is None:
        steps = [s for s, _ in parts if s is not None] + [Step(k, k) for k in skipped]
    start = n * 3600 * S
    ends, at = [], start
    for step, seconds in parts:
        at += seconds * S
        ends.append((step, at))
    t = run_fold.make_timing(
        start, ends, skipped, [] if pauses is None else [Pause(start, start + pauses * S)], steps=steps
    )
    return TimedEntry(entry_id=f"e{n}", captured_at=t.ended_at, timing=t)


def stats(*entries: TimedEntry, steps: list[Step] | None = None) -> timing_stats.TopicTiming:
    return timing_stats.timing_stats(entries, {1: [A, B] if steps is None else steps}, 1)


def test_median_takes_the_middle_or_floors_the_two_middle_values() -> None:
    assert timing_stats.median([]) is None
    assert timing_stats.median([5, 1, 3]) == 3
    assert timing_stats.median([4, 1, 2, 9]) == 3  # floor((2 + 4) / 2)
    assert timing_stats.median([1, 2]) == 1  # floor(1.5)


def test_mean_floors() -> None:
    assert timing_stats.mean([]) is None
    assert timing_stats.mean([1, 2]) == 1
    assert timing_stats.mean([3, 3, 4]) == 3


def test_best_median_and_mean_count_complete_runs_only() -> None:
    result = stats(entry(1, [(A, 10), (B, 10)]), entry(2, [(B, 5)], skipped=("a",)))
    assert (result.runs, result.complete_runs) == (2, 1)
    assert result.total == timing_stats.Summary(best_ms=20 * S, median_ms=20 * S, mean_ms=20 * S)


def test_a_run_stopped_before_its_last_step_is_not_complete() -> None:
    result = stats(entry(1, [(A, 10)], steps=[A, B]), entry(2, [(A, 10), (B, 10)], steps=[A, B]))
    assert result.complete_runs == 1
    assert result.total.best_ms == 20 * S


def test_versions_order_as_numbers() -> None:
    t = run_fold.make_timing(0, [(A, S)], (), [], steps=[A])
    result = timing_stats.timing_stats([TimedEntry("e", S, t)], {2: [A], 10: [Step("a", "Ten")]}, 10)
    assert result.steps[0].label == "Ten"


def test_runs_without_steps_are_complete() -> None:
    result = stats(entry(1, [(None, 7)]), steps=[])
    assert result.complete_runs == 1
    assert result.total.best_ms == 7 * S


def test_per_step_stats_use_every_run() -> None:
    result = stats(entry(1, [(A, 10), (B, 30)]), entry(2, [(A, 20)], skipped=("b",)))
    alpha, beta = result.steps
    assert (alpha.done, alpha.skipped, alpha.best_ms, alpha.median_ms) == (2, 0, 10 * S, 15 * S)
    assert (beta.done, beta.skipped, beta.best_ms) == (1, 1, 30 * S)


def test_only_keys_seen_in_range_are_listed() -> None:
    assert [s.key for s in stats(entry(1, [(B, 5)])).steps] == ["b"]


def test_laps_are_never_a_step_and_sum_per_run() -> None:
    result = stats(entry(1, [(A, 10), (None, 3), (None, 4)]), entry(2, [(A, 10)]))
    assert result.laps == timing_stats.LapStats(runs_with_laps=1, median_ms=7 * S, mean_ms=7 * S)
    assert result.steps[0].best_ms == 10 * S


def test_paused_time_is_reported_apart_and_excluded_from_durations() -> None:
    result = stats(entry(1, [(A, 10)], pauses=4), entry(2, [(A, 10)]))
    assert result.paused == timing_stats.PausedStats(runs_with_pauses=1, median_ms=4 * S)
    assert result.total.best_ms == 6 * S
    zero = stats(entry(1, [(A, 10)], pauses=0))
    assert zero.paused == timing_stats.PausedStats(runs_with_pauses=0, median_ms=None)


def test_untimed_entries_count_toward_nothing() -> None:
    result = stats(TimedEntry("u", 0, None), entry(1, [(A, 1)]))
    assert result.runs == 1
    assert [p.entry_id for p in result.series] == ["e1"]


def test_series_points_are_by_end_with_step_times() -> None:
    result = stats(entry(2, [(A, 1), (B, 2)]), entry(1, [(None, 5)]))
    assert [p.entry_id for p in result.series] == ["e1", "e2"]
    assert result.series[1].steps == {"a": 1 * S, "b": 2 * S}


def test_labels_come_from_the_latest_version_with_the_key() -> None:
    versions: dict[int, list[Step] | None] = {
        1: [Step("a", "Old"), Step("z", "Zed")],
        2: [Step("a", "New")],
        3: None,
    }
    old_steps = [Step("a", "Old"), Step("z", "Zed")]
    old = run_fold.make_timing(0, [(old_steps[0], S), (old_steps[1], 2 * S)], (), [], steps=old_steps)
    result = timing_stats.timing_stats([TimedEntry("e", old.ended_at, old)], versions, 2)
    assert [(s.key, s.label, s.current) for s in result.steps] == [("a", "New", True), ("z", "Zed", False)]
