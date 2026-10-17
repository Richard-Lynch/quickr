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
from contextvars import ContextVar
from dataclasses import dataclass
from typing import Any, Concatenate
from uuid import UUID, uuid4

from sqlalchemy import select, text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import EpochMismatch, ServerMismatch
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


_IN_WRITER = "quickr_feed_writer"


class WriterMisuse(RuntimeError):
    """A writer was called on a session that already has work in flight."""


def writer[**P, T](
    fn: Callable[Concatenate[AsyncSession, P], Coroutine[Any, Any, T]],
) -> Callable[Concatenate[AsyncSession, P], Coroutine[Any, Any, T]]:
    """Run a mutating service function as one transaction under the feed lock.

    The outermost writer owns the transaction: it takes the lock as the first
    statement, runs the function, and commits. The wrapped function never commits;
    it may flush and read back its own writes. A writer called from inside another
    (on the same session) just runs as part of the outer transaction.

    The session must be idle: pending ORM changes or an open transaction (whose
    flushed writes would otherwise be committed outside the lock) raise
    :class:`WriterMisuse`. Right after taking the lock, on every attempt, the request's
    expected identity (:data:`expected_identity`) is checked against the stored one,
    so a precondition can't pass and then race an epoch rotation (which takes the
    same lock). Deadlocks and serialization failures, including at commit,
    roll back and re-run the whole function (up to ``MAX_ATTEMPTS``); any other error
    rolls back, releasing the lock, and propagates.
    """

    async def run(db: AsyncSession, /, *args: P.args, **kwargs: P.kwargs) -> T:
        if db.info.get(_IN_WRITER):
            return await fn(db, *args, **kwargs)  # nested: the outer writer locks and commits
        if db.new or db.dirty or db.deleted or db.in_transaction():
            raise WriterMisuse(f"{fn.__name__} needs an idle session: commit or roll back earlier work first")
        db.info[_IN_WRITER] = True
        try:
            for attempt in itertools.count(1):
                try:
                    await db.execute(text("SELECT pg_advisory_xact_lock(:id)"), {"id": FEED_LOCK_ID})
                    await _check_expected_identity(db)
                    result = await fn(db, *args, **kwargs)
                    await db.commit()
                except DBAPIError as exc:
                    await db.rollback()
                    if attempt >= MAX_ATTEMPTS or not _retryable(exc):
                        raise
                    log.warning("%s: retrying after %s (attempt %d)", fn.__name__, exc.orig, attempt)
                    continue
                except Exception:
                    await db.rollback()
                    raise
                return result
            raise AssertionError("unreachable")
        finally:
            db.info.pop(_IN_WRITER, None)

    return functools.update_wrapper(run, fn)


async def log_change(db: AsyncSession, kind: FeedKind, op: FeedOp, entity_id: UUID, topic_id: UUID) -> None:
    """Append a feed row. Call inside a :func:`writer` transaction."""
    await db.execute(insert(ChangeLog).values(kind=kind, op=op, entity_id=entity_id, topic_id=topic_id))


async def is_deleted(db: AsyncSession, kind: FeedKind, entity_id: UUID) -> bool:
    stmt = select(DeletedId.id).where(DeletedId.kind == kind, DeletedId.id == entity_id)
    return (await db.scalar(stmt)) is not None


async def tombstone(db: AsyncSession, kind: FeedKind, entity_id: UUID, topic_id: UUID | None) -> None:
    """Reserve a deleted id forever (idempotent)."""
    await db.execute(
        insert(DeletedId)
        .values(kind=kind, id=entity_id, topic_id=topic_id)
        .on_conflict_do_nothing(index_elements=["kind", "id"])
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


async def ensure_identity(db: AsyncSession) -> None:
    """Generate the epoch and server id if missing (the migration seeds them). Commits."""
    if len(await _stored_identity(db)) < 2:
        await db.execute(
            insert(AppSetting)
            .values([{"key": k, "value": str(uuid4())} for k in (EPOCH_SETTING, SERVER_ID_SETTING)])
            .on_conflict_do_nothing(index_elements=["key"])
        )
    await db.commit()


async def read_identity(db: AsyncSession) -> FeedIdentity:
    """The stored identity, read in the caller's transaction (after :func:`ensure_identity`)."""
    stored = await _stored_identity(db)
    return FeedIdentity(epoch=stored[EPOCH_SETTING], server_id=stored[SERVER_ID_SETTING])


async def feed_identity(db: AsyncSession) -> FeedIdentity:
    """The feed epoch and server id (generated on first use). One query once they exist;
    leaves no transaction open."""
    stored = await _stored_identity(db)
    await db.commit()
    if len(stored) < 2:
        await ensure_identity(db)
        stored = await _stored_identity(db)
        await db.commit()
    return FeedIdentity(epoch=stored[EPOCH_SETTING], server_id=stored[SERVER_ID_SETTING])


@writer
async def rotate_epoch(db: AsyncSession) -> str:
    """Start a new feed epoch: every client rebuilds its server layer (keeping its outbox).

    Run after restoring or resetting the database (``make rotate-epoch``). Takes the
    feed lock, so no mutation can check its expected epoch against the old one and
    commit after the rotation.
    """
    epoch = str(uuid4())
    stmt = insert(AppSetting).values(key=EPOCH_SETTING, value=epoch)
    await db.execute(stmt.on_conflict_do_update(index_elements=["key"], set_={"value": epoch}))
    return epoch


# --- mutation preconditions -----------------------------------------------------


@dataclass(frozen=True, slots=True)
class ExpectedIdentity:
    server_id: str | None
    epoch: str | None


# Set per request from the X-QuickR-Expect-* headers (app.api.identity); None = no check.
expected_identity: ContextVar[ExpectedIdentity | None] = ContextVar("expected_identity", default=None)


@writer
async def check_identity(db: AsyncSession) -> None:
    """Check the request's expected identity under the feed lock, writing nothing.

    For an action whose effects can't run inside a (retried) writer transaction, such
    as sending push messages: check here first, then act.
    """


async def _check_expected_identity(db: AsyncSession) -> None:
    """Raise 409 server_mismatch / epoch_mismatch unless the stored identity matches."""
    expected = expected_identity.get()
    if expected is None:
        return
    stored = await _stored_identity(db)
    server_id, epoch = stored.get(SERVER_ID_SETTING), stored.get(EPOCH_SETTING)
    if expected.server_id is not None and expected.server_id != server_id:
        raise ServerMismatch(f"this is server '{server_id}', not '{expected.server_id}'")
    if expected.epoch is not None and expected.epoch != epoch:
        raise EpochMismatch(f"the feed epoch is '{epoch}', not '{expected.epoch}'; resync from after=0")
