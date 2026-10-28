from __future__ import annotations

import csv
import io
from collections.abc import AsyncGenerator, Sequence
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import Select, delete, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import (
    Conflict,
    EntryDeleted,
    IdConflict,
    InvalidRequest,
    NotFound,
    RunTooLong,
    StaleRevision,
    TopicArchived,
)
from app.models import (
    Answer,
    Channel,
    Entry,
    FeedKind,
    FeedOp,
    Run,
    RunAlias,
    Topic,
    TopicStatus,
    TopicVersion,
)
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
    EnumListAnswer,
    FieldIssue,
    IntAnswer,
    StrAnswer,
    Timing,
    TimingEdit,
)
from app.services import run_fold
from app.services.answers import TypedAnswer, validate_answers
from app.services.feed import (
    FeedIdentity,
    ensure_identity,
    is_deleted,
    log_change,
    read_identity,
    tombstone,
    writer,
)
from app.services.topics import (
    all_questions_by_key,
    get_version,
    parse_questions,
    parse_timer,
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
        case "enum" if a.value_list is not None:
            return EnumListAnswer(key=a.question_key, value=list(a.value_list))
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
        revision=s.revision,
        source=s.source,
        channel=s.channel,
        captured_at=s.captured_at,
        created_at=s.created_at,
        updated_at=s.updated_at,
        notes=s.notes,
        meta=s.meta,
        answers=[_answer_out(a) for a in s.answers],
        timing=None if s.timing is None else Timing.model_validate(s.timing),
    )


def answer_rows(topic_id: UUID, typed: list[TypedAnswer]) -> list[Answer]:
    return [
        Answer(
            topic_id=topic_id,
            question_key=t.key,
            question_type=t.type,
            position=t.position,
            value_int=t.value_int,
            value_double=t.value_double,
            value_str=t.value_str,
            value_list=list(t.value_list) if t.value_list is not None else None,
        )
        for t in typed
    ]


def _raw_value(a: Answer) -> int | float | str | list[str]:
    if a.value_list is not None:
        return list(a.value_list)
    if a.value_int is not None:
        return a.value_int
    if a.value_double is not None:
        return a.value_double
    assert a.value_str is not None
    return a.value_str


async def _existing(db: AsyncSession, entry_id: UUID, topic_id: UUID) -> EntryOut | None:
    """Idempotent replay: the entry with this client id, if it was already recorded for the topic."""
    row = (await db.execute(select(Entry.topic_id).where(Entry.id == entry_id))).scalar_one_or_none()
    if row is None:
        return None
    if row != topic_id:
        raise Conflict(
            f"entry '{entry_id}' already exists under another topic",
            [FieldIssue(loc=["id"], message="already used by an entry of another topic")],
        )
    return await get_entry(db, entry_id)


async def is_run_id(db: AsyncSession, entity_id: UUID) -> bool:
    """Whether ``entity_id`` is a run's id or an alias, or was one (timers.md §1.1: runs and
    entries share one id space). A stopped run's id is also its entry's."""
    for stmt in (
        select(Run.id).where(Run.id == entity_id),
        select(RunAlias.id).where(RunAlias.id == entity_id),
    ):
        if await db.scalar(stmt) is not None:
            return True
    return await is_deleted(db, FeedKind.run, entity_id)


@writer
async def create_entry(db: AsyncSession, ref: str, body: EntryCreate, channel: Channel) -> EntryOut:
    """Record an entry. With a client ``id`` this is idempotent (see ``EntryCreate.id``).

    Runs under the feed lock, so a concurrent submit of the same id waits and then
    replays, and an id reserved by a delete can never be created (409 ``entry_deleted``).
    """
    # Before resolving the topic: a replayed create whose topic was deleted with it is
    # still "entry_deleted" (retire it), not a 404.
    if body.id is not None and await is_deleted(db, FeedKind.entry, body.id):
        raise EntryDeleted(f"entry '{body.id}' was deleted and can't be recreated")
    topic = await resolve_topic(db, ref)
    if body.id is not None and (existing := await _existing(db, body.id, topic.id)) is not None:
        return existing  # logged before (possibly before the topic was archived)
    if body.id is not None and await is_run_id(db, body.id):
        raise IdConflict(
            f"'{body.id}' is the id of a run that has no entry",
            [FieldIssue(loc=["id"], message="already used by a run")],
        )
    if topic.status == TopicStatus.archived:
        raise TopicArchived(f"topic '{topic.slug}' is archived; unarchive it to record entries")
    version = await get_version(db, topic, body.version)
    typed = validate_answers(parse_questions(version.questions), body.answers)
    entry = Entry(
        id=body.id or uuid4(),
        topic_id=topic.id,
        topic_version_id=version.id,
        version=version.version,
        source=body.source or channel.value,
        channel=channel,
        captured_at=body.captured_at or func.now(),
        notes=body.notes,
        meta=body.meta,
        answers=answer_rows(topic.id, typed),
    )
    db.add(entry)
    await db.flush()
    await log_change(db, FeedKind.entry, FeedOp.upsert, entry.id, topic.id)
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


@writer
async def update_entry(db: AsyncSession, entry_id: UUID, body: EntryUpdate) -> EntryOut:
    s = await _load(db, entry_id)
    if body.expected_revision is not None and body.expected_revision != s.revision:
        raise StaleRevision(
            f"entry is at revision {s.revision}, but this change was based on revision "
            f"{body.expected_revision}",
            [FieldIssue(loc=["expected_revision"], message=f"current revision is {s.revision}")],
        )
    topic = (await db.execute(select(Topic).where(Topic.id == s.topic_id))).scalar_one()
    timing: run_fold.Timing | None = None
    if body.timing is not None:
        if s.timing is None:
            raise InvalidRequest(
                "an untimed entry has no run times to edit",
                [FieldIssue(loc=["timing"], message="the entry isn't timed")],
            )
        version = await db.get_one(TopicVersion, s.topic_version_id)
        timing = edited_timing(body.timing, version_steps(version))
    elif body.captured_at is not None and s.timing is not None:
        raise InvalidRequest(
            "a timed entry's captured_at is the end of its run: edit the run's times instead",
            [FieldIssue(loc=["captured_at"], message="send timing instead")],
        )
    if body.answers is not None:
        version = await get_version(db, topic, s.version)
        existing = {a.question_key: a for a in s.answers}
        merged: dict[str, Any] = {k: _raw_value(a) for k, a in existing.items()}
        merged.update(body.answers)
        # Archived enum options the entry already holds may be kept.
        held = {k: frozenset(_enum_values(a)) for k, a in existing.items() if a.question_type == "enum"}
        typed = validate_answers(parse_questions(version.questions), merged, allowed_archived=held)
        s.answers.clear()
        await db.flush()
        s.answers.extend(answer_rows(topic.id, typed))
    if body.source is not None:
        s.source = body.source
    if body.captured_at is not None:
        s.captured_at = body.captured_at
    if body.notes is not None:
        s.notes = body.notes
    if body.meta is not None:
        s.meta = body.meta
    if timing is not None:
        s.timing = run_fold.timing_json(timing)
        s.captured_at = run_fold.from_ms(timing.ended_at)  # T1
        # The edit owns the times: later events on the run are void (timers.md §4.4).
        await db.execute(
            update(Run)
            .where(Run.id == s.id, Run.entry_id == s.id)  # a run's entry has the run's id
            .values(edited=True, revision=Run.revision + 1, updated_at=func.now())
        )
    s.revision += 1
    s.updated_at = func.now()
    await log_change(db, FeedKind.entry, FeedOp.upsert, s.id, s.topic_id)
    await db.flush()
    return await get_entry(db, s.id)


def version_steps(version: TopicVersion) -> list[run_fold.Step]:
    """The steps a run on ``version`` is timed over."""
    timer = parse_timer(version.timer)
    return [] if timer is None else [run_fold.Step(s.key, s.label) for s in timer.steps]


def edited_timing(edit: TimingEdit, steps: Sequence[run_fold.Step]) -> run_fold.Timing:
    """The entry's ``Timing`` rebuilt from an edit (timers.md §3.8), or 422 at the first field
    that breaks a rule: step keys of the run's version, each at most once (T4); segments of
    non-negative length (T2); sorted, disjoint pauses within the run (T3); at most 7 days."""
    by_key = {step.key: step for step in steps}
    seen: set[str] = set()

    def bad(loc: list[str | int], message: str) -> InvalidRequest:
        return InvalidRequest(
            f"invalid timing: {message}", [FieldIssue(loc=["timing", *loc], message=message)]
        )

    def claim(key: str, loc: list[str | int]) -> None:
        if key not in by_key:
            raise bad(loc, f"'{key}' is not a step of the run's version")
        if key in seen:
            raise bad(loc, f"step '{key}' appears more than once")
        seen.add(key)

    started_at = run_fold.to_ms(edit.started_at)
    parts: list[tuple[run_fold.Step | None, int]] = []
    previous = started_at
    for i, seg in enumerate(edit.segments):
        if (seg.kind == "step") != (seg.step is not None):
            raise bad(["segments", i, "step"], "a step segment names its step, a lap names none")
        if seg.step is not None:
            claim(seg.step, ["segments", i, "step"])
        ended_at = run_fold.to_ms(seg.ended_at)
        if ended_at < previous:
            raise bad(["segments", i, "ended_at"], "before the segment's start")
        parts.append((None if seg.step is None else by_key[seg.step], ended_at))
        previous = ended_at
    for i, key in enumerate(edit.skipped):
        claim(key, ["skipped", i])
    if previous - started_at > run_fold.MAX_RUN_MS:
        raise RunTooLong(
            "a run is at most 7 days long",
            [
                FieldIssue(
                    loc=["timing", "segments", len(parts) - 1, "ended_at"],
                    message="more than 7 days after the start",
                )
            ],
        )
    pauses: list[run_fold.Pause] = []
    floor = started_at
    for i, p in enumerate(edit.pauses):
        pause = run_fold.Pause(run_fold.to_ms(p.start), run_fold.to_ms(p.end))
        if pause.start < floor:
            raise bad(["pauses", i, "start"], "before the run's start or the previous pause's end")
        if pause.end < pause.start:
            raise bad(["pauses", i, "end"], "before the pause's start")
        if pause.end > previous:
            raise bad(["pauses", i, "end"], "after the run's end")
        pauses.append(pause)
        floor = pause.end
    skipped = sorted(edit.skipped, key=list(by_key).index)  # in step order (§2.3)
    timing = run_fold.make_timing(started_at, parts, skipped, pauses, steps=steps, edited=True)
    try:
        run_fold.check_timing(timing, captured_at=timing.ended_at)  # T1 to T5
    except run_fold.TimingError as exc:  # a guard: the checks above cover every way an edit breaks them
        raise bad([], str(exc)) from exc
    return timing


def _enum_values(a: Answer) -> list[str]:
    if a.value_list is not None:
        return list(a.value_list)
    return [a.value_str] if a.value_str is not None else []


def _csv_value(v: int | float | str | list[str]) -> int | float | str:
    return ";".join(v) if isinstance(v, list) else v


@writer
async def delete_entry(db: AsyncSession, entry_id: UUID) -> None:
    """Delete an entry and reserve its id forever. Idempotent: an unknown id is reserved too,
    so a create that arrives after its own undo (a delayed POST) can never materialise."""
    topic_id = await db.scalar(select(Entry.topic_id).where(Entry.id == entry_id))
    await tombstone(db, FeedKind.entry, entry_id, topic_id)
    if topic_id is not None:
        await db.execute(delete(Entry).where(Entry.id == entry_id))
        await log_change(db, FeedKind.entry, FeedOp.delete, entry_id, topic_id)
        # A run's entry: the run stays, and later events on it are void (timers.md §4.4).
        await db.execute(
            update(Run)
            .where(Run.id == entry_id, Run.entry_id == entry_id)
            .values(entry_id=None, revision=Run.revision + 1, updated_at=func.now())
        )


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


async def export_csv(
    db: AsyncSession, ref: str, filters: EntryFilters
) -> tuple[FeedIdentity, AsyncGenerator[str]]:
    """A CSV export read from one REPEATABLE READ snapshot, and that snapshot's identity.

    The snapshot stays open while the rows stream (label the response with the returned
    identity, not one read later). The generator ends the transaction when it finishes
    or is closed; if it never runs, closing the session does.
    """
    await ensure_identity(db)  # its own short transaction; commits
    await db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
    try:
        identity = await read_identity(db)
        return identity, await _export(db, ref, filters)
    except Exception:
        await db.rollback()
        raise


async def _export(db: AsyncSession, ref: str, filters: EntryFilters) -> AsyncGenerator[str]:
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
                *[_csv_value(by_key.get(k, "")) for k in keys],
            ]
        )

    async def gen() -> AsyncGenerator[str]:
        try:
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
        finally:
            await db.rollback()  # ends the snapshot (also on client disconnect)

    return gen()
