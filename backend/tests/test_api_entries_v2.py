"""Entries: idempotent client ids, captured_at window, multi-select answers over HTTP."""

from __future__ import annotations

import asyncio
import csv
import io
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import uuid4

import httpx

from tests.helpers import make_topic, record

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}


def factors_question(**kw: Any) -> dict[str, Any]:
    return {
        "key": "factors",
        "label": "Factors",
        "type": "enum",
        "multiple": True,
        "required": False,
        "options": [
            {"value": "caffeine", "label": "Caffeine"},
            {"value": "screen", "label": "Screens"},
            {"value": "stress", "label": "Stress"},
        ],
        **kw,
    }


def multi_questions(**kw: Any) -> list[dict[str, Any]]:
    return [{"key": "mood", "label": "Mood", "type": "int", "min": 1, "max": 5}, factors_question(**kw)]


# --- idempotency ----------------------------------------------------------------


async def test_client_id_is_used_and_replays_are_idempotent(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    entry_id = str(uuid4())
    first = await record(client, "sleep-log", ANSWERS, id=entry_id, captured_at="2026-05-01T08:00:00Z")
    assert first["id"] == entry_id
    # Same id again (even with different content): the original comes back, 201, no duplicate.
    r = await client.post(
        "/topics/sleep-log/entries", json={"id": entry_id, "answers": {**ANSWERS, "wakeups": 9}}
    )
    assert r.status_code == 201
    assert r.json() == first
    assert (await client.get("/topics/sleep-log/entries")).json()["total"] == 1


async def test_replay_after_archive_returns_existing(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    entry_id = str(uuid4())
    first = await record(client, "sleep-log", ANSWERS, id=entry_id)
    await client.post("/topics/sleep-log/archive")
    r = await client.post("/topics/sleep-log/entries", json={"id": entry_id, "answers": ANSWERS})
    assert r.status_code == 201
    assert r.json()["id"] == first["id"]
    # A new entry is still refused.
    r = await client.post("/topics/sleep-log/entries", json={"id": str(uuid4()), "answers": ANSWERS})
    assert (r.status_code, r.json()["code"]) == (409, "topic_archived")


async def test_same_id_under_another_topic_conflicts(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await make_topic(client, "Other")
    entry_id = str(uuid4())
    await record(client, "sleep-log", ANSWERS, id=entry_id)
    r = await client.post("/topics/other/entries", json={"id": entry_id, "answers": ANSWERS})
    assert r.status_code == 409
    assert r.json()["code"] == "conflict"
    assert r.json()["errors"] == [{"loc": ["id"], "message": "already used by an entry of another topic"}]


async def test_concurrent_duplicate_submits_do_not_500(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    entry_id = str(uuid4())
    body = {"id": entry_id, "answers": ANSWERS}
    responses = await asyncio.gather(*(client.post("/topics/sleep-log/entries", json=body) for _ in range(5)))
    assert {r.status_code for r in responses} == {201}
    assert {r.json()["id"] for r in responses} == {entry_id}
    assert (await client.get("/topics/sleep-log/entries")).json()["total"] == 1


async def test_invalid_client_id(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post("/topics/sleep-log/entries", json={"id": "nope", "answers": ANSWERS})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "id"]


# --- captured_at window -----------------------------------------------------------


async def test_captured_at_window(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    soon = datetime.now(UTC) + timedelta(hours=23)
    s = await record(client, "sleep-log", ANSWERS, captured_at=soon.isoformat())
    assert datetime.fromisoformat(s["captured_at"]) == soon.replace(microsecond=soon.microsecond)
    # Late (offline) submissions far in the past are fine.
    await record(client, "sleep-log", ANSWERS, captured_at="2000-01-01T00:00:00Z")

    too_late = (datetime.now(UTC) + timedelta(hours=25)).isoformat()
    for value, message in [
        (too_late, "must not be more than 24 hours in the future"),
        ("1999-12-31T23:59:59Z", "must not be before 2000-01-01"),
    ]:
        r = await client.post("/topics/sleep-log/entries", json={"answers": ANSWERS, "captured_at": value})
        assert r.status_code == 422
        assert r.json()["errors"] == [{"loc": ["body", "captured_at"], "message": message}]

    r = await client.patch(f"/entries/{s['id']}", json={"captured_at": too_late})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["body", "captured_at"]


async def test_entry_field_limits(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    cases: list[tuple[dict[str, Any], list[str | int]]] = [
        ({"source": "   "}, ["body", "source"]),
        ({"source": "x" * 101}, ["body", "source"]),
        ({"notes": "x" * 5001}, ["body", "notes"]),
        ({"meta": {f"k{i}": "v" for i in range(51)}}, ["body", "meta"]),
        ({"meta": {"k": "x" * 501}}, ["body", "meta", "k"]),
        ({"version": 0}, ["body", "version"]),
    ]
    for extra, loc in cases:
        r = await client.post("/topics/sleep-log/entries", json={"answers": ANSWERS, **extra})
        assert r.status_code == 422, extra
        assert [e["loc"] for e in r.json()["errors"]] == [loc], (extra, r.json())


async def test_bad_answer_type_is_one_error(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post("/topics/sleep-log/entries", json={"answers": {**ANSWERS, "hours": {"x": 1}}})
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {
            "loc": ["body", "answers", "hours"],
            "message": "must be a number, a string, or a list of strings (multi-select)",
        }
    ]


# --- multi-select -------------------------------------------------------------------


async def test_multi_select_roundtrip(client: httpx.AsyncClient) -> None:
    t = await make_topic(client, "Day", multi_questions(max_selected=2))
    factors = t["questions"][1]
    assert (factors["multiple"], factors["min_selected"], factors["max_selected"]) == (True, None, 2)
    e = await record(client, "day", {"mood": 3, "factors": ["stress", "caffeine"]})
    assert e["answers"] == [
        {"key": "mood", "type": "int", "value": 3},
        {"key": "factors", "type": "enum_list", "value": ["caffeine", "stress"]},
    ]
    assert (await client.get(f"/entries/{e['id']}")).json() == e

    # Empty list = unanswered (optional question).
    e2 = await record(client, "day", {"mood": 2, "factors": []})
    assert [a["key"] for a in e2["answers"]] == ["mood"]

    r = await client.post("/topics/day/entries", json={"answers": {"mood": 3, "factors": ["a", "b", "c"]}})
    assert r.status_code == 422
    assert r.json()["code"] == "invalid_answers"
    assert [i["loc"] for i in r.json()["errors"]] == [
        ["answers", "factors", 0],
        ["answers", "factors", 1],
        ["answers", "factors", 2],
    ]
    r = await client.post(
        "/topics/day/entries", json={"answers": {"mood": 3, "factors": ["caffeine", "screen", "stress"]}}
    )
    assert r.json()["errors"] == [{"loc": ["answers", "factors"], "message": "select at most 2 options"}]


async def test_multi_select_update_keeps_archived_held_options(client: httpx.AsyncClient) -> None:
    t = await make_topic(client, "Day", multi_questions())
    e = await record(client, "day", {"mood": 3, "factors": ["caffeine", "screen"]})
    archived = multi_questions()
    archived[1]["options"][0]["archived"] = True  # caffeine
    r = await client.post(
        "/topics/day/versions",
        json={"questions": archived, "base_version": t["current_version"], "timer": None},
    )
    assert r.status_code == 201

    # New v2 entries cannot pick caffeine ...
    r = await client.post("/topics/day/entries", json={"answers": {"mood": 3, "factors": ["caffeine"]}})
    assert r.status_code == 422
    # ... and editing the v1 entry can keep it, even alongside a change.
    r = await client.patch(f"/entries/{e['id']}", json={"answers": {"factors": ["caffeine", "stress"]}})
    assert r.status_code == 200, r.text
    assert r.json()["answers"][1]["value"] == ["caffeine", "stress"]
    # Pinned to v1 where caffeine is active anyway; check against a v2 entry instead.
    e2 = await record(client, "day", {"mood": 3, "factors": ["screen"]})
    r = await client.patch(f"/entries/{e2['id']}", json={"answers": {"factors": ["caffeine"]}})
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {"loc": ["answers", "factors", 0], "message": "option 'caffeine' is archived"}
    ]


async def test_single_to_multi_keeps_old_answers_readable(client: httpx.AsyncClient) -> None:
    single = multi_questions()
    single[1] = {k: v for k, v in single[1].items() if k != "multiple"}
    t = await make_topic(client, "Day", single)
    old = await record(client, "day", {"mood": 3, "factors": "screen"})
    r = await client.post(
        "/topics/day/versions",
        json={"questions": multi_questions(), "base_version": t["current_version"], "timer": None},
    )
    assert r.status_code == 201
    new = await record(client, "day", {"mood": 4, "factors": ["screen", "stress"]})
    assert old["answers"][1] == {"key": "factors", "type": "enum", "value": "screen"}
    assert new["answers"][1] == {"key": "factors", "type": "enum_list", "value": ["screen", "stress"]}

    # Stats count both shapes; shares are per answered entry and may sum past 1.
    stats = (await client.get("/topics/day/stats")).json()
    factors = next(q for q in stats["questions"] if q["key"] == "factors")
    assert (factors["type"], factors["multiple"], factors["count"], factors["missing"]) == (
        "enum",
        True,
        2,
        0,
    )
    counts = {o["value"]: (o["count"], o["share"]) for o in factors["options"]}
    assert counts == {"caffeine": (0, 0.0), "screen": (2, 1.0), "stress": (1, 0.5)}

    series = (await client.get("/topics/day/questions/factors/series", params={"bucket": "month"})).json()
    assert sum(p["count"] for p in series["points"]) == 2
    totals: dict[str, int] = {}
    for p in series["points"]:
        for k, v in p["option_counts"].items():
            totals[k] = totals.get(k, 0) + v
    assert totals == {"screen": 2, "stress": 1}

    # CSV joins multi-select values with ';'.
    text = (await client.get("/topics/day/entries.csv")).text
    rows = list(csv.DictReader(io.StringIO(text)))
    assert list(rows[0])[:2] == ["entry_id", "captured_at"]
    assert sorted(r["factors"] for r in rows) == ["screen", "screen;stress"]


async def test_multi_stats_missing_and_filters(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Day", multi_questions())
    await record(
        client,
        "day",
        {"mood": 1, "factors": ["caffeine", "screen", "stress"]},
        captured_at="2026-01-01T00:00:00Z",
    )
    await record(client, "day", {"mood": 2, "factors": ["caffeine"]}, captured_at="2026-02-01T00:00:00Z")
    await record(client, "day", {"mood": 3}, captured_at="2026-03-01T00:00:00Z")
    stats = (await client.get("/topics/day/stats")).json()
    factors = next(q for q in stats["questions"] if q["key"] == "factors")
    assert (factors["count"], factors["missing"]) == (2, 1)
    assert {o["value"]: o["count"] for o in factors["options"]} == {"caffeine": 2, "screen": 1, "stress": 1}
    filtered = (
        await client.get("/topics/day/stats", params={"captured_from": "2026-01-15T00:00:00Z"})
    ).json()
    factors = next(q for q in filtered["questions"] if q["key"] == "factors")
    assert {o["value"]: o["count"] for o in factors["options"]} == {"caffeine": 1, "screen": 0, "stress": 0}
