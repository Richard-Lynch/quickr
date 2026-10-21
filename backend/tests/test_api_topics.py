"""Topic CRUD, search, listing and archive lifecycle over HTTP."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest

from tests.helpers import make_topic, record, sleep_questions


async def test_health(client: httpx.AsyncClient) -> None:
    r = await client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


async def test_create_and_get_topic(client: httpx.AsyncClient) -> None:
    t = await make_topic(client, "Sleep log", description="Nightly sleep")
    assert t["slug"] == "sleep-log"
    assert t["status"] == "active"
    assert t["current_version"] == 1
    assert t["question_count"] == 4
    assert t["entry_count"] == 0
    assert t["last_captured_at"] is None
    assert t["archived_at"] is None
    assert [q["key"] for q in t["questions"]] == ["hours", "wakeups", "quality", "dream"]
    # Defaults are materialised in the output.
    assert t["questions"][3] == {
        "key": "dream",
        "label": "Dream journal",
        "help_text": None,
        "required": False,
        "type": "str",
        "min_length": 0,
        "max_length": 500,
        "multiline": True,
    }

    by_slug = (await client.get("/topics/sleep-log")).json()
    by_id = (await client.get(f"/topics/{t['id']}")).json()
    assert by_slug == by_id == t


async def test_get_missing_topic_is_problem(client: httpx.AsyncClient) -> None:
    r = await client.get("/topics/nope")
    assert r.status_code == 404
    assert r.json() == {"code": "not_found", "detail": "topic 'nope' not found", "errors": []}
    r = await client.get("/topics/00000000-0000-0000-0000-000000000000")
    assert r.status_code == 404


@pytest.mark.parametrize(
    ("name", "slug"),
    [
        ("Sleep Log", "sleep-log"),
        ("  Café — crème brûlée!  ", "cafe-creme-brulee"),
        ("A/B   test__2", "a-b-test-2"),
        ("!!!", "topic"),
        ("x" * 100, "x" * 64),
    ],
)
async def test_slug_derivation(client: httpx.AsyncClient, name: str, slug: str) -> None:
    t = await make_topic(client, name[:200])
    assert t["slug"] == slug


async def test_explicit_slug_and_conflicts(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Sleep log")
    r = await client.post("/topics", json={"name": "Sleep log", "questions": sleep_questions()})
    assert r.status_code == 409
    assert r.json()["code"] == "conflict"
    assert "sleep-log" in r.json()["detail"]

    other = await make_topic(client, "Sleep log", slug="sleep-2")
    assert other["slug"] == "sleep-2"

    r = await client.patch(f"/topics/{other['id']}", json={"slug": "sleep-log"})
    assert r.status_code == 409
    # The failed update did not leak into the stored topic.
    assert (await client.get(f"/topics/{other['id']}")).json()["slug"] == "sleep-2"


async def test_invalid_slug_rejected(client: httpx.AsyncClient) -> None:
    r = await client.post("/topics", json={"name": "x", "slug": "Bad Slug", "questions": sleep_questions()})
    assert r.status_code == 422


async def test_create_rejects_bad_question_config(client: httpx.AsyncClient) -> None:
    dup = [*sleep_questions(), {"key": "hours", "label": "Again", "type": "int"}]
    r = await client.post("/topics", json={"name": "x", "questions": dup})
    assert r.status_code == 422
    assert r.json() == {
        "code": "invalid_request",
        "detail": "request validation failed",
        "errors": [{"loc": ["body", "questions", 4, "key"], "message": "duplicate question key 'hours'"}],
    }
    assert (await client.get("/topics", params={"status": "all"})).json()["total"] == 0

    bad = [{"key": "a", "label": "A", "type": "int", "min": 3, "max": 1}]
    r = await client.post("/topics", json={"name": "x", "questions": bad})
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {"loc": ["body", "questions", 0, "max"], "message": "max must be greater than or equal to min"}
    ]

    # No questions is a valid (single) topic: tests/test_single_topics.py.


async def test_update_topic_metadata(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    r = await client.patch("/topics/sleep-log", json={"name": "Sleep", "description": "zzz"})
    assert r.status_code == 200
    u = r.json()
    assert (u["name"], u["description"], u["slug"]) == ("Sleep", "zzz", "sleep-log")
    assert u["updated_at"] >= t["updated_at"]
    # Questions cannot be changed via PATCH.
    r = await client.patch("/topics/sleep-log", json={"questions": []})
    assert r.status_code == 422
    r = await client.patch("/topics/sleep-log", json={"slug": "renamed"})
    assert r.json()["slug"] == "renamed"
    assert (await client.get("/topics/sleep-log")).status_code == 404


async def test_archive_lifecycle(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    await record(client, "sleep-log", {"hours": 7, "wakeups": 1, "quality": "ok"})

    # Delete requires archived.
    r = await client.delete("/topics/sleep-log")
    assert r.status_code == 409
    assert r.json()["code"] == "conflict"

    r = await client.post("/topics/sleep-log/archive")
    assert r.status_code == 200
    assert r.json()["status"] == "archived"
    assert r.json()["archived_at"] is not None

    # Archived topics refuse new entries.
    r = await client.post("/topics/sleep-log/entries", json={"answers": {"hours": 1}})
    assert r.status_code == 409
    assert r.json()["code"] == "topic_archived"

    r = await client.post("/topics/sleep-log/unarchive")
    assert r.json()["status"] == "active"
    assert r.json()["archived_at"] is None
    await record(client, "sleep-log", {"hours": 7, "wakeups": 1, "quality": "ok"})

    await client.post("/topics/sleep-log/archive")
    r = await client.delete("/topics/sleep-log")
    assert r.status_code == 204
    assert (await client.get(f"/topics/{t['id']}")).status_code == 404
    assert (await client.delete("/topics/sleep-log")).status_code == 404


async def _names(client: httpx.AsyncClient, **params: Any) -> list[str]:
    r = await client.get("/topics", params=params)
    assert r.status_code == 200, r.text
    return [t["name"] for t in r.json()["items"]]


async def test_search(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Sleep log", description="How did you sleep?")
    await make_topic(
        client,
        "Workout",
        questions=[{"key": "reps", "label": "Push-ups done", "type": "int"}],
    )
    await make_topic(
        client,
        "Mood 100% check",
        description="feelings_and_stuff",
        questions=[{"key": "mood", "label": "Mood", "type": "str"}],
    )

    assert await _names(client, q="sleep") == ["Sleep log"]
    assert await _names(client, q="SLEEP") == ["Sleep log"]  # case-insensitive
    assert await _names(client, q="you sleep") == ["Sleep log"]  # description
    assert await _names(client, q="push-ups") == ["Workout"]  # question label
    assert await _names(client, q="workout") == ["Workout"]  # slug/name
    assert await _names(client, q="nothing here") == []

    # LIKE wildcards are matched literally.
    assert await _names(client, q="100%") == ["Mood 100% check"]
    assert await _names(client, q="%") == ["Mood 100% check"]
    assert await _names(client, q="s_and") == ["Mood 100% check"]
    assert await _names(client, q="_") == ["Mood 100% check"]

    # Searching question config must not match JSON structure (keys/type names).
    assert await _names(client, q="label") == []
    assert await _names(client, q="required") == []
    assert await _names(client, q="type") == []


async def test_search_counts_match_items(client: httpx.AsyncClient) -> None:
    for n in range(3):
        await make_topic(client, f"Alpha {n}")
    await make_topic(client, "Beta")
    r = (await client.get("/topics", params={"q": "alpha", "limit": 2})).json()
    assert r["total"] == 3
    assert len(r["items"]) == 2


async def test_status_filter(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Active one")
    await make_topic(client, "Old one")
    await client.post("/topics/old-one/archive")
    assert await _names(client) == ["Active one"]
    assert await _names(client, status="archived") == ["Old one"]
    assert sorted(await _names(client, status="all")) == ["Active one", "Old one"]
    r = await client.get("/topics", params={"status": "bogus"})
    assert r.status_code == 422


async def test_sorts(client: httpx.AsyncClient) -> None:
    await make_topic(client, "banana")
    await make_topic(client, "Apple")
    await make_topic(client, "cherry")
    assert await _names(client, sort="name") == ["Apple", "banana", "cherry"]
    assert await _names(client, sort="-name") == ["cherry", "banana", "Apple"]
    assert await _names(client, sort="created") == ["banana", "Apple", "cherry"]
    assert await _names(client, sort="-created") == ["cherry", "Apple", "banana"]

    # Touching banana makes it most recently updated.
    await client.patch("/topics/banana", json={"description": "yellow"})
    assert (await _names(client, sort="-updated"))[0] == "banana"
    assert (await _names(client, sort="updated"))[-1] == "banana"

    # Activity = latest captured_at (falls back to updated_at).
    await record(
        client,
        "apple",
        {"hours": 1, "wakeups": 0, "quality": "ok"},
        captured_at="2026-01-01T00:00:00Z",
    )
    await record(
        client,
        "apple",
        {"hours": 1, "wakeups": 0, "quality": "ok"},
        captured_at=(datetime.now(UTC) + timedelta(hours=1)).isoformat(),
    )
    # Unscheduled topics sort by activity under the default "due" sort.
    assert (await _names(client))[0] == "Apple"
    assert (await _names(client, sort="-activity"))[0] == "Apple"
    assert (await _names(client, sort="activity"))[-1] == "Apple"
    r = await client.get("/topics", params={"sort": "bogus"})
    assert r.status_code == 422


async def test_pagination(client: httpx.AsyncClient) -> None:
    for n in range(5):
        await make_topic(client, f"T{n}")
    page = (await client.get("/topics", params={"sort": "name", "limit": 2, "offset": 2})).json()
    assert page["total"] == 5
    assert (page["limit"], page["offset"]) == (2, 2)
    assert [t["name"] for t in page["items"]] == ["T2", "T3"]
    last = (await client.get("/topics", params={"sort": "name", "limit": 2, "offset": 4})).json()
    assert [t["name"] for t in last["items"]] == ["T4"]
    beyond = (await client.get("/topics", params={"limit": 2, "offset": 50})).json()
    assert beyond["items"] == []
    assert beyond["total"] == 5
    for bad in ({"limit": 0}, {"limit": 201}, {"offset": -1}):
        assert (await client.get("/topics", params=bad)).status_code == 422


async def test_summary_counts(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await record(
        client, "sleep-log", {"hours": 1, "wakeups": 0, "quality": "ok"}, captured_at="2026-01-01T00:00:00Z"
    )
    await record(
        client, "sleep-log", {"hours": 2, "wakeups": 0, "quality": "ok"}, captured_at="2026-01-03T00:00:00Z"
    )
    (item,) = (await client.get("/topics")).json()["items"]
    assert item["entry_count"] == 2
    assert item["last_captured_at"] == "2026-01-03T00:00:00Z"
    detail = (await client.get("/topics/sleep-log")).json()
    assert detail["entry_count"] == 2


async def test_question_types(client: httpx.AsyncClient) -> None:
    r = await client.get("/question-types")
    assert r.status_code == 200
    body = r.json()
    assert [t["type"] for t in body] == ["int", "double", "str", "enum"]
    for t in body:
        assert t["description"]
        schema = t["json_schema"]
        assert schema["properties"]["type"]["const"] == t["type"]
        assert "key" in schema["properties"]
    enum_schema = body[3]["json_schema"]
    assert "options" in enum_schema["properties"]


async def test_slug_conflict_has_field_location(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post("/topics", json={"name": "Sleep log", "questions": sleep_questions()})
    assert r.status_code == 409
    assert r.json()["errors"][0]["loc"] == ["slug"]


async def test_request_validation_uses_problem_envelope(client: httpx.AsyncClient) -> None:
    r = await client.post("/topics", json={"name": "", "questions": "none"})
    assert r.status_code == 422
    body = r.json()
    assert body["code"] == "invalid_request"
    locs = [e["loc"] for e in body["errors"]]
    assert ["body", "name"] in locs
    assert ["body", "questions"] in locs
    r = await client.get("/topics", params={"limit": 0})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["query", "limit"]
