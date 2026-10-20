"""Background scheduler: push a notification when a scheduled topic becomes due.

Each tick takes a transaction-scoped Postgres advisory lock (skipping the tick
when another replica holds it), finds active topics with ``schedule.notify``
that are due for a slot not yet notified (``topics.last_notified_due_since``),
pushes one notification per topic to every target (browser subscriptions and APNs
devices, concurrently) and records the slot. Each notification carries what an action
needs to log the topic from it: the server id, the topic's current version, the slot and
its ``quick_log`` descriptor (:func:`prepare_quick_logs`; docs/ios/specs/notifications.md §2).

Delivery semantics: send, then mark. The tick's targets are loaded once; the delivery
outcomes (success, failure counts, gone targets) and the notified slots are written
only just before the commit, so no target or topic row is locked during the network
calls. If the tick fails before its commit, nothing is marked and the next tick sends
those slots again: every slot goes out at least once overall, and best-effort to each
target (a target that fails is not retried; the shared tag ``due-{topic_id}``
collapses a resent duplicate on the device).

Delivery stops ``TICK_BUDGET_SECONDS`` after it starts (once the tick's reads are done,
so slow preparation never starves it), mid-topic if need be.
The topic being delivered then is not marked (some of its sends were cut off). The
targets whose send did finish are recorded for that slot (``push_slot_deliveries``, in
the same commit), and the next tick resumes with the others, so a fan-out larger than
one tick's budget still completes, each target getting the slot once, in a few ticks.
Due topics go oldest slot first, so the remaining topics follow. (Progress needs one
send to fit in the budget: the per-send timeouts are well under it.) The progress rows
are deleted when the slot is marked. A slot that is still due keeps its progress however
long it takes; the progress of an abandoned slot (the topic moved on to a newer slot, an
entry satisfied it, the topic was archived or silenced) goes after ``SLOT_PROGRESS_TTL``.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

from sqlalchemy import DateTime, String, Uuid, column, delete, func, select, text, tuple_, update, values
from sqlalchemy.dialects.postgresql import distinct_on, insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_sessionmaker
from app.models import Answer, Entry, PushSlotDelivery, Topic, TopicStatus, TopicVersion
from app.schemas.api import QuickLogDescriptor
from app.schemas.questions import Question
from app.services import push as push_svc
from app.services.feed import feed_identity
from app.services.notification import MAX_SHOWN_OPTIONS, descriptor
from app.services.push import Notification
from app.services.quicklog import QuickLogChips, quick_log_for
from app.services.schedule import compute_due, due_message, parse_schedule
from app.services.topics import parse_questions

log = logging.getLogger(__name__)

# Arbitrary, app-wide advisory lock id ("qkr" + 1), scoped to this database like every
# advisory lock (see feed.FEED_LOCK_ID).
ADVISORY_LOCK_ID = 0x716B7201
# Delivery stops this long after it starts; unfinished topics wait for the next tick.
TICK_BUDGET_SECONDS = 30.0
# Progress of a slot that is no longer due (e.g. a new entry moved the topic on) is dropped.
SLOT_PROGRESS_TTL = timedelta(days=2)

type Slot = tuple[UUID, datetime]  # (topic id, due_since)
type Progress = tuple[UUID, datetime, str, UUID]  # a slot, and a target (kind, id) it reached


async def tick(db: AsyncSession, *, now: datetime | None = None) -> int:
    """Run one scheduler pass. Returns the number of topics notified (0 if the lock is busy)."""
    now = now or datetime.now(UTC)
    server_id = (await feed_identity(db)).server_id  # ends its read with a rollback: before the lock
    locked = await db.scalar(text("SELECT pg_try_advisory_xact_lock(:id)"), {"id": ADVISORY_LOCK_ID})
    if not locked:
        await db.rollback()
        return 0
    last_entry = (
        select(func.max(Entry.captured_at))
        .where(Entry.topic_id == Topic.id)
        .correlate(Topic)
        .scalar_subquery()
    )
    rows = (
        await db.execute(
            select(
                Topic.id,
                Topic.slug,
                Topic.name,
                Topic.current_version,
                Topic.schedule,
                func.coalesce(Topic.schedule_updated_at, Topic.created_at),
                Topic.last_notified_due_since,
            )
            .add_columns(last_entry)
            .where(Topic.status == TopicStatus.active, Topic.schedule.is_not(None))
            .order_by(Topic.created_at)
        )
    ).all()
    due: list[tuple[datetime, UUID, str, str, int, str]] = []
    for topic_id, slug, name, version, raw_schedule, since, last_notified, last_entry_at in rows:
        schedule = parse_schedule(raw_schedule)
        if schedule is None or not schedule.notify:
            continue
        status = compute_due(schedule, now=now, last_entry_at=last_entry_at, schedule_since=since)
        if not status.is_due or status.due_since is None or status.due_since == last_notified:
            continue
        message = due_message(schedule, status.due_since, now)
        due.append((status.due_since, topic_id, slug, name, version, message))
    due.sort(key=lambda t: t[0])  # oldest slot first (stable: then creation order)

    # Every read happens before any send (no query may autoflush mid-tick), and before the
    # delivery budget starts: however long preparing takes, each tick still delivers.
    due_topics: list[tuple[datetime, UUID, str, Notification]] = []
    targets: list[push_svc.Pair] = []
    reached: set[Progress] = set()
    if due:
        questions = await _questions(db, [(topic_id, version) for _, topic_id, _, _, version, _ in due])
        quick_logs = await prepare_quick_logs(db, questions)
        for due_since, topic_id, slug, name, version, message in due:
            notification = Notification(
                kind="due",
                title=name,
                body=message,
                url=f"/t/{slug}/record",
                tag=f"due-{topic_id}",
                topic_slug=slug,
                server_id=server_id,
                topic_id=topic_id,
                version=version,
                due_since=due_since,
                quick_log=quick_logs.get(topic_id),
            )
            due_topics.append((due_since, topic_id, slug, notification))
        targets = await push_svc.targets(db)
        reached = await _slot_progress(db)
    deadline = asyncio.get_running_loop().time() + TICK_BUDGET_SECONDS
    marks: list[Slot] = []
    progress: list[Progress] = []
    for due_since, topic_id, slug, notification in due_topics:
        pending = [(s, t) for s, t in targets if (topic_id, due_since, s.kind, t.id) not in reached]
        delivery = await push_svc.deliver(
            db, pending, notification, push_svc.DEFAULT_TTL_SECONDS, deadline=deadline
        )
        log.info(
            "topic %s due since %s: pushed %d, failed %d (%d of %d targets reached before)",
            slug,
            due_since,
            delivery.sent,
            delivery.failed,
            len(targets) - len(pending),
            len(targets),
        )
        if not delivery.complete:
            progress = [(topic_id, due_since, s.kind, t.id) for s, t in delivery.finished]
            log.warning("scheduler tick over budget; topic %s resumes next tick, with the rest", slug)
            break
        marks.append((topic_id, due_since))
    await db.flush()  # the delivery outcomes
    active = [(topic_id, due_since) for due_since, topic_id, _, _ in due_topics]
    await _record_progress(db, progress, marks, active)
    if marks:
        await _mark_notified(db, marks)
    await db.commit()  # also releases the advisory lock
    return len(marks)


async def _questions(db: AsyncSession, versions: list[tuple[UUID, int]]) -> dict[UUID, list[Question]]:
    """The questions of each ``(topic id, version)``, by topic id."""
    rows = await db.execute(
        select(TopicVersion.topic_id, TopicVersion.questions).where(
            tuple_(TopicVersion.topic_id, TopicVersion.version).in_(versions)
        )
    )
    return {topic_id: parse_questions(raw) for topic_id, raw in rows}


async def prepare_quick_logs(
    db: AsyncSession, questions: dict[UUID, list[Question]]
) -> dict[UUID, QuickLogDescriptor | None]:
    """Each topic's ``quick_log`` descriptor (docs/ios/specs/notifications.md §2.3), in at
    most two queries whatever the number of topics.

    Enums with 5-6 active options: how many of the topic's entries (any version) chose each
    option, to rank the most-used (with fewer, all are shown and counts don't matter).
    Numbers: the latest numeric answer for the key, by ``captured_at`` then entry id, which
    the descriptor keeps only while the question still accepts it.
    """
    ranked: list[tuple[UUID, str]] = []
    numbers: list[tuple[UUID, str]] = []
    for topic_id, qs in questions.items():
        quick = quick_log_for(qs)
        if isinstance(quick, QuickLogChips):
            if len(quick.options) > MAX_SHOWN_OPTIONS:
                ranked.append((topic_id, quick.question.key))
        elif quick is not None:
            numbers.append((topic_id, quick.question.key))
    answered = tuple_(Answer.topic_id, Answer.question_key)
    counts: dict[UUID, dict[str, int]] = {}
    if ranked:
        counted = await db.execute(
            select(Answer.topic_id, Answer.value_str, func.count())
            .where(answered.in_(ranked), Answer.question_type == "enum", Answer.value_str.is_not(None))
            .group_by(Answer.topic_id, Answer.value_str)
        )
        for topic_id, value, n in counted:
            if value is not None:
                counts.setdefault(topic_id, {})[value] = n
    last: dict[UUID, int | float | None] = {}
    if numbers:
        latest = await db.execute(
            select(Answer.topic_id, Answer.value_int, Answer.value_double)
            .join(Entry, Entry.id == Answer.entry_id)
            .where(answered.in_(numbers), Answer.question_type.in_(["int", "double"]))
            .ext(distinct_on(Answer.topic_id))
            .order_by(Answer.topic_id, Entry.captured_at.desc(), Entry.id.desc())
        )
        for topic_id, value_int, value_double in latest:
            last[topic_id] = value_int if value_int is not None else value_double
    return {
        topic_id: descriptor(qs, counts=counts.get(topic_id, {}), last=last.get(topic_id))
        for topic_id, qs in questions.items()
    }


async def _slot_progress(db: AsyncSession) -> set[Progress]:
    rows = await db.execute(
        select(
            PushSlotDelivery.topic_id,
            PushSlotDelivery.due_since,
            PushSlotDelivery.target_kind,
            PushSlotDelivery.target_id,
        )
    )
    return {(r.topic_id, r.due_since, r.target_kind, r.target_id) for r in rows}


async def _record_progress(
    db: AsyncSession, progress: list[Progress], marks: list[Slot], active: list[Slot]
) -> None:
    """Save the unfinished slot's reached targets; forget marked slots, and abandoned ones
    (not among the ``active`` due, unmarked slots) after ``SLOT_PROGRESS_TTL``."""
    if progress:
        reached = values(
            column("topic_id", Uuid()),
            column("due_since", DateTime(timezone=True)),
            column("target_kind", String()),
            column("target_id", Uuid()),
            name="reached",
        ).data(progress)
        # Joined to topics: a topic deleted meanwhile is skipped rather than failing the tick.
        rows = select(reached).join(Topic, Topic.id == reached.c.topic_id)
        await db.execute(
            insert(PushSlotDelivery)
            .from_select(["topic_id", "due_since", "target_kind", "target_id"], rows)
            .on_conflict_do_nothing()
        )
    if marks:
        await db.execute(
            delete(PushSlotDelivery).where(PushSlotDelivery.topic_id.in_([topic_id for topic_id, _ in marks]))
        )
    abandoned = PushSlotDelivery.created_at < func.now() - SLOT_PROGRESS_TTL
    if active:
        slot = tuple_(PushSlotDelivery.topic_id, PushSlotDelivery.due_since)
        abandoned = abandoned & slot.not_in(active)
    await db.execute(delete(PushSlotDelivery).where(abandoned))


async def _mark_notified(db: AsyncSession, marks: list[Slot]) -> None:
    """Record the notified slots in one statement."""
    slots = values(column("id", Uuid()), column("due_since", DateTime(timezone=True)), name="slots").data(
        marks
    )
    # Keep updated_at untouched: notifying is not a user edit.
    await db.execute(
        update(Topic)
        .where(Topic.id == slots.c.id)
        .values(last_notified_due_since=slots.c.due_since, updated_at=Topic.updated_at)
    )


async def run_forever(interval_seconds: float) -> None:
    """Tick forever. Errors are logged and never stop the loop."""
    while True:
        try:
            async with get_sessionmaker()() as db:
                await tick(db)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("scheduler tick failed")
        await asyncio.sleep(interval_seconds)


@asynccontextmanager
async def lifespan(_app: Any) -> AsyncIterator[None]:
    """App lifespan that runs the scheduler in the background when enabled."""
    settings = get_settings()
    task: asyncio.Task[None] | None = None
    if settings.scheduler_enabled:
        task = asyncio.create_task(run_forever(settings.scheduler_interval_seconds), name="quickr-scheduler")
    try:
        yield
    finally:
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
