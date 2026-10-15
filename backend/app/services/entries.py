from __future__ import annotations

import csv
import io
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import NotFound, TopicArchived
from app.models import Answer, Channel, Entry, Topic, TopicStatus
from app.schemas.api import (
    AnswerOut,
    DoubleAnswer,
    EntryCreate,
    EntryFilters,
    EntryOrder,
    EntryOut,
    EntryPage,
    EntryUpdate,
    EnumAnswer,
    IntAnswer,
    StrAnswer,
)
from app.services.answers import TypedAnswer, validate_answers
from app.services.topics import (
    all_questions_by_key,
    get_version,
    parse_questions,
    resolve_topic,
)


def _answer_out(a: Answer) -> AnswerOut:
    match a.question_type:
        case "int":
            assert a.value_int is not None
            return IntAnswer(key=a.question_key, value=a.value_int)
        case "double":
            assert a.value_double is not None
            return DoubleAnswer(key=a.question_key, value=a.value_double)
        case "enum":
            assert a.value_str is not None
            return EnumAnswer(key=a.question_key, value=a.value_str)
        case _:
            assert a.value_str is not None
            return StrAnswer(key=a.question_key, value=a.value_str)


def entry_out(s: Entry) -> EntryOut:
    return EntryOut(
        id=s.id,
        topic_id=s.topic_id,
        version=s.version,
        source=s.source,
        channel=s.channel,
        captured_at=s.captured_at,
        created_at=s.created_at,
        updated_at=s.updated_at,
        notes=s.notes,
        meta=s.meta,
        answers=[_answer_out(a) for a in s.answers],
    )


def _to_rows(topic_id: UUID, typed: list[TypedAnswer]) -> list[Answer]:
    return [
        Answer(
            topic_id=topic_id,
            question_key=t.key,
            question_type=t.type,
            position=t.position,
            value_int=t.value_int,
            value_double=t.value_double,
            value_str=t.value_str,
        )
        for t in typed
    ]


def _raw_value(a: Answer) -> int | float | str:
    if a.value_int is not None:
        return a.value_int
    if a.value_double is not None:
        return a.value_double
    assert a.value_str is not None
    return a.value_str


async def create_entry(db: AsyncSession, ref: str, body: EntryCreate, channel: Channel) -> EntryOut:
    topic = await resolve_topic(db, ref)
    if topic.status == TopicStatus.archived:
        raise TopicArchived(f"topic '{topic.slug}' is archived; unarchive it to record entries")
    version = await get_version(db, topic, body.version)
    typed = validate_answers(parse_questions(version.questions), body.answers)
    entry = Entry(
        topic_id=topic.id,
        topic_version_id=version.id,
        version=version.version,
        source=body.source or channel.value,
        channel=channel,
        captured_at=body.captured_at or datetime.now(UTC),
        notes=body.notes,
        meta=body.meta,
        answers=_to_rows(topic.id, typed),
    )
    db.add(entry)
    await db.commit()
    return await get_entry(db, entry.id)


async def _load(db: AsyncSession, entry_id: UUID) -> Entry:
    # populate_existing: return DB-normalised values (e.g. UTC captured_at) even
    # when the object is already in the identity map from this request.
    stmt = select(Entry).where(Entry.id == entry_id).execution_options(populate_existing=True)
    s = (await db.execute(stmt)).scalar_one_or_none()
    if s is None:
        raise NotFound(f"entry '{entry_id}' not found")
    return s


async def get_entry(db: AsyncSession, entry_id: UUID) -> EntryOut:
    s = await _load(db, entry_id)
    await db.refresh(s, ["answers"])
    return entry_out(s)


async def update_entry(db: AsyncSession, entry_id: UUID, body: EntryUpdate) -> EntryOut:
    s = await _load(db, entry_id)
    topic = (await db.execute(select(Topic).where(Topic.id == s.topic_id))).scalar_one()
    if body.answers is not None:
        version = await get_version(db, topic, s.version)
        existing = {a.question_key: a for a in s.answers}
        merged: dict[str, Any] = {k: _raw_value(a) for k, a in existing.items()}
        merged.update(body.answers)
        # Archived enum values the entry already holds stay editable-around.
        keep_archived = {
            k: a.value_str for k, a in existing.items() if a.question_type == "enum" and a.value_str
        }
        typed = validate_answers(
            parse_questions(version.questions),
            merged,
            allowed_archived={k: v for k, v in keep_archived.items() if v is not None},
        )
        s.answers.clear()
        await db.flush()
        s.answers.extend(_to_rows(topic.id, typed))
    if body.source is not None:
        s.source = body.source
    if body.captured_at is not None:
        s.captured_at = body.captured_at
    if body.notes is not None:
        s.notes = body.notes
    if body.meta is not None:
        s.meta = body.meta
    s.updated_at = datetime.now(UTC)
    await db.commit()
    return await get_entry(db, s.id)


async def delete_entry(db: AsyncSession, entry_id: UUID) -> None:
    s = await _load(db, entry_id)
    await db.delete(s)
    await db.commit()


def apply_filters[*Ts](stmt: Select[*Ts], topic_id: UUID, f: EntryFilters) -> Select[*Ts]:
    stmt = stmt.where(Entry.topic_id == topic_id)
    if f.captured_from is not None:
        stmt = stmt.where(Entry.captured_at >= f.captured_from)
    if f.captured_to is not None:
        stmt = stmt.where(Entry.captured_at < f.captured_to)
    if f.version is not None:
        stmt = stmt.where(Entry.version == f.version)
    if f.source is not None:
        stmt = stmt.where(Entry.source == f.source)
    if f.channel is not None:
        stmt = stmt.where(Entry.channel == f.channel)
    return stmt


async def list_entries(
    db: AsyncSession,
    ref: str,
    filters: EntryFilters,
    *,
    order: EntryOrder = "-captured_at",
    limit: int = 50,
    offset: int = 0,
) -> EntryPage:
    topic = await resolve_topic(db, ref)
    total = (await db.execute(apply_filters(select(func.count(Entry.id)), topic.id, filters))).scalar_one()
    col = Entry.captured_at if order.lstrip("-") == "captured_at" else Entry.created_at
    stmt = apply_filters(select(Entry), topic.id, filters).order_by(
        col.desc() if order.startswith("-") else col.asc(), Entry.id
    )
    rows = (await db.execute(stmt.limit(limit).offset(offset))).scalars().all()
    return EntryPage(items=[entry_out(s) for s in rows], total=total, limit=limit, offset=offset)


async def export_csv(db: AsyncSession, ref: str, filters: EntryFilters) -> AsyncIterator[str]:
    topic = await resolve_topic(db, ref)
    questions = list((await all_questions_by_key(db, topic)).values())
    current_keys = [q.key for q in parse_questions((await get_version(db, topic)).questions)]
    keys = current_keys + [q.key for q in questions if q.key not in current_keys]
    header = [
        "entry_id",
        "captured_at",
        "version",
        "source",
        "channel",
        "notes",
        *keys,
    ]

    def line(values: list[object]) -> str:
        buf = io.StringIO()
        csv.writer(buf).writerow(values)
        return buf.getvalue()

    def row(s: Entry) -> str:
        by_key = {a.question_key: _raw_value(a) for a in s.answers}
        return line(
            [
                str(s.id),
                s.captured_at.isoformat(),
                s.version,
                s.source,
                s.channel.value,
                s.notes,
                *[by_key.get(k, "") for k in keys],
            ]
        )

    async def gen() -> AsyncIterator[str]:
        yield line(list(header))
        stmt = apply_filters(select(Entry), topic.id, filters).order_by(Entry.captured_at, Entry.id)
        offset = 0
        while True:
            # Paged rather than streamed: answers are selectin-loaded per page
            # on the same connection, which a live server-side cursor forbids.
            page = (await db.execute(stmt.limit(500).offset(offset))).scalars().all()
            if not page:
                break
            offset += len(page)
            for s in page:
                yield row(s)

    return gen()
