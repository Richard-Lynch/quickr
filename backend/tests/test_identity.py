"""Server identity headers on every /api/v1 response, and the mutation preconditions."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from sqlalchemy import text

from app.db import get_sessionmaker
from tests.helpers import make_topic, record, sleep_questions

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}
PUSH_SUB = {
    "endpoint": "https://fcm.googleapis.com/fcm/send/1",
    "keys": {"p256dh": "p256dh-1", "auth": "auth-1"},
}


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
        "push": "SELECT endpoint FROM push_subscriptions",
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
    ]


MUTATIONS = range(11)


@pytest.mark.parametrize("which", MUTATIONS)
@pytest.mark.parametrize(
    ("header", "code"),
    [("X-QuickR-Expect-Server-Id", "server_mismatch"), ("X-QuickR-Expect-Epoch", "epoch_mismatch")],
)
async def test_precondition_rejects_before_any_write(
    client: httpx.AsyncClient, which: int, header: str, code: str
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
            if method not in {"post", "patch", "delete", "put"} or op["operationId"] in {
                "checkTopicVersion",  # dry run
                "sendTestPush",  # writes nothing the client keeps
            }:
                continue
            names = {p["name"] for p in op.get("parameters", []) if p["in"] == "header"}
            assert {"X-QuickR-Expect-Server-Id", "X-QuickR-Expect-Epoch"} <= names, (path, method)
