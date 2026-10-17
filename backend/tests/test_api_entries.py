"""Entry create / update / delete / list over HTTP."""

from __future__ import annotations

from datetime import UTC, datetime

import httpx

from tests.helpers import make_topic, record, sleep_questions

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}


def answers_of(entry: dict[str, object]) -> dict[str, object]:
    items = entry["answers"]
    assert isinstance(items, list)
    return {a["key"]: a["value"] for a in items}


async def test_create_with_defaults(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    before = datetime.now(UTC)
    s = await record(client, "sleep-log", ANSWERS)
    assert s["topic_id"] == t["id"]
    assert s["version"] == 1
    assert s["channel"] == "api"
    assert s["source"] == "api"  # defaults to the channel
    assert s["notes"] == ""
    assert s["meta"] == {}
    assert datetime.fromisoformat(s["captured_at"]) >= before.replace(microsecond=0)
    assert s["answers"] == [
        {"key": "hours", "type": "double", "value": 7.5},
        {"key": "wakeups", "type": "int", "value": 1},
        {"key": "quality", "type": "enum", "value": "ok"},
    ]
    assert (await client.get(f"/entries/{s['id']}")).json() == s


async def test_channel_header_and_explicit_fields(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post(
        "/topics/sleep-log/entries",
        json={"answers": ANSWERS},
        headers={"X-QuickR-Channel": "ui"},
    )
    assert r.status_code == 201
    assert (r.json()["channel"], r.json()["source"]) == ("ui", "ui")

    r = await client.post(
        "/topics/sleep-log/entries",
        json={"answers": ANSWERS, "source": "ios.widget"},
        headers={"X-QuickR-Channel": "ios"},
    )
    assert r.status_code == 201
    assert (r.json()["channel"], r.json()["source"]) == ("ios", "ios.widget")
    r = await client.get("/topics/sleep-log/entries", params={"channel": "ios"})
    assert r.json()["total"] == 1

    s = await record(
        client,
        "sleep-log",
        {**ANSWERS, "dream": "  flying  "},
        source="garmin",
        captured_at="2026-03-01T08:00:00+02:00",
        notes="note",
        meta={"device": "watch"},
    )
    assert (s["channel"], s["source"]) == ("api", "garmin")
    assert s["captured_at"] == "2026-03-01T06:00:00Z"
    assert (s["notes"], s["meta"]) == ("note", {"device": "watch"})
    assert answers_of(s)["dream"] == "flying"

    r = await client.post(
        "/topics/sleep-log/entries", json={"answers": ANSWERS}, headers={"X-QuickR-Channel": "fax"}
    )
    assert r.status_code == 422


async def test_naive_captured_at_rejected(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post(
        "/topics/sleep-log/entries", json={"answers": ANSWERS, "captured_at": "2026-03-01T08:00:00"}
    )
    assert r.status_code == 422


async def test_int_given_as_float_stored_as_int(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s = await record(client, "sleep-log", {**ANSWERS, "wakeups": 2.0, "hours": 8})
    assert s["answers"][0] == {"key": "hours", "type": "double", "value": 8.0}
    assert s["answers"][1] == {"key": "wakeups", "type": "int", "value": 2}


async def test_invalid_answers_problem(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post(
        "/topics/sleep-log/entries",
        json={"answers": {"hours": 30, "wakeups": "2", "quality": "superb", "ghost": 1}},
    )
    assert r.status_code == 422
    body = r.json()
    assert body["code"] == "invalid_answers"
    assert body["detail"] == "one or more answers are invalid"
    errors = {e["loc"][1]: e["message"] for e in body["errors"]}
    assert errors == {
        "ghost": "unknown question",
        "hours": "must be <= 24",
        "wakeups": "must be an integer",
        "quality": "must be one of: great, ok, poor",
    }
    assert all(e["loc"][0] == "answers" for e in body["errors"])

    # Missing required answers.
    r = await client.post("/topics/sleep-log/entries", json={"answers": {}})
    assert {e["loc"][1] for e in r.json()["errors"]} == {"hours", "wakeups", "quality"}

    # Booleans are rejected at the request level (strict types).
    r = await client.post("/topics/sleep-log/entries", json={"answers": {**ANSWERS, "wakeups": True}})
    assert r.status_code == 422

    # Huge integers are validation errors, not 500s.
    qs = [{"key": "n", "label": "N", "type": "int"}]
    await make_topic(client, "Big", questions=qs)
    r = await client.post("/topics/big/entries", json={"answers": {"n": 2**70}})
    assert r.status_code == 422
    assert r.json()["code"] == "invalid_answers"


async def test_patch_merges_and_null_clears(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s = await record(client, "sleep-log", {**ANSWERS, "dream": "boat"}, notes="n1", meta={"a": "1"})

    r = await client.patch(f"/entries/{s['id']}", json={"answers": {"wakeups": 4}})
    assert r.status_code == 200
    u = r.json()
    assert answers_of(u) == {"hours": 7.5, "wakeups": 4, "quality": "ok", "dream": "boat"}
    assert (u["notes"], u["meta"], u["source"]) == ("n1", {"a": "1"}, "api")
    assert u["updated_at"] > s["updated_at"]
    assert u["created_at"] == s["created_at"]

    # null clears an optional answer.
    u = (await client.patch(f"/entries/{s['id']}", json={"answers": {"dream": None}})).json()
    assert "dream" not in answers_of(u)

    # Clearing a required answer is a validation error and changes nothing.
    r = await client.patch(f"/entries/{s['id']}", json={"answers": {"hours": None}})
    assert r.status_code == 422
    assert r.json()["errors"] == [{"loc": ["answers", "hours"], "message": "required"}]
    assert answers_of((await client.get(f"/entries/{s['id']}")).json())["hours"] == 7.5

    # Metadata-only update leaves answers alone.
    u = (
        await client.patch(
            f"/entries/{s['id']}",
            json={"notes": "n2", "meta": {"b": "2"}, "source": "fix", "captured_at": "2026-01-01T00:00:00Z"},
        )
    ).json()
    assert (u["notes"], u["meta"], u["source"], u["captured_at"]) == (
        "n2",
        {"b": "2"},
        "fix",
        "2026-01-01T00:00:00Z",
    )
    assert answers_of(u) == {"hours": 7.5, "wakeups": 4, "quality": "ok"}

    r = await client.patch(f"/entries/{s['id']}", json={"answers": {"nope": 1}})
    assert r.status_code == 422
    r = await client.patch(f"/entries/{s['id']}", json={"channel": "ui"})
    assert r.status_code == 422


async def test_editing_keeps_archived_enum_value_valid(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s = await record(client, "sleep-log", {**ANSWERS, "quality": "poor"})
    # Archive 'poor' in v2 and record against v2.
    qs = sleep_questions()
    qs[2]["options"][0]["archived"] = True
    r = await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    assert r.status_code == 201
    s2 = await record(client, "sleep-log", {**ANSWERS, "quality": "ok"})
    assert s2["version"] == 2
    r = await client.post("/topics/sleep-log/entries", json={"answers": {**ANSWERS, "quality": "poor"}})
    assert r.json()["errors"] == [{"loc": ["answers", "quality"], "message": "option is archived"}]

    # A v2 entry that holds the archived value (recorded before archiving is
    # impossible, so use a v1 entry) can still be edited around it.
    u = await client.patch(f"/entries/{s['id']}", json={"answers": {"hours": 6}})
    assert u.status_code == 200
    assert answers_of(u.json())["quality"] == "poor"

    # But a v2 entry cannot be switched to the archived value.
    r = await client.patch(f"/entries/{s2['id']}", json={"answers": {"quality": "poor"}})
    assert r.status_code == 422


async def test_editing_v2_entry_holding_archived_value(client: httpx.AsyncClient) -> None:
    """An entry on the archiving version itself, holding the archived value, stays editable."""
    await make_topic(client)
    qs = sleep_questions()
    qs[0]["label"] = "Hours"
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    s = await record(client, "sleep-log", {**ANSWERS, "quality": "poor"})
    assert s["version"] == 2
    # v3 archives 'poor'; s is pinned to v2 where it is active, so edits are fine.
    qs[2]["options"][0]["archived"] = True
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 2})
    s3 = await record(client, "sleep-log", ANSWERS)
    assert s3["version"] == 3
    r = await client.patch(f"/entries/{s['id']}", json={"answers": {"wakeups": 0}})
    assert r.status_code == 200


async def test_delete_entry(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s = await record(client, "sleep-log", ANSWERS)
    assert (await client.delete(f"/entries/{s['id']}")).status_code == 204
    assert (await client.get(f"/entries/{s['id']}")).status_code == 404
    assert (await client.delete(f"/entries/{s['id']}")).status_code == 404
    assert (await client.patch(f"/entries/{s['id']}", json={"notes": "x"})).status_code == 404
    assert (await client.get("/entries/not-a-uuid")).status_code == 422


async def test_list_entries_filters_order_pagination(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    ids = []
    for day, source in [(3, "a"), (1, "b"), (2, "a")]:
        s = await record(client, "sleep-log", ANSWERS, source=source, captured_at=f"2026-05-0{day}T12:00:00Z")
        ids.append(s["id"])
    await client.post(
        "/topics/sleep-log/entries", json={"answers": ANSWERS}, headers={"X-QuickR-Channel": "mcp"}
    )

    page = (await client.get("/topics/sleep-log/entries")).json()
    assert page["total"] == 4
    days = [s["captured_at"][:10] for s in page["items"][1:]]
    assert days == ["2026-05-03", "2026-05-02", "2026-05-01"]  # newest first

    asc = (await client.get("/topics/sleep-log/entries", params={"order": "captured_at"})).json()
    assert asc["items"][0]["captured_at"].startswith("2026-05-01")
    created = (await client.get("/topics/sleep-log/entries", params={"order": "created_at"})).json()
    assert [s["id"] for s in created["items"][:3]] == ids

    async def total(**params: str | int) -> int:
        r = await client.get("/topics/sleep-log/entries", params=params)
        assert r.status_code == 200, r.text
        n: int = r.json()["total"]
        return n

    assert await total(source="a") == 2
    assert await total(channel="mcp") == 1
    assert await total(captured_from="2026-05-02T00:00:00Z", captured_to="2026-05-03T00:00:00Z") == 1
    assert await total(captured_from="2026-05-02T12:00:00Z") == 3  # inclusive lower bound
    assert await total(captured_to="2026-05-02T12:00:00Z") == 1  # exclusive upper bound
    assert await total(version=2) == 0

    p = (await client.get("/topics/sleep-log/entries", params={"limit": 1, "offset": 1})).json()
    assert len(p["items"]) == 1
    assert (p["limit"], p["offset"], p["total"]) == (1, 1, 4)

    r = await client.get("/topics/sleep-log/entries", params={"captured_from": "2026-05-02T00:00:00"})
    assert r.status_code == 422  # naive datetimes rejected
    assert (await client.get("/topics/nope/entries")).status_code == 404
