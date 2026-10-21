"""Aggregation across entries. Numeric work is pushed into Postgres."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from sqlalchemy import Double, Select, cast, func, literal, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import DomainError, NotFound
from app.models import Answer, Entry
from app.schemas.api import (
    Bucket,
    EntryFilters,
    EnumOptionCount,
    EnumStats,
    HistogramBin,
    NumericStats,
    QuestionSeries,
    QuestionStats,
    RecentText,
    SeriesPoint,
    StrStats,
    TopicStats,
    ValueCount,
)
from app.schemas.questions import EnumQuestion, Question
from app.services.entries import apply_filters
from app.services.topics import all_questions_by_key, get_version, parse_questions, resolve_topic

HISTOGRAM_BINS = 10


def _answers_for(topic_id: Any, key: str, filters: EntryFilters, *cols: Any) -> Select[Any]:
    stmt = select(*cols).select_from(Answer).join(Entry, Entry.id == Answer.entry_id)
    stmt = apply_filters(stmt, topic_id, filters)
    return stmt.where(Answer.question_key == key)


async def _numeric(
    db: AsyncSession, topic_id: Any, q: Question, filters: EntryFilters, total: int
) -> NumericStats:
    v = func.coalesce(cast(Answer.value_int, Double), Answer.value_double)
    row = (
        await db.execute(
            _answers_for(
                topic_id,
                q.key,
                filters,
                func.count(v),
                func.min(v),
                func.max(v),
                func.avg(v),
                func.percentile_cont(0.5).within_group(v),
                func.stddev_samp(v),
                func.sum(v),
            )
        )
    ).one()
    count, vmin, vmax, mean, median, stddev, total_sum = row
    histogram: list[HistogramBin] = []
    if count and vmin is not None and vmax is not None:
        lo, hi = float(vmin), float(vmax)
        if q.type == "int" and hi - lo + 1 <= HISTOGRAM_BINS:
            # One bin per integer for small integer ranges.
            edges = [(lo + i - 0.5, lo + i + 0.5) for i in range(int(hi - lo) + 1)]
        else:
            width = (hi - lo) / HISTOGRAM_BINS or 1.0
            edges = [(lo + i * width, lo + (i + 1) * width) for i in range(HISTOGRAM_BINS)]
        n_bins = len(edges)
        span = edges[-1][1] - edges[0][0]
        bucket = func.least(
            func.floor((v - literal(edges[0][0])) / literal(span) * n_bins), literal(n_bins - 1)
        ).label("b")
        rows = (
            await db.execute(_answers_for(topic_id, q.key, filters, bucket, func.count()).group_by(bucket))
        ).all()
        counts = {int(b): int(c) for b, c in rows}
        histogram = [HistogramBin(lower=a, upper=b, count=counts.get(i, 0)) for i, (a, b) in enumerate(edges)]
    return NumericStats(
        key=q.key,
        label=q.label,
        type="int" if q.type == "int" else "double",
        count=count,
        missing=max(total - count, 0),
        min=_f(vmin),
        max=_f(vmax),
        mean=_f(mean),
        median=_f(median),
        stddev=_f(stddev),
        sum=_f(total_sum),
        histogram=histogram,
    )


def _f(v: object) -> float | None:
    return None if v is None else float(v)  # type: ignore[arg-type]


async def _value_counts(
    db: AsyncSession, topic_id: Any, key: str, filters: EntryFilters, limit: int | None
) -> list[ValueCount]:
    n = func.count().label("n")
    stmt = (
        _answers_for(topic_id, key, filters, Answer.value_str, n)
        .group_by(Answer.value_str)
        .order_by(n.desc(), Answer.value_str)
    )
    if limit is not None:
        stmt = stmt.limit(limit)
    return [ValueCount(value=v, count=c) for v, c in (await db.execute(stmt)).all() if v is not None]


async def _text(db: AsyncSession, topic_id: Any, q: Question, filters: EntryFilters, total: int) -> StrStats:
    count, distinct = (
        await db.execute(
            _answers_for(topic_id, q.key, filters, func.count(), func.count(Answer.value_str.distinct()))
        )
    ).one()
    recent_rows = (
        await db.execute(
            _answers_for(topic_id, q.key, filters, Entry.id, Answer.value_str, Entry.captured_at)
            # Ties (the same captured_at) by id, so a response never depends on the plan.
            .order_by(Entry.captured_at.desc(), Entry.id.desc())
            .limit(10)
        )
    ).all()
    return StrStats(
        key=q.key,
        label=q.label,
        type="str",
        count=count,
        missing=max(total - count, 0),
        distinct=distinct,
        top=[vc for vc in await _value_counts(db, topic_id, q.key, filters, 10) if vc.count > 1],
        recent=[RecentText(entry_id=i, value=v or "", captured_at=t) for i, v, t in recent_rows],
    )


async def _option_counts(db: AsyncSession, topic_id: Any, key: str, filters: EntryFilters) -> dict[str, int]:
    """Entries selecting each option: single-select values plus every element of multi-select lists."""
    counts = {vc.value: vc.count for vc in await _value_counts(db, topic_id, key, filters, None)}
    sub = _answers_for(topic_id, key, filters, func.unnest(Answer.value_list).label("v")).subquery()
    for value, n in (await db.execute(select(sub.c.v, func.count()).group_by(sub.c.v))).all():
        counts[value] = counts.get(value, 0) + n
    return counts


async def _enum(
    db: AsyncSession, topic_id: Any, q: EnumQuestion, filters: EntryFilters, total: int
) -> EnumStats:
    counts = await _option_counts(db, topic_id, q.key, filters)
    answered = (await db.execute(_answers_for(topic_id, q.key, filters, func.count()))).scalar_one()
    return EnumStats(
        key=q.key,
        label=q.label,
        type="enum",
        multiple=q.multiple,
        count=answered,
        missing=max(total - answered, 0),
        options=[
            EnumOptionCount(
                value=o.value,
                label=o.label,
                archived=o.archived,
                count=counts.get(o.value, 0),
                share=(counts.get(o.value, 0) / answered) if answered else 0.0,
            )
            for o in q.options
        ],
    )


async def topic_stats(db: AsyncSession, ref: str, filters: EntryFilters) -> TopicStats:
    topic = await resolve_topic(db, ref)
    total, first, last = (
        await db.execute(
            apply_filters(
                select(func.count(Entry.id), func.min(Entry.captured_at), func.max(Entry.captured_at)),
                topic.id,
                filters,
            )
        )
    ).one()
    current = parse_questions((await get_version(db, topic)).questions)
    every = await all_questions_by_key(db, topic)
    current_keys = {q.key for q in current}
    # Historic (removed) questions are included only when they hold data.
    keys_with_data = set(
        (
            await db.execute(select(Answer.question_key).where(Answer.topic_id == topic.id).distinct())
        ).scalars()
    )
    ordered = current + [q for k, q in every.items() if k not in current_keys and k in keys_with_data]

    stats: list[QuestionStats] = []
    for q in ordered:
        match q.type:
            case "int" | "double":
                stats.append(await _numeric(db, topic.id, q, filters, total))
            case "str":
                stats.append(await _text(db, topic.id, q, filters, total))
            case "enum":
                assert isinstance(q, EnumQuestion)
                stats.append(await _enum(db, topic.id, q, filters, total))

    source_n = func.count().label("n")
    sources = (
        await db.execute(
            apply_filters(select(Entry.source, source_n), topic.id, filters)
            .group_by(Entry.source)
            # Ties by name, as `_value_counts` does: the aggregate's order is the plan's.
            .order_by(source_n.desc(), Entry.source)
        )
    ).all()
    return TopicStats(
        topic_id=topic.id,
        entry_count=total,
        first_captured_at=first,
        last_captured_at=last,
        sources=[ValueCount(value=s, count=n) for s, n in sources],
        questions=stats,
    )


async def question_series(
    db: AsyncSession,
    ref: str,
    key: str,
    filters: EntryFilters,
    bucket: Bucket = "day",
    tz: str = "UTC",
) -> QuestionSeries:
    topic = await resolve_topic(db, ref)
    every = await all_questions_by_key(db, topic)
    q = every.get(key)
    if q is None:
        raise NotFound(f"question '{key}' not found in topic '{topic.slug}'")
    try:
        ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise DomainError(f"unknown timezone '{tz}'") from exc
    # Truncate in the caller's local time, then convert back to an aware timestamp.
    start = func.timezone(tz, func.date_trunc(bucket, func.timezone(tz, Entry.captured_at))).label("start")
    points: dict[datetime, SeriesPoint] = {}
    if q.type in ("int", "double"):
        v = func.coalesce(cast(Answer.value_int, Double), Answer.value_double)
        rows = (
            await db.execute(
                _answers_for(
                    topic.id, key, filters, start, func.count(), func.avg(v), func.min(v), func.max(v)
                )
                .group_by(start)
                .order_by(start)
            )
        ).all()
        for s, n, mean, vmin, vmax in rows:
            points[s] = SeriesPoint(start=s, count=n, mean=_f(mean), min=_f(vmin), max=_f(vmax))
    else:
        rows = (
            await db.execute(
                _answers_for(topic.id, key, filters, start, Answer.value_str, func.count())
                .group_by(start, Answer.value_str)
                .order_by(start)
            )
        ).all()
        for s, value, n in rows:
            p = points.setdefault(s, SeriesPoint(start=s, count=0))
            p.count += n
            if q.type == "enum" and value is not None:
                p.option_counts[value] = n
        if q.type == "enum":
            sub = _answers_for(
                topic.id, key, filters, start, func.unnest(Answer.value_list).label("v")
            ).subquery()
            for s, value, n in (
                await db.execute(select(sub.c.start, sub.c.v, func.count()).group_by(sub.c.start, sub.c.v))
            ).all():
                p = points[s]
                p.option_counts[value] = p.option_counts.get(value, 0) + n
        points = dict(sorted(points.items()))
    return QuestionSeries(key=key, type=q.type, bucket=bucket, points=list(points.values()))
