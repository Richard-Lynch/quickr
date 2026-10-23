"""Stats and series vectors for the Swift port: ``shared/fixtures/stats-vectors.json``.

The iOS app shows ``GET /topics/{ref}/stats`` and ``GET /topics/{ref}/questions/{key}/series``
as the server computes them (``app/services/stats.py``): it never buckets on the device. So
these vectors are real responses over data built to exercise the bucketing the charts then
lay out and label (``frontend`` turns them into ``stats-chart-vectors.json``):

- Europe/London's spring-forward (2025-03-30) and fall-back (2025-10-26) days, with entries
  whose UTC and local days differ;
- America/Santiago, whose DST starts at midnight (2025-09-07: 00:00 local doesn't exist) and
  ends with a repeated 23:00 hour (2025-04-05);
- Asia/Kolkata (+05:30), and a week and a month across the new year;
- empty and single-entry topics, and a 400-day topic with large and negative doubles;
- every question kind: int, double, single and multi-select enum (with an archived option), str,
  and a retired question (removed in v2) that still holds data.

The data goes through the real app (ASGI client, test database) with fixed ids and
``captured_at`` values. Two values come from the database clock or the id generator and are
pinned: each topic's ``topic_id`` becomes ``TOPIC_IDS[slug]``. No wall clock otherwise.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the committed file
must match.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlencode
from uuid import UUID

import httpx
import pytest

from tests.helpers import make_topic
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "stats-vectors.json"
GENERATOR_VERSION = 1
TOPIC_IDS = {
    "everything": "5a7c0000-0000-4000-8000-000000000001",
    "empty": "5a7c0000-0000-4000-8000-000000000002",
    "single": "5a7c0000-0000-4000-8000-000000000003",
    "many": "5a7c0000-0000-4000-8000-000000000004",
}
ZONES = ["UTC", "Europe/London", "America/Santiago", "Asia/Kolkata"]
BUCKETS = ["day", "week", "month"]


def utc(month: int, day: int, hour: int = 0, minute: int = 0, year: int = 2025) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=UTC)


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def entry_id(n: int) -> str:
    return str(UUID(f"5a7ce000-0000-4000-8000-{n:012x}"))


MOOD = [
    {"value": "good", "label": "Good"},
    {"value": "ok", "label": "OK"},
    {"value": "bad", "label": "Bad"},
    {"value": "meh", "label": "Meh"},
]
TAGS = [
    {"value": "work", "label": "Work"},
    {"value": "family", "label": "Family"},
    {"value": "sport", "label": "Sport"},
]
EVERYTHING_V1: list[dict[str, Any]] = [
    {"key": "glasses", "label": "Glasses", "type": "int", "min": 0, "max": 50, "unit": "glasses"},
    {"key": "hours", "label": "Hours slept", "type": "double", "min": 0, "max": 24, "unit": "h"},
    {"key": "mood", "label": "Mood", "type": "enum", "options": MOOD},
    {"key": "tags", "label": "Tags", "type": "enum", "multiple": True, "options": TAGS, "required": False},
    {"key": "note", "label": "Note", "type": "str", "required": False},
    {"key": "old", "label": "Old score", "type": "int", "required": False},
]
# v2: "meh" archived, "old" retired.
EVERYTHING_V2: list[dict[str, Any]] = [
    *EVERYTHING_V1[:2],
    {"key": "mood", "label": "Mood", "type": "enum", "options": [*MOOD[:3], {**MOOD[3], "archived": True}]},
    EVERYTHING_V1[3],
    EVERYTHING_V1[4],
]

# (captured_at, source, answers, version). Comments give the local days that matter. All in the
# past (the API refuses a captured_at more than a day ahead), in 2025.
EVERYTHING_ENTRIES: list[tuple[datetime, str, dict[str, Any], int]] = [
    # Santiago fall-back: 23:00-24:00 local on Sat 5 Apr happens twice (-03 then -04).
    (utc(4, 6, 2, 30), "ios", {"glasses": 3, "hours": 7.5, "mood": "meh", "old": 4, "tags": ["work"]}, 1),
    (utc(4, 6, 3, 30), "web", {"glasses": 5, "hours": 6.25, "mood": "good", "old": 2}, 1),
    # London spring-forward: 29 Mar 23:30 GMT; 30 Mar 00:30 GMT; 30 Mar 23:30Z is 31 Mar 00:30 BST.
    (utc(3, 29, 23, 30), "ios", {"glasses": 8, "hours": 8.0, "mood": "ok", "note": "late", "tags": []}, 2),
    (utc(3, 30, 0, 30), "ios", {"glasses": 2, "hours": 5.5, "mood": "bad", "note": "late"}, 2),
    (utc(3, 30, 23, 30), "web", {"glasses": 6, "hours": 7.0, "mood": "good", "tags": ["work", "sport"]}, 2),
    # Santiago spring-forward: 7 Sep 03:30Z is Sat 6 Sep 23:30 -04; 04:30Z is Sun 7 Sep 01:30 -03.
    (utc(9, 7, 3, 30), "mcp", {"glasses": 4, "hours": 9.75, "mood": "good", "note": "Gap eve"}, 2),
    (utc(9, 7, 4, 30), "ios", {"glasses": 7, "hours": 6.0, "mood": "ok", "tags": ["family"], "note": "x"}, 2),
    (utc(9, 7, 12, 0), "ios", {"glasses": 1, "hours": 4.5, "mood": "ok", "tags": ["family", "work"]}, 2),
    # London fall-back: 25 Oct 23:30Z is 26 Oct 00:30 BST; 26 Oct 23:30Z is 26 Oct 23:30 GMT.
    (utc(10, 25, 23, 30), "web", {"glasses": 9, "hours": 7.25, "mood": "bad", "note": "x"}, 2),
    (
        utc(10, 26, 23, 30),
        "ios",
        {"glasses": 3, "hours": 8.5, "mood": "good", "tags": ["sport"], "note": "x"},
        2,
    ),
    # New year: Wed 31 Dec 2025 in London; Thu 1 Jan 2026 in Kolkata (+05:30).
    (utc(12, 31, 20, 0), "ios", {"glasses": 10, "hours": 6.75, "mood": "ok", "note": "NYE"}, 2),
    (utc(1, 1, 9, 0, year=2026), "ios", {"glasses": 0, "hours": 10.0, "mood": "good", "tags": ["family"]}, 2),
]

SINGLE_QUESTIONS: list[dict[str, Any]] = [
    {"key": "n", "label": "Count", "type": "int"},
    {"key": "x", "label": "Weight", "type": "double", "unit": "kg"},
    {"key": "pick", "label": "Pick", "type": "enum", "multiple": True, "options": TAGS},
]
MANY_QUESTIONS: list[dict[str, Any]] = [
    {"key": "n", "label": "Steps", "type": "int"},
    {"key": "d", "label": "Balance", "type": "double", "unit": "EUR"},
    {
        "key": "c",
        "label": "Colour",
        "type": "enum",
        "options": [{"value": f"c{i}", "label": f"Colour {i}"} for i in range(8)],
    },
]
MANY_START = utc(6, 1, 12, 0, year=2024)
MANY_DAYS = 400


def many_answers(i: int) -> dict[str, Any]:
    return {"n": (i * 7919) % 20000, "d": round((i - 200) * 12345.678, 3), "c": f"c{(i * i) % 8}"}


def stats_path(slug: str, query: dict[str, str]) -> str:
    qs = urlencode(query)
    return f"/api/v1/topics/{slug}/stats" + (f"?{qs}" if qs else "")


def series_path(slug: str, key: str, query: dict[str, str]) -> str:
    return f"/api/v1/topics/{slug}/questions/{key}/series?{urlencode(query)}"


async def build(client: httpx.AsyncClient) -> dict[str, Any]:
    ids: dict[str, str] = {}

    async def topic(name: str, slug: str, questions: list[dict[str, Any]]) -> None:
        ids[slug] = (await make_topic(client, name, questions, slug=slug))["id"]

    async def post(
        slug: str, n: int, at: datetime, source: str, answers: dict[str, Any], version: int
    ) -> None:
        body = {
            "id": entry_id(n),
            "answers": answers,
            "captured_at": iso(at),
            "source": source,
            "version": version,
        }
        r = await client.post(f"/topics/{slug}/entries", json=body)
        assert r.status_code == 201, r.text

    await topic("Everything", "everything", EVERYTHING_V1)
    for n, (at, source, answers, version) in enumerate(EVERYTHING_ENTRIES):
        if version == 2:
            current = (await client.get("/topics/everything")).json()["current_version"]
            if current == 1:
                r = await client.post(
                    "/topics/everything/versions",
                    json={"questions": EVERYTHING_V2, "base_version": 1, "timer": None},
                )
                assert r.status_code == 201, r.text
        await post("everything", n, at, source, answers, version)
    await topic("Empty", "empty", SINGLE_QUESTIONS)
    await topic("Single", "single", SINGLE_QUESTIONS)
    await post("single", 100, utc(6, 15, 9, 0), "ios", {"n": 4, "x": 72.5, "pick": ["sport"]}, 1)
    await topic("Many", "many", MANY_QUESTIONS)
    for i in range(MANY_DAYS):
        await post("many", 1000 + i, MANY_START + timedelta(days=i), "ios", many_answers(i), 1)

    cases: list[dict[str, Any]] = []

    async def get(
        name: str, kind: str, slug: str, path: str, query: dict[str, str], key: str | None = None
    ) -> None:
        r = await client.get(path.removeprefix("/api/v1"))
        assert r.status_code == 200, r.text
        body = r.json()
        if kind == "stats":
            assert body["topic_id"] == ids[slug]
            body["topic_id"] = TOPIC_IDS[slug]
        case: dict[str, Any] = {"name": name, "kind": kind, "topic": slug, "query": query, "response": body}
        if key is not None:
            case["question"] = key
        cases.append(case)

    stat_queries: list[tuple[str, str, dict[str, str]]] = [
        ("everything", "all", {}),
        ("everything", "source web", {"source": "web"}),
        ("everything", "from Santiago gap eve", {"captured_from": "2025-09-06T00:00:00-04:00"}),
        ("everything", "version 1", {"version": "1"}),
        ("empty", "all", {}),
        ("single", "all", {}),
        ("many", "all", {}),
    ]
    for slug, label, query in stat_queries:
        await get(f"stats {slug} {label}", "stats", slug, stats_path(slug, query), query)

    for key in ["glasses", "hours", "mood", "tags", "note", "old"]:
        for bucket in BUCKETS:
            for tz in ZONES:
                query = {"bucket": bucket, "tz": tz}
                path = series_path("everything", key, query)
                await get(f"series everything {key} {bucket} {tz}", "series", "everything", path, query, key)
    for key, query in [
        ("mood", {"bucket": "day", "tz": "Europe/London", "source": "web"}),
        (
            "glasses",
            {"bucket": "week", "tz": "America/Santiago", "captured_from": "2025-09-06T00:00:00-04:00"},
        ),
    ]:
        name = f"series everything {key} filtered {query['bucket']} {query['tz']}"
        await get(name, "series", "everything", series_path("everything", key, query), query, key)
    for slug in ["empty", "single"]:
        for key in ["n", "x", "pick"]:
            query = {"bucket": "day", "tz": "Europe/London"}
            await get(f"series {slug} {key} day", "series", slug, series_path(slug, key, query), query, key)
    for key in ["n", "d", "c"]:
        for bucket in BUCKETS:
            query = {"bucket": bucket, "tz": "Europe/London"}
            await get(
                f"series many {key} {bucket}", "series", "many", series_path("many", key, query), query, key
            )

    return {
        "meta": {
            "generator_version": GENERATOR_VERSION,
            "topic_ids": TOPIC_IDS,
            "semantics": (
                "Each case is one real response. 'query' holds the request's query parameters "
                "(stats: the entry filters; series: bucket, tz and the filters). Series buckets "
                "are the server's: date_trunc in 'tz' (weeks start on Monday), each 'start' the "
                "UTC instant of the bucket's local start, buckets without answers omitted. "
                "topic_id is pinned per topic (meta.topic_ids)."
            ),
        },
        "cases": cases,
    }


@pytest.mark.asyncio
async def test_stats_vectors(client: httpx.AsyncClient) -> None:
    check_or_write(PATH, dump_cases(await build(client)))
