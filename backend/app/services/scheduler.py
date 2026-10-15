"""Background scheduler: push a notification when a scheduled topic becomes due.

Each tick takes a transaction-scoped Postgres advisory lock (skipping the tick
when another replica holds it), finds active topics with ``schedule.notify``
that are due for a slot not yet notified (``topics.last_notified_due_since``),
pushes one notification per topic to every subscription and records the slot.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_sessionmaker
from app.models import Entry, Topic, TopicStatus
from app.schemas.api import PushPayload
from app.services import push as push_svc
from app.services.schedule import compute_due, due_message, parse_schedule

log = logging.getLogger(__name__)

# Arbitrary, app-wide advisory lock id ("qkr" + 1).
ADVISORY_LOCK_ID = 0x716B7201


async def tick(db: AsyncSession, *, now: datetime | None = None) -> int:
    """Run one scheduler pass. Returns the number of topics notified (0 if the lock is busy)."""
    now = now or datetime.now(UTC)
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
                Topic.schedule,
                Topic.created_at,
                Topic.last_notified_due_since,
            )
            .add_columns(last_entry)
            .where(Topic.status == TopicStatus.active, Topic.schedule.is_not(None))
            .order_by(Topic.created_at)
        )
    ).all()
    notified = 0
    for topic_id, slug, name, raw_schedule, created_at, last_notified, last_entry_at in rows:
        schedule = parse_schedule(raw_schedule)
        if schedule is None or not schedule.notify:
            continue
        due = compute_due(schedule, now=now, last_entry_at=last_entry_at, created_at=created_at)
        if not due.is_due or due.due_since is None or due.due_since == last_notified:
            continue
        payload = PushPayload(
            title=name,
            body=due_message(schedule, due.due_since, now),
            url=f"/t/{slug}/record",
            tag=f"due-{topic_id}",
            topic_slug=slug,
        )
        result = await push_svc.send_to_all(db, payload)
        log.info(
            "topic %s due since %s: pushed %d, failed %d", slug, due.due_since, result.sent, result.failed
        )
        # Keep updated_at untouched: notifying is not a user edit.
        await db.execute(
            update(Topic)
            .where(Topic.id == topic_id)
            .values(last_notified_due_since=due.due_since, updated_at=Topic.updated_at)
        )
        notified += 1
    await db.commit()  # also releases the advisory lock
    return notified


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
