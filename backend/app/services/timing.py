"""``getTopicTiming`` (docs/specs/timers.md §9.2): :mod:`app.services.timing_stats` over a
topic's entries in range. The math lives there; this module only loads its inputs."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Entry, TopicVersion
from app.schemas.api import (
    EntryFilters,
    TimingLaps,
    TimingPaused,
    TimingSeriesPoint,
    TimingStepStats,
    TimingSummary,
    TopicTiming,
)
from app.services import run_fold, timing_stats
from app.services.entries import apply_filters
from app.services.topics import parse_timer, resolve_topic


async def topic_timing(db: AsyncSession, ref: str, filters: EntryFilters) -> TopicTiming:
    """The same filters as ``getTopicStats``; an untimed topic answers zero counts."""
    topic = await resolve_topic(db, ref)
    rows = (
        await db.execute(
            apply_filters(select(Entry.id, Entry.captured_at, Entry.timing), topic.id, filters).where(
                Entry.timing.is_not(None)
            )
        )
    ).all()
    entries = [
        timing_stats.TimedEntry(
            entry_id=str(entry_id),
            captured_at=run_fold.to_ms(captured_at),
            timing=None if timing is None else run_fold.timing_from_json(timing),
        )
        for entry_id, captured_at, timing in rows
    ]
    # Every version, not only those in range: a step's label is the latest version's.
    versions: dict[int, list[run_fold.Step] | None] = {}
    for number, raw in (
        await db.execute(
            select(TopicVersion.version, TopicVersion.timer).where(TopicVersion.topic_id == topic.id)
        )
    ).all():
        timer = parse_timer(raw)
        versions[number] = None if timer is None else [run_fold.Step(s.key, s.label) for s in timer.steps]
    return _out(timing_stats.timing_stats(entries, versions, topic.current_version))


def _out(t: timing_stats.TopicTiming) -> TopicTiming:
    return TopicTiming(
        runs=t.runs,
        complete_runs=t.complete_runs,
        total=TimingSummary(best_ms=t.total.best_ms, median_ms=t.total.median_ms, mean_ms=t.total.mean_ms),
        steps=[
            TimingStepStats(
                key=s.key,
                label=s.label,
                current=s.current,
                done=s.done,
                skipped=s.skipped,
                best_ms=s.best_ms,
                median_ms=s.median_ms,
                mean_ms=s.mean_ms,
            )
            for s in t.steps
        ],
        laps=TimingLaps(
            runs_with_laps=t.laps.runs_with_laps, median_ms=t.laps.median_ms, mean_ms=t.laps.mean_ms
        ),
        paused=TimingPaused(runs_with_pauses=t.paused.runs_with_pauses, median_ms=t.paused.median_ms),
        series=[
            TimingSeriesPoint(
                entry_id=UUID(p.entry_id),
                captured_at=run_fold.from_ms(p.captured_at),
                started_at=run_fold.from_ms(p.started_at),
                active_ms=p.active_ms,
                paused_ms=p.paused_ms,
                complete=p.complete,
                steps=dict(p.steps),
            )
            for p in t.series
        ],
    )
