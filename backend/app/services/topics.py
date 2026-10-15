from __future__ import annotations

import re
import unicodedata
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from pydantic import TypeAdapter, ValidationError
from sqlalchemy import Select, column, func, literal, or_, select
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict, DomainError, IncompatibleVersion, NotFound
from app.models import Session, Topic, TopicStatus, TopicVersion
from app.schemas.api import (
    CompatibilityReport,
    FieldIssue,
    StatusFilter,
    TopicCreate,
    TopicDetail,
    TopicPage,
    TopicSort,
    TopicSummary,
    TopicUpdate,
    TopicVersionOut,
    VersionCreate,
)
from app.schemas.questions import Question, QuestionSet
from app.services.compat import check_compatibility

_questions_adapter: TypeAdapter[list[Question]] = TypeAdapter(list[Question])


def parse_questions(raw: list[dict[str, Any]]) -> list[Question]:
    return _questions_adapter.validate_python(raw)


def dump_questions(questions: list[Question]) -> list[dict[str, Any]]:
    dumped: list[dict[str, Any]] = _questions_adapter.dump_python(questions, mode="json")
    return dumped


def slugify(name: str) -> str:
    norm = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", norm.lower()).strip("-")[:64].strip("-")
    return slug or "topic"


def _validated_set(questions: list[Question]) -> list[Question]:
    try:
        return QuestionSet(questions=questions).questions
    except ValidationError as exc:
        issues = [
            FieldIssue(loc=["questions", *e["loc"]], message=e["msg"].removeprefix("Value error, "))
            for e in exc.errors()
        ]
        raise DomainError("invalid question set", issues) from exc


async def resolve_topic(db: AsyncSession, ref: str) -> Topic:
    """Find a topic by UUID or slug."""
    stmt = select(Topic)
    try:
        stmt = stmt.where(Topic.id == UUID(ref))
    except ValueError:
        stmt = stmt.where(Topic.slug == ref)
    topic = (await db.execute(stmt)).scalar_one_or_none()
    if topic is None:
        raise NotFound(f"topic '{ref}' not found")
    return topic


async def get_version(db: AsyncSession, topic: Topic, version: int | None = None) -> TopicVersion:
    v = version if version is not None else topic.current_version
    row = (
        await db.execute(
            select(TopicVersion).where(TopicVersion.topic_id == topic.id, TopicVersion.version == v)
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound(f"version {v} of topic '{topic.slug}' not found")
    return row


def _session_stats_subquery() -> Any:
    return (
        select(
            Session.topic_id.label("topic_id"),
            func.count(Session.id).label("session_count"),
            func.max(Session.captured_at).label("last_captured_at"),
        )
        .group_by(Session.topic_id)
        .subquery()
    )


async def _summaries(db: AsyncSession, stmt: Select[Any]) -> list[tuple[TopicSummary, list[Question]]]:
    rows = (await db.execute(stmt)).all()
    out: list[tuple[TopicSummary, list[Question]]] = []
    for topic, questions_raw, session_count, last_captured in rows:
        questions = parse_questions(questions_raw)
        out.append(
            (
                TopicSummary(
                    id=topic.id,
                    slug=topic.slug,
                    name=topic.name,
                    description=topic.description,
                    status=topic.status,
                    current_version=topic.current_version,
                    question_count=len(questions),
                    session_count=session_count or 0,
                    last_captured_at=last_captured,
                    created_at=topic.created_at,
                    updated_at=topic.updated_at,
                    archived_at=topic.archived_at,
                ),
                questions,
            )
        )
    return out


def _base_select() -> tuple[Select[Any], Any]:
    stats = _session_stats_subquery()
    stmt = (
        select(
            Topic,
            TopicVersion.questions,
            stats.c.session_count,
            stats.c.last_captured_at,
        )
        .join(
            TopicVersion,
            (TopicVersion.topic_id == Topic.id) & (TopicVersion.version == Topic.current_version),
        )
        .outerjoin(stats, stats.c.topic_id == Topic.id)
    )
    return stmt, stats


async def topic_detail(db: AsyncSession, topic_id: UUID) -> TopicDetail:
    stmt, _ = _base_select()
    rows = await _summaries(db, stmt.where(Topic.id == topic_id))
    if not rows:
        raise NotFound("topic not found")
    summary, questions = rows[0]
    return TopicDetail(**summary.model_dump(), questions=questions)


def _question_text_matches(pattern: str) -> Any:
    """Match question keys/labels/help text in the current version config.

    Matches individual fields rather than the serialized JSON, so searching for
    e.g. "label" or "_" does not hit every topic via the JSON structure.
    """
    elem = func.jsonb_array_elements(TopicVersion.questions).table_valued(column("value", JSONB)).alias("qe")
    fields = [elem.c.value[f].astext.ilike(pattern) for f in ("key", "label", "help_text")]
    return select(literal(1)).select_from(elem).where(or_(*fields)).exists()


async def list_topics(
    db: AsyncSession,
    *,
    q: str | None = None,
    status: StatusFilter = "active",
    sort: TopicSort = "-updated",
    limit: int = 50,
    offset: int = 0,
) -> TopicPage:
    stmt, stats = _base_select()
    count_stmt = select(func.count(Topic.id))
    filters = []
    if status != "all":
        filters.append(Topic.status == TopicStatus(status))
    if q:
        pattern = f"%{q.strip().replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')}%"
        filters.append(
            or_(
                Topic.name.ilike(pattern),
                Topic.slug.ilike(pattern),
                Topic.description.ilike(pattern),
                _question_text_matches(pattern),
            )
        )
        count_stmt = count_stmt.join(
            TopicVersion,
            (TopicVersion.topic_id == Topic.id) & (TopicVersion.version == Topic.current_version),
        )
    for f in filters:
        stmt = stmt.where(f)
        count_stmt = count_stmt.where(f)

    activity = func.coalesce(stats.c.last_captured_at, Topic.updated_at)
    order_cols = {
        "updated": Topic.updated_at,
        "name": func.lower(Topic.name),
        "created": Topic.created_at,
        "activity": activity,
    }
    col = order_cols[sort.lstrip("-")]
    stmt = stmt.order_by(col.desc() if sort.startswith("-") else col.asc(), Topic.id)
    total = (await db.execute(count_stmt)).scalar_one()
    items = await _summaries(db, stmt.limit(limit).offset(offset))
    return TopicPage(items=[s for s, _ in items], total=total, limit=limit, offset=offset)


async def create_topic(db: AsyncSession, body: TopicCreate) -> TopicDetail:
    questions = _validated_set(body.questions)
    topic = Topic(
        slug=body.slug or slugify(body.name),
        name=body.name,
        description=body.description,
        status=TopicStatus.active,
        current_version=1,
    )
    topic.versions.append(
        TopicVersion(
            version=1,
            questions=dump_questions(questions),
            change_note="Initial version",
        )
    )
    db.add(topic)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        raise Conflict(f"slug '{topic.slug}' is already in use") from exc
    return await topic_detail(db, topic.id)


async def update_topic(db: AsyncSession, ref: str, body: TopicUpdate) -> TopicDetail:
    topic = await resolve_topic(db, ref)
    if body.name is not None:
        topic.name = body.name
    if body.slug is not None:
        topic.slug = body.slug
    if body.description is not None:
        topic.description = body.description
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        raise Conflict(f"slug '{body.slug}' is already in use") from exc
    return await topic_detail(db, topic.id)


async def set_archived(db: AsyncSession, ref: str, archived: bool) -> TopicDetail:
    topic = await resolve_topic(db, ref)
    topic.status = TopicStatus.archived if archived else TopicStatus.active
    topic.archived_at = datetime.now(UTC) if archived else None
    await db.commit()
    return await topic_detail(db, topic.id)


async def delete_topic(db: AsyncSession, ref: str) -> None:
    topic = await resolve_topic(db, ref)
    if topic.status != TopicStatus.archived:
        raise Conflict("archive the topic before deleting it")
    await db.delete(topic)
    await db.commit()


async def _history(db: AsyncSession, topic: Topic) -> list[list[Question]]:
    rows = (
        await db.execute(
            select(TopicVersion.questions)
            .where(TopicVersion.topic_id == topic.id)
            .order_by(TopicVersion.version)
        )
    ).scalars()
    return [parse_questions(r) for r in rows]


async def check_version(db: AsyncSession, ref: str, questions: list[Question]) -> CompatibilityReport:
    topic = await resolve_topic(db, ref)
    return check_compatibility(await _history(db, topic), _validated_set(questions))


async def publish_version(db: AsyncSession, ref: str, body: VersionCreate) -> TopicDetail:
    # Row lock prevents two concurrent publishes from racing on version numbers.
    topic = await resolve_topic(db, ref)
    await db.execute(select(Topic.id).where(Topic.id == topic.id).with_for_update())
    await db.refresh(topic)
    if body.base_version != topic.current_version:
        raise Conflict(
            f"topic is at version {topic.current_version}, but this edit was based on "
            f"version {body.base_version}; reload and re-apply your changes"
        )
    questions = _validated_set(body.questions)
    report = check_compatibility(await _history(db, topic), questions)
    if not report.ok:
        raise IncompatibleVersion(
            "; ".join(
                i.message if i.question_key is None else f"{i.question_key}: {i.message}"
                for i in report.issues
                if i.level == "error"
            )
        )
    next_version = topic.current_version + 1
    db.add(
        TopicVersion(
            topic_id=topic.id,
            version=next_version,
            questions=dump_questions(questions),
            change_note=body.change_note,
        )
    )
    topic.current_version = next_version
    topic.updated_at = datetime.now(UTC)
    await db.commit()
    return await topic_detail(db, topic.id)


async def list_versions(db: AsyncSession, ref: str) -> list[TopicVersionOut]:
    topic = await resolve_topic(db, ref)
    counts = (
        select(Session.version, func.count(Session.id).label("n"))
        .where(Session.topic_id == topic.id)
        .group_by(Session.version)
        .subquery()
    )
    rows = (
        await db.execute(
            select(TopicVersion, counts.c.n)
            .outerjoin(counts, counts.c.version == TopicVersion.version)
            .where(TopicVersion.topic_id == topic.id)
            .order_by(TopicVersion.version.desc())
        )
    ).all()
    return [
        TopicVersionOut(
            version=v.version,
            questions=parse_questions(v.questions),
            change_note=v.change_note,
            created_at=v.created_at,
            session_count=n or 0,
        )
        for v, n in rows
    ]


async def all_questions_by_key(db: AsyncSession, topic: Topic) -> dict[str, Question]:
    """Latest definition of every question ever present in the topic (current version wins)."""
    out: dict[str, Question] = {}
    for version in await _history(db, topic):
        for q in version:
            out[q.key] = q
    return out
