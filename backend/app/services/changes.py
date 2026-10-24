"""Change-feed read side: ``GET /changes``.

A page is materialised in one REPEATABLE READ snapshot, so the log rows and the
entity state it returns are consistent with each other. Within a page each entity
appears once, at its latest seq: in its current state if it still exists, as a
deletion if its id is tombstoned, and not at all otherwise (its own delete row
follows in a later page).

Runs (timers.md §7.1) are items only while open or finishing. A closed run is still a
row, so it is a deletion only when its own delete row is on the page; otherwise it is
skipped, which keeps its deletion off any page before its entry's row. A run whose row
is gone (its topic was deleted) is the exception: it is a deletion at its latest row on
the page, like the topic's entries; it has no entry to wait for, and clients apply a
repeated deletion idempotently. A bootstrap therefore deletes every closed run ever, which
is accepted for one user.
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import func, select, text, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ChangeLog, DeletedId, Entry, FeedKind, FeedOp, Run, RunStatus
from app.schemas.api import (
    ChangesPage,
    FeedDeletion,
    FeedEntry,
    FeedItem,
    FeedRun,
    FeedTopic,
    FeedVersion,
)
from app.services import entries as entry_svc
from app.services import runs as run_svc
from app.services import topics as topic_svc
from app.services.feed import ensure_identity, read_identity

MAX_PAGE = 500
# Order a page is applied in: parents before children, and the reverse for deletions.
_APPLY_ORDER = {FeedKind.topic: 0, FeedKind.version: 1, FeedKind.entry: 2, FeedKind.run: 3}
# A run in these statuses is a feed item; in the others it is closed (stopped or discarded).
_LIVE = (RunStatus.running, RunStatus.paused, RunStatus.finishing)

# Ids are only unique per kind (entry ids are client-chosen), so entities are keyed by both.
Key = tuple[FeedKind, UUID]


async def list_changes(db: AsyncSession, after: int = 0, limit: int = MAX_PAGE) -> ChangesPage:
    await ensure_identity(db)  # its own short transaction; commits
    await db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
    try:
        return await _page(db, after, min(limit, MAX_PAGE))
    finally:
        await db.rollback()  # ends the snapshot


async def _page(db: AsyncSession, after: int, limit: int) -> ChangesPage:
    # Everything below, the identity included, comes from one snapshot.
    identity = await read_identity(db)
    server_time = await db.scalar(select(func.now()))
    head = await db.scalar(select(func.coalesce(func.max(ChangeLog.seq), 0)))
    assert server_time is not None
    assert head is not None
    rows = (
        (
            await db.execute(
                select(ChangeLog).where(ChangeLog.seq > after).order_by(ChangeLog.seq).limit(limit)
            )
        )
        .scalars()
        .all()
    )
    latest: dict[Key, ChangeLog] = {}
    run_deletes: set[UUID] = set()  # runs whose own delete row is on this page
    for row in rows:
        if row.kind == FeedKind.run and row.op == FeedOp.delete:
            run_deletes.add(row.entity_id)
        key = (row.kind, row.entity_id)
        latest.pop(key, None)
        latest[key] = row  # re-insert: dict order = order of latest seq
    by_kind: dict[FeedKind, list[UUID]] = {k: [] for k in FeedKind}
    for kind, entity_id in latest:
        by_kind[kind].append(entity_id)

    found: dict[Key, FeedItem] = {}
    if ids := by_kind[FeedKind.topic]:
        for topic_id, detail in (await topic_svc.topic_details(db, ids)).items():
            key = (FeedKind.topic, topic_id)
            found[key] = FeedTopic(seq=latest[key].seq, topic=detail)
    if ids := by_kind[FeedKind.version]:
        for v, out in await topic_svc.versions_by_id(db, ids):
            key = (FeedKind.version, v.id)
            found[key] = FeedVersion(seq=latest[key].seq, id=v.id, topic_id=v.topic_id, version=out)
    if ids := by_kind[FeedKind.entry]:
        entries = select(Entry).where(Entry.id.in_(ids)).execution_options(populate_existing=True)
        for e in (await db.execute(entries)).scalars():
            key = (FeedKind.entry, e.id)
            found[key] = FeedEntry(seq=latest[key].seq, entry=entry_svc.entry_out(e))
    closed: set[Key] = set()  # closed runs, still rows: a deletion only with their delete row
    if ids := by_kind[FeedKind.run]:
        runs = select(Run).where(Run.id.in_(ids)).execution_options(populate_existing=True)
        for r in (await db.execute(runs)).scalars():
            key = (FeedKind.run, r.id)
            if r.status in _LIVE:
                found[key] = FeedRun(seq=latest[key].seq, run=await run_svc.run_out(db, r))
            elif r.id not in run_deletes:
                closed.add(key)

    # A run without a row went with its topic and is tombstoned like the topic's other children.
    vanished = [k for k in latest if k not in found and k not in closed]
    tombstones: dict[Key, DeletedId] = {}
    if vanished:
        tomb_stmt = select(DeletedId).where(tuple_(DeletedId.kind, DeletedId.id).in_(vanished))
        tombstones = {(d.kind, d.id): d for d in (await db.execute(tomb_stmt)).scalars()}
    deleted = [
        # The log row's topic_id: a tombstone's is null only for ids that were never logged.
        FeedDeletion(
            kind=k[0].value,
            seq=latest[k].seq,
            id=k[1],
            topic_id=latest[k].topic_id,
            deleted_at=d.deleted_at,
        )
        for k in vanished
        if (d := tombstones.get(k)) is not None
    ]

    items = sorted(found.values(), key=lambda it: (_APPLY_ORDER[FeedKind(it.kind)], it.seq))
    deleted.sort(key=lambda d: (-_APPLY_ORDER[FeedKind(d.kind)], d.seq))
    next_seq = rows[-1].seq if rows else after
    return ChangesPage(
        items=items,
        deleted=deleted,
        next=next_seq,
        has_more=head > next_seq,
        head=head,
        epoch=identity.epoch,
        server_id=identity.server_id,
        server_time=server_time,
    )
