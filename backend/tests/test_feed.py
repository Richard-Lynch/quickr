"""The change feed: write order, tombstones, revisions and ``GET /changes``."""

from __future__ import annotations

import asyncio
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
from fastmcp import Client
from sqlalchemy import func, select, text, update
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.mcp_server import mcp
from app.models import ChangeLog, DeletedId, Entry, FeedKind, FeedOp
from app.schemas.api import TopicCreate
from app.services import feed
from app.services import topics as topic_svc
from tests.helpers import make_topic, record, sleep_questions, wait_for_lock_waiter

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}


async def changes(client: httpx.AsyncClient, after: int = 0, limit: int = 500) -> dict[str, Any]:
    r = await client.get("/changes", params={"after": after, "limit": limit})
    assert r.status_code == 200, r.text
    body: dict[str, Any] = r.json()
    return body


async def drain(client: httpx.AsyncClient, after: int = 0, limit: int = 500) -> list[dict[str, Any]]:
    """Every page from ``after`` until ``has_more`` is false."""
    pages = []
    while True:
        page = await changes(client, after, limit)
        pages.append(page)
        assert page["next"] >= after
        after = page["next"]
        if not page["has_more"]:
            return pages


def kinds(page: dict[str, Any]) -> list[tuple[str, str]]:
    def ident(i: dict[str, Any]) -> str:
        return str(i["id"] if "id" in i else i[i["kind"]]["id"])

    return [(i["kind"], ident(i)) for i in page["items"]]


async def log_rows() -> list[tuple[FeedKind, FeedOp, UUID]]:
    async with get_sessionmaker()() as db:
        rows = await db.execute(
            select(ChangeLog.kind, ChangeLog.op, ChangeLog.entity_id).order_by(ChangeLog.seq)
        )
        return [(k, o, i) for k, o, i in rows]


# --- bootstrap and paging --------------------------------------------------------


async def test_bootstrap_from_zero(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    e1 = await record(client, "sleep-log", ANSWERS)
    e2 = await record(client, "sleep-log", {**ANSWERS, "wakeups": 2})

    page = await changes(client)
    versions = [i for i in page["items"] if i["kind"] == "version"]
    assert [(k, i) for k, i in kinds(page) if k != "version"] == [
        ("topic", t["id"]),
        ("entry", e1["id"]),
        ("entry", e2["id"]),
    ]
    assert [i["kind"] for i in page["items"]] == ["topic", "version", "entry", "entry"]
    assert versions[0]["topic_id"] == t["id"]
    assert versions[0]["version"]["version"] == 1
    assert page["items"][0]["topic"]["questions"][0]["key"] == "hours"
    assert page["items"][2]["entry"] == e1
    assert page["deleted"] == []
    assert page["next"] == page["head"] == 4
    assert page["has_more"] is False
    assert UUID(page["epoch"])
    assert UUID(page["server_id"])
    assert page["server_time"]

    again = await changes(client, after=page["next"])
    assert (again["items"], again["deleted"], again["next"], again["has_more"]) == ([], [], 4, False)
    assert (again["epoch"], again["server_id"]) == (page["epoch"], page["server_id"])


async def test_entry_mutations_do_not_log_the_topic(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    before = len(await log_rows())
    e = await record(client, "sleep-log", ANSWERS)
    await client.patch(f"/entries/{e['id']}", json={"notes": "x"})
    await client.delete(f"/entries/{e['id']}")
    assert [(k, o) for k, o, _ in (await log_rows())[before:]] == [
        (FeedKind.entry, FeedOp.upsert),
        (FeedKind.entry, FeedOp.upsert),
        (FeedKind.entry, FeedOp.delete),
    ]


async def test_every_topic_mutation_is_logged(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    await client.patch("/topics/sleep-log", json={"name": "Sleep"})
    await client.patch(
        "/topics/sleep-log", json={"schedule": {"kind": "interval", "every_minutes": 60, "timezone": "UTC"}}
    )
    qs = sleep_questions()
    qs[0]["label"] = "Hours"
    assert (
        await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    ).status_code == 201
    await client.post("/topics/sleep-log/archive")
    await client.post("/topics/sleep-log/unarchive")
    await client.post("/topics/sleep-log/archive")
    await client.delete("/topics/sleep-log")
    rows = [(k.value, o.value) for k, o, _ in await log_rows()]
    assert rows == [
        ("topic", "upsert"),  # create
        ("version", "upsert"),
        ("topic", "upsert"),  # rename
        ("topic", "upsert"),  # schedule
        ("topic", "upsert"),  # publish
        ("version", "upsert"),
        ("topic", "upsert"),  # archive
        ("topic", "upsert"),  # unarchive
        ("topic", "upsert"),  # archive
        ("topic", "delete"),
    ]
    assert {i for _, _, i in await log_rows() if i != UUID(t["id"])}  # the two versions


async def test_latest_state_wins_within_a_page(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    e = await record(client, "sleep-log", ANSWERS)
    await client.patch(f"/entries/{e['id']}", json={"notes": "one"})
    latest = (await client.patch(f"/entries/{e['id']}", json={"notes": "two"})).json()
    page = await changes(client)
    entries = [i for i in page["items"] if i["kind"] == "entry"]
    assert len(entries) == 1
    assert entries[0]["entry"] == latest
    assert entries[0]["entry"]["revision"] == 3
    assert entries[0]["seq"] == page["head"]


async def test_paging_returns_every_change_once(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    ids = [(await record(client, "sleep-log", ANSWERS))["id"] for _ in range(7)]
    # Identical timestamps must not matter: the cursor is the seq, not a time.
    async with get_sessionmaker()() as db:
        await db.execute(text("UPDATE change_log SET at = '2026-01-01T00:00:00Z'"))
        await db.execute(update(Entry).values(updated_at=text("'2026-01-01T00:00:00Z'")))
        await db.commit()

    pages = await drain(client, limit=2)
    assert len(pages) == 5  # 9 rows: topic, version, 7 entries
    assert [p["has_more"] for p in pages] == [True] * 4 + [False]
    seen = [i["entry"]["id"] for p in pages for i in p["items"] if i["kind"] == "entry"]
    assert seen == ids
    assert [p["next"] for p in pages] == [2, 4, 6, 8, 9]


async def test_limit_is_capped(client: httpx.AsyncClient) -> None:
    assert (await client.get("/changes", params={"limit": 501})).status_code == 422
    assert (await client.get("/changes", params={"after": -1})).status_code == 422


async def test_cursor_beyond_head_is_reported(client: httpx.AsyncClient) -> None:
    """A restored database has a lower head than the client's cursor: the client sees it."""
    await make_topic(client)
    page = await changes(client, after=1000)
    assert (page["items"], page["next"], page["has_more"], page["head"]) == ([], 1000, False, 2)


async def test_large_pages_are_gzipped(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    for _ in range(10):
        await record(client, "sleep-log", ANSWERS)
    r = await client.get("/changes", headers={"Accept-Encoding": "gzip"})
    assert r.headers["content-encoding"] == "gzip"
    assert len(r.json()["items"]) == 12


# --- deletions and tombstones ----------------------------------------------------


async def test_deletion_only_page(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    a = await record(client, "sleep-log", ANSWERS)
    b = await record(client, "sleep-log", ANSWERS)
    cursor = (await changes(client))["next"]
    for e in (a, b):
        assert (await client.delete(f"/entries/{e['id']}")).status_code == 204

    page = await changes(client, after=cursor)
    assert page["items"] == []
    assert [(d["kind"], d["id"], d["topic_id"]) for d in page["deleted"]] == [
        ("entry", a["id"], t["id"]),
        ("entry", b["id"], t["id"]),
    ]
    assert page["next"] == page["head"] == cursor + 2
    # From the start, the deleted entries' create rows resolve to deletions too.
    full = await changes(client)
    assert [k for k, _ in kinds(full)] == ["topic", "version"]
    assert {d["id"] for d in full["deleted"]} == {a["id"], b["id"]}


async def test_delete_unknown_id_reserves_it(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    entry_id = str(uuid4())
    head = (await changes(client))["head"]
    assert (await client.delete(f"/entries/{entry_id}")).status_code == 204
    assert (await client.delete(f"/entries/{entry_id}")).status_code == 204
    async with get_sessionmaker()() as db:
        tomb = (await db.execute(select(DeletedId).where(DeletedId.id == UUID(entry_id)))).scalar_one()
    assert (tomb.kind, tomb.topic_id) == (FeedKind.entry, None)
    assert (await changes(client))["head"] == head  # nothing anyone could have seen changed

    r = await client.post("/topics/sleep-log/entries", json={"id": entry_id, "answers": ANSWERS})
    assert r.status_code == 409
    assert r.json()["code"] == "entry_deleted"
    assert (await client.get(f"/entries/{entry_id}")).status_code == 404


async def test_delayed_create_after_delete(client: httpx.AsyncClient) -> None:
    """The undo flow: the entry was created, deleted, then the create is replayed (late retry)."""
    await make_topic(client)
    entry_id = str(uuid4())
    await record(client, "sleep-log", ANSWERS, id=entry_id)
    assert (await client.delete(f"/entries/{entry_id}")).status_code == 204
    r = await client.post("/topics/sleep-log/entries", json={"id": entry_id, "answers": ANSWERS})
    assert (r.status_code, r.json()["code"]) == (409, "entry_deleted")
    page = await changes(client)
    assert [d["id"] for d in page["deleted"]] == [entry_id]
    assert "entry" not in [k for k, _ in kinds(page)]


async def test_topic_delete_tombstones_children(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    qs = sleep_questions()
    qs[0]["label"] = "Hours"
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    entries = [(await record(client, "sleep-log", ANSWERS))["id"] for _ in range(3)]
    await client.post("/topics/sleep-log/archive")
    cursor = (await changes(client))["next"]
    assert (await client.delete("/topics/sleep-log")).status_code == 204

    async with get_sessionmaker()() as db:
        tombs = (await db.execute(select(DeletedId.kind, DeletedId.topic_id))).all()
    assert sorted(k.value for k, _ in tombs) == ["entry"] * 3 + ["topic"] + ["version"] * 2
    assert {str(topic_id) for _, topic_id in tombs} == {t["id"]}

    page = await changes(client, after=cursor)
    assert page["items"] == []
    assert [(d["kind"], d["id"]) for d in page["deleted"]] == [("topic", t["id"])]

    # A fresh client sees only deletions, children first.
    full = await changes(client)
    assert full["items"] == []
    order = [d["kind"] for d in full["deleted"]]
    assert order == ["entry"] * 3 + ["version"] * 2 + ["topic"]
    assert {d["id"] for d in full["deleted"] if d["kind"] == "entry"} == set(entries)

    # Replaying a create for a child of the deleted topic retires it (not a 404).
    r = await client.post(f"/topics/{t['id']}/entries", json={"id": entries[0], "answers": ANSWERS})
    assert (r.status_code, r.json()["code"]) == (409, "entry_deleted")
    async with Client(mcp) as mcp_client:
        replay = await mcp_client.call_tool(
            "record_entry", {"ref": t["id"], "answers": ANSWERS, "id": entries[1]}, raise_on_error=False
        )
    assert replay.is_error
    assert "was deleted and can't be recreated" in str(replay.content[0])
    # Without a client id there is nothing to retire: the topic is simply gone.
    r = await client.post(f"/topics/{t['id']}/entries", json={"answers": ANSWERS})
    assert r.status_code == 404


async def test_ids_are_unique_per_kind_only(client: httpx.AsyncClient) -> None:
    """An entry may reuse its topic's UUID (client-chosen ids): neither hides the other."""
    t = await make_topic(client)
    e = await record(client, "sleep-log", ANSWERS, id=t["id"])
    assert e["id"] == t["id"]
    page = await changes(client)
    assert [k for k, _ in kinds(page)] == ["topic", "version", "entry"]
    assert {i for k, i in kinds(page) if k != "version"} == {t["id"]}

    cursor = page["next"]
    assert (await client.delete(f"/entries/{t['id']}")).status_code == 204
    page = await changes(client, after=cursor)
    assert (page["items"], [(d["kind"], d["id"]) for d in page["deleted"]]) == ([], [("entry", t["id"])])
    full = await changes(client)
    assert [k for k, _ in kinds(full)] == ["topic", "version"]  # the topic is untouched
    assert (await client.get(f"/topics/{t['id']}")).status_code == 200

    # Both tombstones coexist once the topic goes too.
    await client.post(f"/topics/{t['id']}/archive")
    assert (await client.delete(f"/topics/{t['id']}")).status_code == 204
    async with get_sessionmaker()() as db:
        tombs = (await db.execute(select(DeletedId.kind).where(DeletedId.id == UUID(t["id"])))).scalars()
        assert sorted(k.value for k in tombs) == ["entry", "topic"]
    full = await changes(client)
    assert {(d["kind"], d["id"]) for d in full["deleted"] if d["id"] == t["id"]} == {
        ("entry", t["id"]),
        ("topic", t["id"]),
    }


async def test_mcp_delete_shows_in_feed(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    e = await record(client, "sleep-log", ANSWERS)
    cursor = (await changes(client))["next"]
    async with Client(mcp) as mcp_client:
        result = await mcp_client.call_tool("delete_entry", {"entry_id": e["id"]})
        assert not result.is_error
        created = await mcp_client.call_tool(
            "record_entry", {"ref": "sleep-log", "answers": ANSWERS, "id": e["id"]}, raise_on_error=False
        )
        assert created.is_error
        assert "deleted" in str(created.content[0])
    page = await changes(client, after=cursor)
    assert [(d["kind"], d["id"]) for d in page["deleted"]] == [("entry", e["id"])]


# --- revisions -------------------------------------------------------------------


async def test_entry_stale_revision(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    e = await record(client, "sleep-log", ANSWERS)
    assert e["revision"] == 1
    r = await client.patch(f"/entries/{e['id']}", json={"notes": "a", "expected_revision": 1})
    assert (r.status_code, r.json()["revision"]) == (200, 2)
    assert r.json()["updated_at"] > e["updated_at"]
    r = await client.patch(f"/entries/{e['id']}", json={"notes": "b", "expected_revision": 1})
    assert r.status_code == 409
    assert r.json()["code"] == "stale_revision"
    assert r.json()["errors"] == [{"loc": ["expected_revision"], "message": "current revision is 2"}]
    assert (await client.get(f"/entries/{e['id']}")).json()["notes"] == "a"
    # Without a guard, last write wins (the PWA's behaviour).
    r = await client.patch(f"/entries/{e['id']}", json={"notes": "c"})
    assert (r.status_code, r.json()["revision"]) == (200, 3)


async def test_topic_stale_revision(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    assert t["revision"] == 1
    r = await client.post("/topics/sleep-log/archive", params={"expected_revision": 1})
    assert (r.status_code, r.json()["revision"], r.json()["status"]) == (200, 2, "archived")
    r = await client.post("/topics/sleep-log/unarchive", params={"expected_revision": 1})
    assert (r.status_code, r.json()["code"]) == (409, "stale_revision")
    r = await client.post("/topics/sleep-log/unarchive", params={"expected_revision": 2})
    assert (r.status_code, r.json()["revision"]) == (200, 3)
    r = await client.patch("/topics/sleep-log", json={"name": "x", "expected_revision": 2})
    assert (r.status_code, r.json()["code"]) == (409, "stale_revision")
    r = await client.patch("/topics/sleep-log", json={"name": "x", "expected_revision": 3})
    assert (r.status_code, r.json()["revision"]) == (200, 4)
    # Recording entries doesn't touch the topic's revision.
    await record(client, "sleep-log", ANSWERS)
    assert (await client.get("/topics/sleep-log")).json()["revision"] == 4


# --- write order -----------------------------------------------------------------


async def test_seq_follows_commit_order() -> None:
    """Two sessions: the one that commits later always gets the higher seq.

    A holds the feed lock with a seq allocated but uncommitted; B (a real service call)
    starts meanwhile and must wait for A's commit, so it can't take a lower seq and a
    reader can never see B's row while A's is still invisible.
    """
    started, release = asyncio.Event(), asyncio.Event()
    a_id = uuid4()

    @feed.writer
    async def slow_write(db: AsyncSession) -> None:
        await feed.log_change(db, FeedKind.topic, FeedOp.upsert, a_id, a_id)
        started.set()
        await release.wait()

    maker = get_sessionmaker()
    async with maker() as a, maker() as b, maker() as reader:
        task_a = asyncio.create_task(slow_write(a))
        await asyncio.wait_for(started.wait(), 5)
        body = TopicCreate.model_validate({"name": "Later", "questions": sleep_questions()})
        task_b = asyncio.create_task(topic_svc.create_topic(b, body))
        try:
            b_waited = await wait_for_lock_waiter(reader)
            visible = await reader.scalar(select(func.count()).select_from(ChangeLog))
            await reader.rollback()
        finally:
            release.set()  # never leave A hanging, even when an assertion fails
            await task_a
            b_topic = await task_b
    assert b_waited, "B must wait for the feed lock"
    assert visible == 0

    rows = await log_rows()
    assert [i for _, _, i in rows][:2] == [a_id, b_topic.id]


@pytest.fixture(autouse=True)
async def _isolated(clean_db: None) -> None:
    """Every test here starts from an empty database (and an empty change log)."""


class _FakeOrig(Exception):
    def __init__(self, sqlstate: str) -> None:
        super().__init__(sqlstate)
        self.sqlstate = sqlstate


async def test_writer_retries_deadlocks(db: AsyncSession) -> None:
    calls: list[int] = []

    @feed.writer
    async def flaky(session: AsyncSession, fail: int, sqlstate: str) -> int:
        held = await session.scalar(
            text("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = :id"),
            {"id": feed.FEED_LOCK_ID},
        )
        assert held == 1  # the lock is taken before the function body runs
        calls.append(1)
        if len(calls) <= fail:
            raise DBAPIError("stmt", {}, _FakeOrig(sqlstate))
        return len(calls)

    assert await flaky(db, 2, "40P01") == 3
    calls.clear()
    with pytest.raises(DBAPIError):
        await flaky(db, 3, "40001")  # gives up after MAX_ATTEMPTS
    assert len(calls) == feed.MAX_ATTEMPTS
    calls.clear()
    with pytest.raises(DBAPIError):
        await flaky(db, 1, "23505")  # unique violation: not retried
    assert len(calls) == 1
    # The lock is released after a failure.
    assert not await db.scalar(text("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'"))


# --- epoch and identity ----------------------------------------------------------


async def test_rotate_epoch_keeps_server_id(client: httpx.AsyncClient, db: AsyncSession) -> None:
    before = await changes(client)
    new = await feed.rotate_epoch(db)
    after = await changes(client)
    assert after["epoch"] == new != before["epoch"]
    assert after["server_id"] == before["server_id"]


async def _rotate() -> str:
    async with get_sessionmaker()() as other:
        return await feed.rotate_epoch(other)


async def test_page_identity_comes_from_the_page_snapshot(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    await make_topic(client)
    old = (await changes(client))["epoch"]
    real_ensure, real_details = feed.ensure_identity, topic_svc.topic_details
    rotated: list[str] = []

    async def ensure_then_rotate(db: AsyncSession) -> None:
        await real_ensure(db)
        rotated.append(await _rotate())  # after the identity exists, before the snapshot

    monkeypatch.setattr("app.services.changes.ensure_identity", ensure_then_rotate)
    page = await changes(client)
    assert page["epoch"] == rotated[0] != old
    monkeypatch.setattr("app.services.changes.ensure_identity", real_ensure)

    async def rotate_mid_page(db: AsyncSession, ids: list[UUID]) -> Any:
        rotated.append(await _rotate())  # commits while the page's snapshot is open
        return await real_details(db, ids)

    monkeypatch.setattr(topic_svc, "topic_details", rotate_mid_page)
    page = await changes(client)
    assert page["epoch"] == rotated[0]  # consistent with the snapshot it was read in
    monkeypatch.setattr(topic_svc, "topic_details", real_details)
    assert (await changes(client))["epoch"] == rotated[1]


# --- writer contract ---------------------------------------------------------------


async def _count(sql: str) -> int:
    async with get_sessionmaker()() as db:
        return int(await db.scalar(text(sql)) or 0)


async def test_writer_rejects_pending_orm_writes(db: AsyncSession) -> None:
    from app.models import AppSetting
    from app.services import entries as entry_svc

    db.add(AppSetting(key="stray", value="x"))
    with pytest.raises(feed.WriterMisuse):
        await entry_svc.delete_entry(db, uuid4())
    await db.rollback()
    assert await _count("SELECT count(*) FROM app_settings WHERE key = 'stray'") == 0
    assert await _count("SELECT count(*) FROM deleted_ids") == 0


async def test_writer_rejects_an_open_transaction(db: AsyncSession) -> None:
    from app.services import entries as entry_svc

    await db.execute(text("SELECT 1"))  # could as well have been a write
    with pytest.raises(feed.WriterMisuse):
        await entry_svc.delete_entry(db, uuid4())
    await db.rollback()
    await entry_svc.delete_entry(db, uuid4())  # an idle session is fine
    assert await _count("SELECT count(*) FROM deleted_ids") == 1


async def test_nested_writers_share_the_outer_transaction(db: AsyncSession) -> None:
    from app.services import entries as entry_svc

    @feed.writer
    async def outer(session: AsyncSession, fail: bool) -> None:
        await feed.log_change(session, FeedKind.topic, FeedOp.upsert, uuid4(), uuid4())
        await entry_svc.delete_entry(session, uuid4())  # nested: no lock re-take, no commit
        locks = await session.scalar(
            text("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = :id AND granted"),
            {"id": feed.FEED_LOCK_ID},
        )
        assert locks == 1
        if fail:
            raise RuntimeError("after the inner writer")

    with pytest.raises(RuntimeError):
        await outer(db, True)
    assert await _count("SELECT count(*) FROM change_log") == 0
    assert await _count("SELECT count(*) FROM deleted_ids") == 0  # the inner write rolled back too

    await outer(db, False)
    assert await _count("SELECT count(*) FROM change_log") == 1
    assert await _count("SELECT count(*) FROM deleted_ids") == 1


async def test_retry_rolls_back_and_replays_real_writes(db: AsyncSession) -> None:
    attempts: list[int] = []
    entity = uuid4()

    @feed.writer
    async def write_then_deadlock(session: AsyncSession) -> None:
        attempts.append(1)
        await feed.log_change(session, FeedKind.entry, FeedOp.delete, entity, entity)
        await feed.tombstone(session, FeedKind.entry, entity, entity)
        if len(attempts) == 1:
            raise DBAPIError("stmt", {}, _FakeOrig("40P01"))

    await write_then_deadlock(db)
    assert len(attempts) == 2
    assert await _count("SELECT count(*) FROM change_log") == 1
    assert await _count("SELECT count(*) FROM deleted_ids") == 1


async def test_writer_once_never_retries(db: AsyncSession) -> None:
    calls: list[int] = []

    @feed.writer_once
    async def deliver_then_deadlock(session: AsyncSession) -> None:
        calls.append(1)
        await feed.log_change(session, FeedKind.entry, FeedOp.delete, uuid4(), uuid4())
        raise DBAPIError("stmt", {}, _FakeOrig("40P01"))

    with pytest.raises(DBAPIError):
        await deliver_then_deadlock(db)
    assert len(calls) == 1
    assert await _count("SELECT count(*) FROM change_log") == 0  # rolled back
    assert not db.in_transaction()


async def test_writer_once_refuses_to_join_a_retried_writer(db: AsyncSession) -> None:
    @feed.writer_once
    async def once(session: AsyncSession) -> None:
        pass

    @feed.writer
    async def outer(session: AsyncSession) -> None:
        await once(session)

    with pytest.raises(feed.WriterMisuse):
        await outer(db)
