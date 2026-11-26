"""Change-feed read side: ``GET /changes``.

A page is materialised in one REPEATABLE READ snapshot, so the log rows and the
entity state it returns are consistent with each other. Within a page each entity
appears once, at its latest seq: in its current state if it still exists, as a
deletion if its id is tombstoned, and not at all otherwise (its own delete row
follows in a later page).

Runs (timers.md §7.1, timers2.md §5.1) are emitted by their state in the snapshot, never by their
state at each log row: the run's latest row on the page decides whether it is on the page, its
current row decides as what. An open or finishing run is an item, whatever that row was (a page
cut between a stop and its reopen carries the item). A closed run (stopped or discarded) is a
deletion only when its latest row on the page is its own delete row, from that row; otherwise it is
skipped, which keeps its deletion off any page before its entry's row (a page cut between a reopen
and its re-stop emits nothing for it; the re-stop's delete row is on a later page). A run whose row
is gone (its topic was deleted) is a deletion at its latest row on the page, from its tombstone,
like the topic's entries; it has no entry to wait for, and clients apply a repeated deletion
idempotently. A run deletion carries the run's revision in the snapshot (null when the row is
gone), which bounds every earlier state of the run (timers2.md §5.2). A bootstrap therefore deletes
every closed run whose latest row is its delete row, which is accepted for one user.
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
    for row in rows:
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
    closed: set[Key] = set()  # closed runs, still rows: never looked up as tombstones
    closed_deleted: list[FeedDeletion] = []  # ... a deletion when their latest row is a delete row
    if ids := by_kind[FeedKind.run]:
        runs = select(Run).where(Run.id.in_(ids)).execution_options(populate_existing=True)
        for r in (await db.execute(runs)).scalars():
            key = (FeedKind.run, r.id)
            row = latest[key]
            if r.status in _LIVE:
                found[key] = FeedRun(seq=row.seq, run=await run_svc.run_out(db, r))
                continue
            closed.add(key)
            if row.op == FeedOp.delete:
                # A stop writes no tombstone (timers2.md §4.3): the deletion comes from the log row.
                closed_deleted.append(
                    FeedDeletion(
                        kind=FeedKind.run.value,
                        seq=row.seq,
                        id=r.id,
                        topic_id=row.topic_id,
                        deleted_at=row.at,
                        revision=r.revision,
                    )
                )

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
            revision=None,
        )
        for k in vanished
        if (d := tombstones.get(k)) is not None
    ]
    deleted += closed_deleted

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
