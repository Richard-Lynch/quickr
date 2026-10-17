"""Change-feed write side: one write order, the change log, tombstones and feed identity.

Every mutating service function is wrapped in :func:`writer`. It takes the feed
advisory lock as the transaction's first statement, before any row or foreign-key
lock, so all writers are serialised: ``change_log.seq`` (allocated after the lock)
follows commit order, and a reader never sees seq N+1 without seq N. The scheduler
uses its own lock (``scheduler.ADVISORY_LOCK_ID``) and never this one, so the two
can't deadlock on each other's advisory locks.

Deletions are permanent: ``deleted_ids`` keeps every deleted id, so a late or
replayed create of a deleted entry gets 409 ``entry_deleted`` instead of bringing
it back.

The read side (``GET /changes``) is in :mod:`app.services.changes`.
"""

from __future__ import annotations

import functools
import itertools
import logging
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from typing import Any, Concatenate
from uuid import UUID, uuid4

from sqlalchemy import select, text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AppSetting, ChangeLog, DeletedId, FeedKind, FeedOp

log = logging.getLogger(__name__)

# Arbitrary, app-wide advisory lock id ("qkr" + 2); the scheduler uses "qkr" + 1.
FEED_LOCK_ID = 0x716B7202
MAX_ATTEMPTS = 3
# deadlock_detected, serialization_failure
RETRYABLE_SQLSTATES = frozenset({"40P01", "40001"})

EPOCH_SETTING = "feed_epoch"
SERVER_ID_SETTING = "server_id"


def _retryable(exc: DBAPIError) -> bool:
    return getattr(exc.orig, "sqlstate", None) in RETRYABLE_SQLSTATES


def writer[**P, T](
    fn: Callable[Concatenate[AsyncSession, P], Coroutine[Any, Any, T]],
) -> Callable[Concatenate[AsyncSession, P], Coroutine[Any, Any, T]]:
    """Run a mutating service function under the feed lock, retrying deadlocks.

    The wrapped function does its writes and commits. A transaction left open by
    earlier reads on the session is committed first, so the lock really is the first
    statement. Deadlocks and serialization failures re-run the whole function (up to
    ``MAX_ATTEMPTS``); any other error rolls back, releasing the lock, and propagates.
    """

    async def run(db: AsyncSession, /, *args: P.args, **kwargs: P.kwargs) -> T:
        for attempt in itertools.count(1):
            if db.in_transaction():
                await db.commit()
            try:
                await db.execute(text("SELECT pg_advisory_xact_lock(:id)"), {"id": FEED_LOCK_ID})
                result = await fn(db, *args, **kwargs)
            except DBAPIError as exc:
                await db.rollback()
                if attempt >= MAX_ATTEMPTS or not _retryable(exc):
                    raise
                log.warning("%s: retrying after %s (attempt %d)", fn.__name__, exc.orig, attempt)
                continue
            except Exception:
                await db.rollback()
                raise
            if db.in_transaction():
                await db.commit()  # a path that returned without writing still holds the lock
            return result
        raise AssertionError("unreachable")

    return functools.update_wrapper(run, fn)


async def log_change(db: AsyncSession, kind: FeedKind, op: FeedOp, entity_id: UUID, topic_id: UUID) -> None:
    """Append a feed row. Call inside a :func:`writer` transaction."""
    await db.execute(insert(ChangeLog).values(kind=kind, op=op, entity_id=entity_id, topic_id=topic_id))


async def is_deleted(db: AsyncSession, entity_id: UUID) -> bool:
    return (await db.scalar(select(DeletedId.id).where(DeletedId.id == entity_id))) is not None


async def tombstone(db: AsyncSession, kind: FeedKind, entity_id: UUID, topic_id: UUID | None) -> None:
    """Reserve a deleted id forever (idempotent)."""
    await db.execute(
        insert(DeletedId).values(id=entity_id, kind=kind, topic_id=topic_id).on_conflict_do_nothing()
    )


# --- feed identity ------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class FeedIdentity:
    epoch: str
    server_id: str


async def _stored_identity(db: AsyncSession) -> dict[str, str]:
    rows = await db.execute(
        select(AppSetting.key, AppSetting.value).where(AppSetting.key.in_([EPOCH_SETTING, SERVER_ID_SETTING]))
    )
    return {row.key: row.value for row in rows}


async def feed_identity(db: AsyncSession) -> FeedIdentity:
    """The feed epoch and server id, generated once on first use (the migration seeds them)."""
    stored = await _stored_identity(db)
    if len(stored) < 2:
        await db.execute(
            insert(AppSetting)
            .values([{"key": k, "value": str(uuid4())} for k in (EPOCH_SETTING, SERVER_ID_SETTING)])
            .on_conflict_do_nothing(index_elements=["key"])
        )
        await db.commit()
        stored = await _stored_identity(db)
    return FeedIdentity(epoch=stored[EPOCH_SETTING], server_id=stored[SERVER_ID_SETTING])


async def rotate_epoch(db: AsyncSession) -> str:
    """Start a new feed epoch: every client rebuilds its server layer (keeping its outbox).

    Run after restoring or resetting the database (``make rotate-epoch``).
    """
    epoch = str(uuid4())
    stmt = insert(AppSetting).values(key=EPOCH_SETTING, value=epoch)
    await db.execute(stmt.on_conflict_do_update(index_elements=["key"], set_={"value": epoch}))
    await db.commit()
    return epoch
