from __future__ import annotations

import re
import unicodedata
from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

from pydantic import TypeAdapter, ValidationError
from sqlalchemy import Select, column, delete, func, literal, or_, select
from sqlalchemy.dialects.postgresql import JSONB, insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import Conflict, DomainError, IncompatibleVersion, NotFound, StaleRevision
from app.models import DeletedId, Entry, FeedKind, FeedOp, Topic, TopicStatus, TopicVersion
from app.schemas.api import (
    CompatibilityReport,
    DueStatus,
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
from app.schemas.base import issues_from
from app.schemas.questions import Question, QuestionSet, Timer
from app.services.compat import check_compatibility
from app.services.feed import log_change, tombstone, writer
from app.services.schedule import compute_due, dump_schedule, parse_schedule

_questions_adapter: TypeAdapter[list[Question]] = TypeAdapter(list[Question])


def parse_questions(raw: list[dict[str, Any]]) -> list[Question]:
    """Parse a stored question config (checks added after it was stored are skipped)."""
    return _questions_adapter.validate_python(raw, context={"stored": True})


def dump_questions(questions: list[Question]) -> list[dict[str, Any]]:
    dumped: list[dict[str, Any]] = _questions_adapter.dump_python(questions, mode="json")
    return dumped


def parse_timer(raw: dict[str, Any] | None) -> Timer | None:
    return None if raw is None else Timer.model_validate(raw, context={"stored": True})


def dump_timer(timer: Timer | None) -> dict[str, Any] | None:
    return None if timer is None else timer.model_dump(mode="json")


def slugify(name: str) -> str:
    norm = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", norm.lower()).strip("-")[:64].strip("-")
    return slug or "topic"


def _validated_set(questions: list[Question]) -> list[Question]:
    try:
        return QuestionSet(questions=questions).questions
    except ValidationError as exc:
        raise DomainError("invalid question set", issues_from(exc)) from exc


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


def _entry_stats_subquery() -> Any:
    return (
        select(
            Entry.topic_id.label("topic_id"),
            func.count(Entry.id).label("entry_count"),
            func.max(Entry.captured_at).label("last_captured_at"),
        )
        .group_by(Entry.topic_id)
        .subquery()
    )


def _due(topic: Topic, last_captured: datetime | None, now: datetime) -> DueStatus | None:
    schedule = parse_schedule(topic.schedule)
    if schedule is None:
        return None
    return compute_due(
        schedule,
        now=now,
        last_entry_at=last_captured,
        schedule_since=topic.schedule_updated_at or topic.created_at,
        archived=topic.status == TopicStatus.archived,
    )


async def _summaries(
    db: AsyncSession, stmt: Select[Any], now: datetime | None = None
) -> list[tuple[TopicSummary, list[Question]]]:
    rows = (await db.execute(stmt)).all()
    now = now or datetime.now(UTC)
    out: list[tuple[TopicSummary, list[Question]]] = []
    for topic, questions_raw, entry_count, last_captured in rows:
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
                    revision=topic.revision,
                    question_count=len(questions),
                    entry_count=entry_count or 0,
                    last_captured_at=last_captured,
                    created_at=topic.created_at,
                    updated_at=topic.updated_at,
                    archived_at=topic.archived_at,
                    schedule=parse_schedule(topic.schedule),
                    schedule_updated_at=topic.schedule_updated_at,
                    due=_due(topic, last_captured, now),
                ),
                questions,
            )
        )
    return out


def _base_select() -> tuple[Select[Any], Any]:
    stats = _entry_stats_subquery()
    stmt = (
        select(
            Topic,
            TopicVersion.questions,
            stats.c.entry_count,
            stats.c.last_captured_at,
        )
        .join(
            TopicVersion,
            (TopicVersion.topic_id == Topic.id) & (TopicVersion.version == Topic.current_version),
        )
        .outerjoin(stats, stats.c.topic_id == Topic.id)
    )
    return stmt, stats


async def topic_details(db: AsyncSession, topic_ids: list[UUID]) -> dict[UUID, TopicDetail]:
    """Details of the given topics that exist, by id."""
    stmt, _ = _base_select()
    rows = await _summaries(db, stmt.where(Topic.id.in_(topic_ids)))
    return {s.id: TopicDetail(**s.model_dump(), questions=questions) for s, questions in rows}


async def topic_detail(db: AsyncSession, topic_id: UUID) -> TopicDetail:
    detail = (await topic_details(db, [topic_id])).get(topic_id)
    if detail is None:
        raise NotFound("topic not found")
    return detail


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
    sort: TopicSort = "due",
    due_only: bool = False,
    limit: int = 50,
    offset: int = 0,
    now: datetime | None = None,
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

    if sort == "due" or due_only:
        # Due status is computed in Python, so sort/filter the whole (personal-scale) set here.
        rows = await _summaries(db, stmt, now)
        items = [s for s, _ in rows if not due_only or (s.due is not None and s.due.is_due)]
        if sort == "due":
            items.sort(key=_due_sort_key)
        else:
            _sort_in_python(items, sort)
        return TopicPage(items=items[offset : offset + limit], total=len(items), limit=limit, offset=offset)

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
    page = await _summaries(db, stmt.limit(limit).offset(offset), now)
    return TopicPage(items=[s for s, _ in page], total=total, limit=limit, offset=offset)


_FAR_FUTURE = datetime.max.replace(tzinfo=UTC).timestamp()


def _activity(s: TopicSummary) -> datetime:
    return s.last_captured_at or s.updated_at


def _due_sort_key(s: TopicSummary) -> tuple[int, float, str]:
    """Due topics (oldest due first), then scheduled by next due time, then the rest by activity."""
    if s.due is not None and s.due.is_due and s.due.due_since is not None:
        return (0, s.due.due_since.timestamp(), str(s.id))
    if s.due is not None:
        nxt = s.due.next_due_at.timestamp() if s.due.next_due_at is not None else _FAR_FUTURE
        return (1, nxt, str(s.id))
    return (2, -_activity(s).timestamp(), str(s.id))


def _sort_in_python(items: list[TopicSummary], sort: TopicSort) -> None:
    """Python equivalent of the SQL orderings (used when filtering by due status)."""
    field = sort.lstrip("-")

    def value(s: TopicSummary) -> Any:
        match field:
            case "name":
                return s.name.lower()
            case "updated":
                return s.updated_at
            case "created":
                return s.created_at
            case _:
                return _activity(s)

    items.sort(key=lambda s: str(s.id))
    items.sort(key=value, reverse=sort.startswith("-"))  # stable: ties keep id order


def _check_revision(topic: Topic, expected: int | None) -> None:
    if expected is not None and expected != topic.revision:
        raise StaleRevision(
            f"topic is at revision {topic.revision}, but this change was based on revision {expected}",
            [FieldIssue(loc=["expected_revision"], message=f"current revision is {topic.revision}")],
        )


async def _log_topic(db: AsyncSession, topic: Topic) -> None:
    await log_change(db, FeedKind.topic, FeedOp.upsert, topic.id, topic.id)


@writer
async def create_topic(db: AsyncSession, body: TopicCreate) -> TopicDetail:
    questions = _validated_set(body.questions)
    topic = Topic(
        id=uuid4(),
        slug=body.slug or slugify(body.name),
        name=body.name,
        description=body.description,
        status=TopicStatus.active,
        current_version=1,
        schedule=dump_schedule(body.schedule),
        schedule_updated_at=func.now() if body.schedule is not None else None,
    )
    first = TopicVersion(
        id=uuid4(),
        version=1,
        questions=dump_questions(questions),
        timer=dump_timer(body.timer),
        change_note="Initial version",
    )
    topic.versions.append(first)
    db.add(topic)
    try:
        await db.flush()
    except IntegrityError as exc:
        raise _slug_conflict(topic.slug) from exc
    await _log_topic(db, topic)
    await log_change(db, FeedKind.version, FeedOp.upsert, first.id, topic.id)
    return await topic_detail(db, topic.id)


@writer
async def update_topic(db: AsyncSession, ref: str, body: TopicUpdate) -> TopicDetail:
    topic = await resolve_topic(db, ref)
    _check_revision(topic, body.expected_revision)
    if body.name is not None:
        topic.name = body.name
    if body.slug is not None:
        topic.slug = body.slug
    if body.description is not None:
        topic.description = body.description
    if "schedule" in body.model_fields_set:  # explicit null clears the schedule
        new = dump_schedule(body.schedule)
        if new != topic.schedule:  # an unchanged schedule keeps its reference point
            topic.schedule = new
            topic.schedule_updated_at = func.now() if new is not None else None
    topic.revision += 1
    try:
        await db.flush()
    except IntegrityError as exc:
        raise _slug_conflict(body.slug or topic.slug) from exc
    await _log_topic(db, topic)
    return await topic_detail(db, topic.id)


@writer
async def set_archived(
    db: AsyncSession, ref: str, archived: bool, expected_revision: int | None = None
) -> TopicDetail:
    topic = await resolve_topic(db, ref)
    _check_revision(topic, expected_revision)
    topic.status = TopicStatus.archived if archived else TopicStatus.active
    topic.archived_at = func.now() if archived else None
    topic.revision += 1
    await _log_topic(db, topic)
    await db.flush()
    return await topic_detail(db, topic.id)


@writer
async def delete_topic(db: AsyncSession, ref: str) -> None:
    """Delete an archived topic. Its versions and entries are tombstoned (before the
    foreign-key cascade removes them) and the feed gets one topic deletion, which clients
    apply to every child."""
    topic = await resolve_topic(db, ref)
    if topic.status != TopicStatus.archived:
        raise Conflict("archive the topic before deleting it")
    for model, kind in ((Entry, FeedKind.entry), (TopicVersion, FeedKind.version)):
        children = select(model.id, literal(kind, DeletedId.__table__.c.kind.type), model.topic_id).where(
            model.topic_id == topic.id
        )
        await db.execute(
            insert(DeletedId).from_select(["id", "kind", "topic_id"], children).on_conflict_do_nothing()
        )
    await tombstone(db, FeedKind.topic, topic.id, topic.id)
    await log_change(db, FeedKind.topic, FeedOp.delete, topic.id, topic.id)
    await db.execute(delete(Topic).where(Topic.id == topic.id))


async def _history(db: AsyncSession, topic: Topic) -> list[list[Question]]:
    rows = (
        await db.execute(
            select(TopicVersion.questions)
            .where(TopicVersion.topic_id == topic.id)
            .order_by(TopicVersion.version)
        )
    ).scalars()
    return [parse_questions(r) for r in rows]


def _slug_conflict(slug: str) -> Conflict:
    return Conflict(
        f"slug '{slug}' is already in use",
        [FieldIssue(loc=["slug"], message="already in use by another topic")],
    )


def _stale(topic: Topic, base_version: int) -> Conflict:
    return Conflict(
        f"topic is at version {topic.current_version}, but this edit was based on "
        f"version {base_version}; reload and re-apply your changes",
        [FieldIssue(loc=["base_version"], message=f"current version is {topic.current_version}")],
    )


async def _report(
    db: AsyncSession, topic: Topic, questions: list[Question], timer: dict[str, Any] | None, with_timer: bool
) -> CompatibilityReport:
    """``check_compatibility`` compares questions only. With the draft's timer, a timer change
    with no question changes is still a change, so the report's "no changes" error goes."""
    report = check_compatibility(await _history(db, topic), questions)
    if not with_timer or report.changes or timer == (await get_version(db, topic)).timer:
        return report
    # With no question changes, "no changes to publish" is the report's only issue without a
    # question; an error on a question (a type change of a historic key, say) still blocks.
    issues = [i for i in report.issues if i.question_key is not None]
    return report.model_copy(update={"issues": issues, "ok": not any(i.level == "error" for i in issues)})


async def check_version(
    db: AsyncSession,
    ref: str,
    questions: list[Question],
    base_version: int | None = None,
    *,
    timer: Timer | None = None,
    with_timer: bool = False,
) -> CompatibilityReport:
    """``with_timer``: the draft has a timer (``timer``, None for untimed) to compare too."""
    topic = await resolve_topic(db, ref)
    if base_version is not None and base_version != topic.current_version:
        raise _stale(topic, base_version)
    return await _report(db, topic, _validated_set(questions), dump_timer(timer), with_timer)


@writer
async def publish_version(db: AsyncSession, ref: str, body: VersionCreate) -> TopicDetail:
    # The feed lock serialises publishes, so version numbers can't race.
    topic = await resolve_topic(db, ref)
    if body.base_version != topic.current_version:
        raise _stale(topic, body.base_version)
    questions = _validated_set(body.questions)
    timer = dump_timer(body.timer)
    report = await _report(db, topic, questions, timer, with_timer=True)
    errors = [i for i in report.issues if i.level == "error"]
    if errors:
        raise IncompatibleVersion(
            "; ".join(
                i.message if i.question_key is None else f"{i.question_key}: {i.message}" for i in errors
            )
        )
    next_version = TopicVersion(
        id=uuid4(),
        topic_id=topic.id,
        version=topic.current_version + 1,
        questions=dump_questions(questions),
        timer=timer,
        change_note=body.change_note,
    )
    db.add(next_version)
    topic.current_version = next_version.version
    topic.revision += 1
    topic.updated_at = func.now()
    await _log_topic(db, topic)
    await log_change(db, FeedKind.version, FeedOp.upsert, next_version.id, topic.id)
    await db.flush()
    return await topic_detail(db, topic.id)


async def _versions(db: AsyncSession, *where: Any) -> list[tuple[TopicVersion, TopicVersionOut]]:
    entry_count = (
        select(func.count(Entry.id))
        .where(Entry.topic_id == TopicVersion.topic_id, Entry.version == TopicVersion.version)
        .scalar_subquery()
    )
    rows = (
        await db.execute(
            select(TopicVersion, entry_count).where(*where).order_by(TopicVersion.version.desc())
        )
    ).all()
    return [
        (
            v,
            TopicVersionOut(
                version=v.version,
                questions=parse_questions(v.questions),
                timer=parse_timer(v.timer),
                change_note=v.change_note,
                created_at=v.created_at,
                entry_count=n or 0,
            ),
        )
        for v, n in rows
    ]


async def list_versions(db: AsyncSession, ref: str) -> list[TopicVersionOut]:
    topic = await resolve_topic(db, ref)
    return [out for _, out in await _versions(db, TopicVersion.topic_id == topic.id)]


async def versions_by_id(db: AsyncSession, ids: list[UUID]) -> list[tuple[TopicVersion, TopicVersionOut]]:
    """The given versions that exist, with their output models."""
    return await _versions(db, TopicVersion.id.in_(ids))


async def all_questions_by_key(db: AsyncSession, topic: Topic) -> dict[str, Question]:
    """Latest definition of every question ever present in the topic (current version wins)."""
    out: dict[str, Question] = {}
    for version in await _history(db, topic):
        for q in version:
            out[q.key] = q
    return out
