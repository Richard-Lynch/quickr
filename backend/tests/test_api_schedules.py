"""Topic schedules, due status and the 'due' listing over HTTP."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from tests.helpers import backdate_schedule, make_topic, record

QUESTIONS = [{"key": "n", "label": "N", "type": "int"}]


def every(minutes: int, **kw: Any) -> dict[str, Any]:
    return {"kind": "interval", "every_minutes": minutes, "timezone": "UTC", **kw}


def ago(**kw: float) -> str:
    return (datetime.now(UTC) - timedelta(**kw)).isoformat()


async def topic(
    client: httpx.AsyncClient, name: str, schedule: dict[str, Any] | None = None
) -> dict[str, Any]:
    extra = {"schedule": schedule} if schedule is not None else {}
    return await make_topic(client, name, QUESTIONS, **extra)


async def names(client: httpx.AsyncClient, **params: Any) -> list[str]:
    r = await client.get("/topics", params=params)
    assert r.status_code == 200, r.text
    return [t["name"] for t in r.json()["items"]]


async def test_create_with_schedule_and_due_status(client: httpx.AsyncClient) -> None:
    t = await topic(client, "Water", every(60))
    assert t["schedule"] == {"kind": "interval", "every_minutes": 60, "timezone": "UTC", "notify": True}
    # Never logged: due one interval after the schedule was set.
    assert t["schedule_updated_at"] == t["created_at"]
    since = datetime.fromisoformat(t["schedule_updated_at"])
    assert t["due"] == {
        "is_due": False,
        "due_since": None,
        "next_due_at": (since + timedelta(minutes=60)).isoformat().replace("+00:00", "Z"),
        "last_entry_at": None,
    }
    await backdate_schedule("water", since - timedelta(minutes=61))
    stale = (await client.get("/topics/water")).json()
    assert stale["due"]["is_due"] is True
    assert datetime.fromisoformat(stale["due"]["due_since"]) == since - timedelta(minutes=1)

    await record(client, "water", {"n": 1})
    detail = (await client.get("/topics/water")).json()
    assert detail["due"]["is_due"] is False
    assert detail["due"]["due_since"] is None
    last = datetime.fromisoformat(detail["due"]["last_entry_at"])
    assert datetime.fromisoformat(detail["due"]["next_due_at"]) == last + timedelta(minutes=60)

    plain = await topic(client, "Plain")
    assert (plain["schedule"], plain["due"]) == (None, None)


async def test_daily_schedule_roundtrip(client: httpx.AsyncClient) -> None:
    now = datetime.now(UTC)
    t = await topic(
        client,
        "Meds",
        {
            "kind": "daily",
            "times": sorted({"21:00", (now - timedelta(minutes=1)).strftime("%H:%M")}, reverse=True),
            "timezone": "UTC",
        },
    )
    assert t["schedule"]["days"] == [1, 2, 3, 4, 5, 6, 7]
    assert t["schedule"]["times"] == sorted(t["schedule"]["times"])
    # The slot a minute ago predates the schedule: not due yet.
    assert t["due"]["is_due"] is False
    await backdate_schedule("meds", now - timedelta(days=2))
    assert (await client.get("/topics/meds")).json()["due"]["is_due"] is True
    await record(client, "meds", {"n": 1})
    assert (await client.get("/topics/meds")).json()["due"]["is_due"] is False


async def test_patch_schedule_set_keep_clear(client: httpx.AsyncClient) -> None:
    await topic(client, "Water")
    r = await client.patch("/topics/water", json={"schedule": every(30, notify=False)})
    assert r.status_code == 200
    assert r.json()["schedule"]["notify"] is False
    # Omitted: unchanged.
    r = await client.patch("/topics/water", json={"description": "drink"})
    assert r.json()["schedule"]["every_minutes"] == 30
    # Explicit null clears.
    r = await client.patch("/topics/water", json={"schedule": None})
    assert (r.json()["schedule"], r.json()["due"], r.json()["schedule_updated_at"]) == (None, None, None)


async def test_patch_schedule_resets_reference_point(client: httpx.AsyncClient) -> None:
    await topic(client, "Water", every(60))
    long_ago = datetime.now(UTC) - timedelta(days=1)
    await backdate_schedule("water", long_ago)
    assert (await client.get("/topics/water")).json()["due"]["is_due"] is True

    # Re-sending the same schedule (or other metadata) keeps the reference point.
    for body in ({"schedule": every(60)}, {"description": "drink"}):
        r = (await client.patch("/topics/water", json=body)).json()
        assert datetime.fromisoformat(r["schedule_updated_at"]) == long_ago
        assert r["due"]["is_due"] is True

    # Changing it restarts the clock: not due until one new interval has passed.
    before = datetime.now(UTC) - timedelta(seconds=5)  # DB clock vs test clock
    r = (await client.patch("/topics/water", json={"schedule": every(90)})).json()
    assert datetime.fromisoformat(r["schedule_updated_at"]) >= before
    assert r["due"]["is_due"] is False
    assert datetime.fromisoformat(r["due"]["next_due_at"]) == datetime.fromisoformat(
        r["schedule_updated_at"]
    ) + timedelta(minutes=90)

    # Clearing and setting again also starts fresh.
    await backdate_schedule("water", long_ago)
    await client.patch("/topics/water", json={"schedule": None})
    r = (await client.patch("/topics/water", json={"schedule": every(90)})).json()
    assert datetime.fromisoformat(r["schedule_updated_at"]) >= before
    assert r["due"]["is_due"] is False


async def test_patch_daily_schedule_ignores_earlier_slots(client: httpx.AsyncClient) -> None:
    now = datetime.now(UTC)
    slot = (now - timedelta(minutes=5)).strftime("%H:%M")
    daily = {"kind": "daily", "times": [slot], "timezone": "UTC"}
    await topic(client, "Meds", every(60))
    await backdate_schedule("meds", now - timedelta(days=3))
    r = (await client.patch("/topics/meds", json={"schedule": daily})).json()
    # Today's slot passed before the change, so it is not due; tomorrow's is next.
    assert r["due"]["is_due"] is False
    assert datetime.fromisoformat(r["due"]["next_due_at"]) > now + timedelta(hours=23)


async def test_body_integers_are_strict(client: httpx.AsyncClient) -> None:
    await topic(client, "Water")
    r = await client.patch("/topics/water", json={"schedule": {**every(60), "every_minutes": "60"}})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "schedule", "every_minutes"]
    r = await client.post(
        "/topics/water/versions", json={"questions": QUESTIONS, "base_version": "1", "timer": None}
    )
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "base_version"]
    r = await client.post("/topics/water/entries", json={"answers": {"n": 1}, "version": "1"})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "version"]


async def test_schedule_validation_locations(client: httpx.AsyncClient) -> None:
    r = await client.post(
        "/topics",
        json={
            "name": "x",
            "questions": QUESTIONS,
            "schedule": {"kind": "daily", "times": ["25:00"], "timezone": "UTC"},
        },
    )
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {"loc": ["body", "schedule", "times", 0], "message": "must be a 24-hour time HH:MM, e.g. '08:00'"}
    ]
    await topic(client, "Water")
    r = await client.patch("/topics/water", json={"schedule": every(5)})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "schedule", "every_minutes"]
    r = await client.patch("/topics/water", json={"schedule": {**every(60), "timezone": "Nowhere/Land"}})
    assert r.json()["errors"][0]["loc"] == ["body", "schedule", "timezone"]


async def test_topic_field_validation_locations(client: httpx.AsyncClient) -> None:
    cases: list[tuple[dict[str, Any], list[str | int]]] = [
        ({"name": ""}, ["body", "name"]),
        ({"name": "   "}, ["body", "name"]),
        ({"name": "x" * 201}, ["body", "name"]),
        ({"name": "x", "slug": "Bad Slug"}, ["body", "slug"]),
        ({"name": "x", "description": "x" * 5001}, ["body", "description"]),
    ]
    for body, loc in cases:
        r = await client.post("/topics", json={"questions": QUESTIONS, **body})
        assert r.status_code == 422, body
        assert [e["loc"] for e in r.json()["errors"]] == [loc], (body, r.json())
    r = await client.post("/topics", json={"name": "x", "slug": "-x", "questions": QUESTIONS})
    assert r.json()["errors"][0]["message"].startswith("must start with a lowercase letter or digit")


async def test_due_sort_is_default(client: httpx.AsyncClient) -> None:
    for name, schedule, last in [
        ("Unscheduled old", None, ago(days=400)),
        ("Later", every(600), ago(hours=1)),
        ("Overdue 1h", every(60), ago(hours=2)),
        ("Sooner", every(300), ago(hours=1)),
        ("Overdue 2h", every(60), ago(hours=3)),
        ("Unscheduled new", None, None),
    ]:
        t = await topic(client, name, schedule)
        await backdate_schedule(t["slug"], datetime.now(UTC) - timedelta(days=1))
        if last is not None:
            await record(client, t["slug"], {"n": 1}, captured_at=last)

    expected = ["Overdue 2h", "Overdue 1h", "Sooner", "Later", "Unscheduled new", "Unscheduled old"]
    assert await names(client) == expected
    assert await names(client, sort="due") == expected
    assert await names(client, due_only=True) == ["Overdue 2h", "Overdue 1h"]
    page = (await client.get("/topics", params={"limit": 2, "offset": 2})).json()
    assert (page["total"], [t["name"] for t in page["items"]]) == (6, ["Sooner", "Later"])
    due_page = (await client.get("/topics", params={"due_only": True, "limit": 1})).json()
    assert (due_page["total"], [t["name"] for t in due_page["items"]]) == (2, ["Overdue 2h"])
    # due_only combines with other sorts and search.
    assert await names(client, due_only=True, sort="name") == ["Overdue 1h", "Overdue 2h"]
    assert await names(client, due_only=True, sort="-name") == ["Overdue 2h", "Overdue 1h"]
    assert await names(client, due_only=True, q="2h") == ["Overdue 2h"]


async def test_archived_topics_are_never_due(client: httpx.AsyncClient) -> None:
    await topic(client, "Water", every(60))
    archived = (await client.post("/topics/water/archive")).json()
    assert archived["due"] == {
        "is_due": False,
        "due_since": None,
        "next_due_at": None,
        "last_entry_at": None,
    }
    assert await names(client, due_only=True, status="all") == []
    assert await names(client, status="all") == ["Water"]


async def test_limits_endpoint(client: httpx.AsyncClient) -> None:
    r = await client.get("/limits")
    assert r.status_code == 200
    limits = r.json()
    assert limits["max_questions"] == 100
    assert limits["max_enum_options"] == 200
    assert limits["max_str_length"] == 10_000
    assert limits["schedule_max_times"] == 24
    assert (limits["interval_min_minutes"], limits["interval_max_minutes"]) == (15, 129_600)
    assert limits["captured_at_max_future_hours"] == 24
    assert limits["captured_at_min"] == "2000-01-01T00:00:00Z"
    assert limits["key_pattern"] == "^[a-z][a-z0-9_]{0,62}$"
