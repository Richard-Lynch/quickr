"""Timing stats: best, median and mean run times, per step, laps and pauses.

Pure functions (no DB, no clock) over a topic's timed entries, mirrored by the PWA's and
the iOS app's timing chart models: ``shared/fixtures/timing-stats-vectors.json``
(generated from this module) is the contract. The rules are docs/specs/timers.md §9.1;
``getTopicTiming`` (§9.2) serves :func:`timing_stats` over the entries in its range.

Every duration is active time (paused time excluded) in integer milliseconds. Best, median
and mean of run totals count **complete** runs only (no step skipped; a run of a version
without steps is always complete). Per-step stats, laps, pauses and the series count every
timed run. Untimed entries (``timing`` None) count toward nothing here.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from app.services.run_fold import Step, Timing


@dataclass(frozen=True, slots=True)
class TimedEntry:
    entry_id: str
    captured_at: int  # epoch milliseconds
    timing: Timing | None


@dataclass(frozen=True, slots=True)
class Summary:
    best_ms: int | None
    median_ms: int | None
    mean_ms: int | None


@dataclass(frozen=True, slots=True)
class StepStats:
    key: str
    label: str
    current: bool
    done: int
    skipped: int
    best_ms: int | None
    median_ms: int | None
    mean_ms: int | None


@dataclass(frozen=True, slots=True)
class LapStats:
    runs_with_laps: int
    median_ms: int | None
    mean_ms: int | None


@dataclass(frozen=True, slots=True)
class PausedStats:
    runs_with_pauses: int
    median_ms: int | None


@dataclass(frozen=True, slots=True)
class SeriesPoint:
    entry_id: str
    captured_at: int
    started_at: int
    active_ms: int
    paused_ms: int
    complete: bool
    steps: Mapping[str, int]


@dataclass(frozen=True, slots=True)
class TopicTiming:
    runs: int
    complete_runs: int
    total: Summary
    steps: tuple[StepStats, ...]
    laps: LapStats
    paused: PausedStats
    series: tuple[SeriesPoint, ...]


def median(values: Sequence[int]) -> int | None:
    """The middle value; ``floor((a + b) / 2)`` of the two middle ones for an even count."""
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) // 2


def mean(values: Sequence[int]) -> int | None:
    """``floor(sum / n)``."""
    return sum(values) // len(values) if values else None


def summary(values: Sequence[int]) -> Summary:
    return Summary(best_ms=min(values, default=None), median_ms=median(values), mean_ms=mean(values))


def step_labels(versions: Mapping[int, Sequence[Step] | None]) -> dict[str, str]:
    """Each step key's label in the latest version that has it."""
    labels: dict[str, str] = {}
    for number in sorted(versions):
        for step in versions[number] or ():
            labels[step.key] = step.label
    return labels


def timing_stats(
    entries: Sequence[TimedEntry], versions: Mapping[int, Sequence[Step] | None], current_version: int
) -> TopicTiming:
    """Timing stats over ``entries`` (already filtered to the range).

    ``versions`` maps each version number of the topic to its steps (None when that version
    isn't timed); the current version's steps come first in ``steps``, in step order, then
    other keys seen in range, by key. Only keys seen in range (done or skipped) are listed.
    A key keeps the label of the latest version that has it, else its latest segment's.
    """
    timed = sorted(
        ((e, e.timing) for e in entries if e.timing is not None),
        key=lambda p: (p[0].captured_at, p[0].entry_id),
    )
    current = [s.key for s in versions.get(current_version) or ()]
    labels = step_labels(versions)
    latest_labels: dict[str, str] = {}  # a key in no version: its latest segment's label

    done: dict[str, list[int]] = {}
    skipped: dict[str, int] = {}
    lap_totals: list[int] = []
    paused: list[int] = []
    series: list[SeriesPoint] = []
    for e, t in timed:
        steps = {s.step: s.active_ms for s in t.segments if s.step is not None}
        for s in t.segments:
            if s.step is not None:
                done.setdefault(s.step, []).append(s.active_ms)
                latest_labels[s.step] = s.label
        for key in t.skipped:
            skipped[key] = skipped.get(key, 0) + 1
        laps = [s.active_ms for s in t.segments if s.kind == "lap"]
        if laps:
            lap_totals.append(sum(laps))
        if t.pauses:
            paused.append(t.paused_ms)
        series.append(
            SeriesPoint(
                entry_id=e.entry_id,
                captured_at=e.captured_at,
                started_at=t.started_at,
                active_ms=t.active_ms,
                paused_ms=t.paused_ms,
                complete=t.complete,
                steps=steps,
            )
        )

    seen = done.keys() | skipped.keys()
    order = [k for k in current if k in seen] + sorted(seen - set(current))
    complete = [t.active_ms for _, t in timed if t.complete]
    return TopicTiming(
        runs=len(timed),
        complete_runs=len(complete),
        total=summary(complete),
        steps=tuple(
            StepStats(
                key=key,
                label=labels.get(key) or latest_labels.get(key, key),
                current=key in current,
                done=len(done.get(key, [])),
                skipped=skipped.get(key, 0),
                best_ms=min(done.get(key, []), default=None),
                median_ms=median(done.get(key, [])),
                mean_ms=mean(done.get(key, [])),
            )
            for key in order
        ),
        laps=LapStats(runs_with_laps=len(lap_totals), median_ms=median(lap_totals), mean_ms=mean(lap_totals)),
        paused=PausedStats(runs_with_pauses=len(paused), median_ms=median(paused)),
        series=tuple(series),
    )
