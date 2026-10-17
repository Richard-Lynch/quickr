"""Change-feed read side: ``GET /changes``.

A page is materialised in one REPEATABLE READ snapshot, so the log rows and the
entity state it returns are consistent with each other. Within a page each entity
appears once, at its latest seq: in its current state if it still exists, as a
deletion if its id is tombstoned, and not at all otherwise (its own delete row
follows in a later page).
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ChangeLog, DeletedId, Entry, FeedKind
from app.schemas.api import ChangesPage, FeedDeletion, FeedEntry, FeedItem, FeedTopic, FeedVersion
from app.services import entries as entry_svc
from app.services import topics as topic_svc
from app.services.feed import feed_identity

MAX_PAGE = 500
# Order a page is applied in: parents before children, and the reverse for deletions.
_APPLY_ORDER = {FeedKind.topic: 0, FeedKind.version: 1, FeedKind.entry: 2}


async def list_changes(db: AsyncSession, after: int = 0, limit: int = MAX_PAGE) -> ChangesPage:
    identity = await feed_identity(db)
    if db.in_transaction():
        await db.commit()
    await db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
    try:
        return await _page(db, after, min(limit, MAX_PAGE), identity.epoch, identity.server_id)
    finally:
        await db.rollback()  # ends the snapshot


async def _page(db: AsyncSession, after: int, limit: int, epoch: str, server_id: str) -> ChangesPage:
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
    latest: dict[UUID, ChangeLog] = {}  # ids are UUIDs, unique across kinds
    for row in rows:
        latest.pop(row.entity_id, None)
        latest[row.entity_id] = row  # re-insert: dict order = order of latest seq
    by_kind: dict[FeedKind, list[UUID]] = {k: [] for k in FeedKind}
    for row in latest.values():
        by_kind[row.kind].append(row.entity_id)

    found: dict[UUID, FeedItem] = {}
    if ids := by_kind[FeedKind.topic]:
        for topic_id, detail in (await topic_svc.topic_details(db, ids)).items():
            found[topic_id] = FeedTopic(seq=latest[topic_id].seq, topic=detail)
    if ids := by_kind[FeedKind.version]:
        for v, out in await topic_svc.versions_by_id(db, ids):
            found[v.id] = FeedVersion(seq=latest[v.id].seq, id=v.id, topic_id=v.topic_id, version=out)
    if ids := by_kind[FeedKind.entry]:
        stmt = select(Entry).where(Entry.id.in_(ids)).execution_options(populate_existing=True)
        for e in (await db.execute(stmt)).scalars():
            found[e.id] = FeedEntry(seq=latest[e.id].seq, entry=entry_svc.entry_out(e))

    vanished = [i for i in latest if i not in found]
    tombstones = (
        {d.id: d for d in (await db.execute(select(DeletedId).where(DeletedId.id.in_(vanished)))).scalars()}
        if vanished
        else {}
    )
    deleted = [
        # The log row's topic_id: a tombstone's is null only for ids that were never logged.
        FeedDeletion(
            kind=d.kind.value, seq=latest[i].seq, id=i, topic_id=latest[i].topic_id, deleted_at=d.deleted_at
        )
        for i in vanished
        if (d := tombstones.get(i)) is not None
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
        epoch=epoch,
        server_id=server_id,
        server_time=server_time,
    )
