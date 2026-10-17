"""Server identity headers on every /api/v1 response, and the mutation preconditions."""

from __future__ import annotations

import asyncio
import threading
from typing import Any
from uuid import uuid4

import httpx
import pytest
from sqlalchemy import text

from app.db import get_sessionmaker
from app.services import feed
from app.services import push as push_svc
from tests.helpers import make_topic, record, sleep_questions, wait_for_lock_waiter

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}
PUSH_SUB = {
    "endpoint": "https://fcm.googleapis.com/fcm/send/1",
    "keys": {"p256dh": "p256dh-1", "auth": "auth-1"},
}


@pytest.fixture(autouse=True)
def deliveries(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Push delivery is mocked: the endpoints that would have been sent to."""
    sent: list[str] = []
    monkeypatch.setattr(push_svc, "deliver", lambda subscription, *_: sent.append(subscription["endpoint"]))
    return sent


async def identity(client: httpx.AsyncClient) -> tuple[str, str]:
    body = (await client.get("/changes", params={"limit": 1})).json()
    return body["server_id"], body["epoch"]


async def test_headers_on_every_response(client: httpx.AsyncClient) -> None:
    server_id, epoch = await identity(client)
    await make_topic(client)
    responses = [
        await client.get("/health"),
        await client.get("/topics"),
        await client.post("/topics", json={"name": "x", "questions": sleep_questions()}),
        await client.get("/topics/nope"),  # 404
        await client.post("/topics", json={}),  # 422
        await client.post("/topics/sleep-log/entries", json={"answers": {"hours": "x"}}),  # domain 422
        await client.delete("/topics/sleep-log"),  # 409
        await client.get("/topics/sleep-log/entries.csv"),  # streamed
    ]
    assert [r.status_code for r in responses] == [200, 200, 201, 404, 422, 422, 409, 200]
    for r in responses:
        assert (r.headers["x-quickr-server-id"], r.headers["x-quickr-epoch"]) == (server_id, epoch)


async def test_headers_on_unhandled_errors(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.services import topics as topic_svc

    server_id, _ = await identity(client)

    async def boom(*_: Any, **__: Any) -> None:
        raise RuntimeError("boom")

    monkeypatch.setattr(topic_svc, "list_topics", boom)
    r = await client.get("/topics")
    assert r.status_code == 500
    assert r.json() == {"code": "internal_error", "detail": "internal server error", "errors": []}
    assert r.headers["x-quickr-server-id"] == server_id


async def test_headers_follow_an_epoch_rotation(client: httpx.AsyncClient) -> None:
    from app.services.feed import rotate_epoch

    server_id, epoch = await identity(client)
    async with get_sessionmaker()() as db:
        new = await rotate_epoch(db)
    r = await client.get("/health")
    assert (r.headers["x-quickr-server-id"], r.headers["x-quickr-epoch"]) == (server_id, new)
    assert new != epoch


async def _state() -> dict[str, Any]:
    """Everything a mutation could touch."""
    queries = {
        "topics": "SELECT id, slug, name, status, revision, current_version, schedule FROM topics",
        "versions": "SELECT id FROM topic_versions",
        "entries": "SELECT id, notes, revision FROM entries",
        "log": "SELECT seq FROM change_log",
        "tombstones": "SELECT id FROM deleted_ids",
        "push": "SELECT endpoint, failure_count, last_success_at FROM push_subscriptions",
        # VAPID keys, server id (the epoch is left out: the lock test rotates it on purpose)
        "settings": f"SELECT key, value FROM app_settings WHERE key <> '{feed.EPOCH_SETTING}'",
    }
    async with get_sessionmaker()() as db:
        return {k: sorted(map(tuple, (await db.execute(text(q))).all()), key=str) for k, q in queries.items()}


async def _fixture(client: httpx.AsyncClient) -> dict[str, str]:
    await make_topic(client)
    entry = await record(client, "sleep-log", ANSWERS)
    await make_topic(client, "Old")
    await client.post("/topics/old/archive")
    await client.post("/push/subscriptions", json=PUSH_SUB)
    return {"entry": entry["id"]}


def _mutations(ids: dict[str, str]) -> list[tuple[str, str, dict[str, Any] | None]]:
    qs = sleep_questions()
    qs[0]["label"] = "Hours"
    return [
        ("POST", "/topics", {"name": "New", "questions": sleep_questions()}),
        ("PATCH", "/topics/sleep-log", {"name": "Renamed"}),
        ("POST", "/topics/sleep-log/archive", None),
        ("POST", "/topics/old/unarchive", None),
        ("DELETE", "/topics/old", None),
        ("POST", "/topics/sleep-log/versions", {"questions": qs, "base_version": 1}),
        ("POST", "/topics/sleep-log/entries", {"answers": ANSWERS}),
        ("PATCH", f"/entries/{ids['entry']}", {"notes": "changed"}),
        ("DELETE", f"/entries/{ids['entry']}", None),
        ("POST", "/push/subscriptions", {**PUSH_SUB, "endpoint": "https://fcm.googleapis.com/fcm/send/2"}),
        ("POST", "/push/subscriptions/delete", {"endpoint": PUSH_SUB["endpoint"]}),
        ("POST", "/push/test", None),
    ]


MUTATIONS = range(12)


@pytest.mark.parametrize("which", MUTATIONS)
@pytest.mark.parametrize(
    ("header", "code"),
    [("X-QuickR-Expect-Server-Id", "server_mismatch"), ("X-QuickR-Expect-Epoch", "epoch_mismatch")],
)
async def test_precondition_rejects_before_any_write(
    client: httpx.AsyncClient, deliveries: list[str], which: int, header: str, code: str
) -> None:
    ids = await _fixture(client)
    server_id, epoch = await identity(client)
    method, url, body = _mutations(ids)[which]
    good = {"X-QuickR-Expect-Server-Id": server_id, "X-QuickR-Expect-Epoch": epoch}
    before = await _state()
    r = await client.request(method, url, json=body, headers={**good, header: "someone-else"})
    assert r.status_code == 409, r.text
    assert r.json()["code"] == code
    assert r.headers["x-quickr-server-id"] == server_id
    assert await _state() == before
    assert deliveries == []

    # Matching headers: the mutation goes through.
    r = await client.request(method, url, json=body, headers=good)
    assert r.status_code < 300, r.text
    assert await _state() != before


@pytest.mark.parametrize("which", MUTATIONS)
async def test_no_headers_no_check(client: httpx.AsyncClient, which: int) -> None:
    method, url, body = _mutations(await _fixture(client))[which]
    r = await client.request(method, url, json=body)
    assert r.status_code < 300, r.text


async def test_every_mutating_operation_declares_the_preconditions() -> None:
    from app.main import app

    spec = app.openapi()
    for path, item in spec["paths"].items():
        for method, op in item.items():
            if (
                method not in {"post", "patch", "delete", "put"} or op["operationId"] == "checkTopicVersion"
            ):  # dry run
                continue
            names = {p["name"] for p in op.get("parameters", []) if p["in"] == "header"}
            assert {"X-QuickR-Expect-Server-Id", "X-QuickR-Expect-Epoch"} <= names, (path, method)


@pytest.mark.parametrize(
    ("method", "url", "body"),
    [
        ("POST", "/topics/sleep-log/entries", {"answers": ANSWERS}),
        ("POST", "/push/subscriptions", PUSH_SUB),
        ("POST", "/push/test", None),
    ],
)
async def test_precondition_is_checked_under_the_lock(
    client: httpx.AsyncClient, deliveries: list[str], method: str, url: str, body: dict[str, Any] | None
) -> None:
    """A request that read epoch A, then waited on the feed lock while a rotation to B
    committed, must fail with epoch_mismatch: the check runs under the lock, not before."""
    await make_topic(client)
    await client.post("/push/subscriptions", json={**PUSH_SUB, "endpoint": f"{PUSH_SUB['endpoint']}0"})
    server_id, epoch_a = await identity(client)
    started, release = asyncio.Event(), asyncio.Event()

    @feed.writer
    async def slow_rotation(db: Any) -> str:
        started.set()
        await release.wait()
        return await feed.rotate_epoch(db)  # nested: joins this locked transaction

    headers = {"X-QuickR-Expect-Server-Id": server_id, "X-QuickR-Expect-Epoch": epoch_a}
    maker = get_sessionmaker()
    async with maker() as holder, maker() as watcher:
        rotation = asyncio.create_task(slow_rotation(holder))
        await asyncio.wait_for(started.wait(), 5)
        before = await _state()
        request = asyncio.create_task(client.request(method, url, json=body, headers=headers))
        try:
            waited = await wait_for_lock_waiter(watcher)
        finally:
            release.set()
            epoch_b = await rotation
            r = await request
    assert waited, "the request must have been waiting for the feed lock"
    assert epoch_b != epoch_a
    assert (r.status_code, r.json()["code"]) == (409, "epoch_mismatch"), r.text
    assert r.headers["x-quickr-epoch"] == epoch_b  # labelled after the handler ran
    assert await _state() == before
    assert deliveries == []


async def test_changes_headers_match_the_page(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A rotation after the middleware read its identity: /changes still answers with the
    page's own (snapshot) identity in both body and headers."""
    await make_topic(client)
    real_ensure = feed.ensure_identity

    async def ensure_then_rotate(db: Any) -> None:
        await real_ensure(db)
        async with get_sessionmaker()() as other:
            await feed.rotate_epoch(other)

    monkeypatch.setattr("app.services.changes.ensure_identity", ensure_then_rotate)
    r = await client.get("/changes")
    assert r.headers["x-quickr-epoch"] == r.json()["epoch"]
    assert r.headers["x-quickr-server-id"] == r.json()["server_id"]
    assert r.headers.get_list("x-quickr-epoch") == [r.json()["epoch"]]  # not duplicated


async def test_unhandled_errors_get_cors_headers(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.services import topics as topic_svc

    async def boom(*_: Any, **__: Any) -> None:
        raise RuntimeError("boom")

    monkeypatch.setattr(topic_svc, "list_topics", boom)
    r = await client.get("/topics", headers={"Origin": "http://localhost:5180"})
    assert r.status_code == 500
    assert r.headers["access-control-allow-origin"] == "http://localhost:5180"
    assert "x-quickr-epoch" in r.headers["access-control-expose-headers"].lower()
    assert r.headers["x-quickr-epoch"]


async def test_one_identity_query_per_request(client: httpx.AsyncClient) -> None:
    from sqlalchemy import event

    from app.db import get_engine

    await client.get("/health")  # identity exists from here on
    statements: list[str] = []

    def record_sql(*args: Any) -> None:
        statements.append(str(args[2]))

    engine = get_engine().sync_engine
    event.listen(engine, "before_cursor_execute", record_sql)
    try:
        await client.get("/health")
    finally:
        event.remove(engine, "before_cursor_execute", record_sql)
    assert sum("app_settings" in sql for sql in statements) == 1


@pytest.mark.parametrize("found", [True, False])
async def test_headers_are_read_after_the_handler(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, found: bool
) -> None:
    """A rotation between the request's start and the lookup: the response (found or
    404) carries the new epoch, never the one current when the request arrived."""
    from app.services import entries as entry_svc

    await make_topic(client)
    entry_id = (await record(client, "sleep-log", ANSWERS))["id"] if found else str(uuid4())
    _, old = await identity(client)
    real_get = entry_svc.get_entry
    rotated: list[str] = []

    async def rotate_then_get(db: Any, eid: Any) -> Any:
        async with get_sessionmaker()() as other:
            rotated.append(await feed.rotate_epoch(other))
        return await real_get(db, eid)

    monkeypatch.setattr(entry_svc, "get_entry", rotate_then_get)
    r = await client.get(f"/entries/{entry_id}")
    assert r.status_code == (200 if found else 404)
    assert r.headers["x-quickr-epoch"] == rotated[0] != old


async def test_csv_export_streams_one_snapshot(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Headers go out, then the epoch rotates and an entry is added, then the body streams:
    the body is the snapshot's (no new entry) and so is the header."""
    from app.models import Channel
    from app.schemas.api import EntryCreate
    from app.services import entries as entry_svc

    await make_topic(client)
    old_entry = await record(client, "sleep-log", ANSWERS)
    _, old_epoch = await identity(client)
    real_export = entry_svc.export_csv
    late: list[str] = []

    async def export_then_change(*args: Any) -> Any:
        result = await real_export(*args)  # the snapshot is open from here
        async with get_sessionmaker()() as other:
            await feed.rotate_epoch(other)
        async with get_sessionmaker()() as other:
            body = EntryCreate.model_validate({"answers": ANSWERS})
            late.append(str((await entry_svc.create_entry(other, "sleep-log", body, Channel.api)).id))
        return result

    monkeypatch.setattr(entry_svc, "export_csv", export_then_change)
    r = await client.get("/topics/sleep-log/entries.csv")
    assert r.status_code == 200
    assert r.headers["x-quickr-epoch"] == old_epoch
    assert r.headers.get_list("x-quickr-epoch") == [old_epoch]
    assert old_entry["id"] in r.text
    assert late[0] not in r.text
    assert (await identity(client))[1] != old_epoch  # the rotation did happen


async def test_csv_export_closes_its_snapshot(db: Any, client: httpx.AsyncClient) -> None:
    """An export abandoned mid-stream (client gone) ends its transaction."""
    from app.errors import NotFound
    from app.schemas.api import EntryFilters
    from app.services import entries as entry_svc

    await make_topic(client)
    await record(client, "sleep-log", ANSWERS)
    _, gen = await entry_svc.export_csv(db, "sleep-log", EntryFilters())
    assert db.in_transaction()
    assert (await anext(gen)).startswith("entry_id,")
    await gen.aclose()  # what Starlette does when the client disconnects
    assert not db.in_transaction()

    with pytest.raises(NotFound):
        await entry_svc.export_csv(db, "nope", EntryFilters())
    assert not db.in_transaction()


async def test_headers_under_a_saturated_pool(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One pooled connection, many concurrent requests: each request reads its identity on
    its own session, so none waits for a second connection while holding the first."""
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from tests.conftest import TEST_DATABASE_URL

    await make_topic(client)
    server_id, epoch = await identity(client)
    engine = create_async_engine(TEST_DATABASE_URL, pool_size=1, max_overflow=0, pool_timeout=2)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    for where in ("app.db", "app.api.identity"):
        monkeypatch.setattr(f"{where}.get_sessionmaker", lambda: maker)
    requests = [
        *(client.get("/topics") for _ in range(4)),
        *(client.get("/topics/sleep-log") for _ in range(4)),
        client.get("/topics/nope"),  # 404
        client.get("/limits"),  # no database work in the handler
        client.post("/topics/sleep-log/entries", json={"answers": ANSWERS}),
        client.get("/changes"),
    ]
    try:
        responses = await asyncio.wait_for(asyncio.gather(*requests), 10)
    finally:
        await engine.dispose()
    assert [r.status_code for r in responses] == [200] * 8 + [404, 200, 201, 200]
    for r in responses:
        assert (r.headers.get("x-quickr-server-id"), r.headers.get("x-quickr-epoch")) == (server_id, epoch)


async def test_unreadable_identity_logs_one_line(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    """Database down: the response goes out without the headers, with a warning and no
    traceback per request."""

    async def down(_: Any) -> None:
        raise ConnectionRefusedError("connection refused")

    monkeypatch.setattr("app.api.identity.feed_identity", down)
    r = await client.get("/limits")
    assert r.status_code == 200
    assert "x-quickr-epoch" not in r.headers
    [warning] = [rec for rec in caplog.records if rec.name == "app.api.identity"]
    assert warning.levelname == "WARNING"
    assert warning.exc_info is None
    assert "ConnectionRefusedError: connection refused" in warning.getMessage()


async def test_prefix_is_a_path_segment(client: httpx.AsyncClient) -> None:
    assert "x-quickr-epoch" in (await client.get("http://test/api/v1")).headers  # 404, but ours
    assert "x-quickr-epoch" not in (await client.get("http://test/api/v10/health")).headers


async def test_test_push_holds_the_lock_through_delivery(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A rotation attempted after /push/test checked its expected epoch waits for the lock
    until the push has delivered and committed: it can't land between check and send."""
    await client.post("/push/subscriptions", json=PUSH_SUB)
    server_id, epoch_a = await identity(client)
    in_delivery, finish = threading.Event(), threading.Event()
    events: list[str] = []

    def slow_deliver(subscription: dict[str, Any], *_: Any) -> None:
        in_delivery.set()
        assert finish.wait(5)
        events.append("delivered")

    monkeypatch.setattr(push_svc, "deliver", slow_deliver)

    async def rotate() -> str:
        async with get_sessionmaker()() as other:
            epoch = await feed.rotate_epoch(other)
        events.append("rotated")
        return epoch

    headers = {"X-QuickR-Expect-Server-Id": server_id, "X-QuickR-Expect-Epoch": epoch_a}
    request = asyncio.create_task(client.post("/push/test", headers=headers))
    async with get_sessionmaker()() as watcher:
        try:
            assert await asyncio.to_thread(in_delivery.wait, 5), "the push never reached delivery"
            rotation = asyncio.create_task(rotate())
            waited = await wait_for_lock_waiter(watcher)
            assert not rotation.done()
        finally:
            finish.set()
        r = await request
        epoch_b = await rotation
    assert waited, "the rotation must have been waiting for the feed lock"
    assert (r.status_code, r.json()) == (200, {"sent": 1, "failed": 0}), r.text
    assert events == ["delivered", "rotated"]
    assert epoch_b != epoch_a
    async with get_sessionmaker()() as db:
        assert await db.scalar(text("SELECT last_success_at IS NOT NULL FROM push_subscriptions"))
