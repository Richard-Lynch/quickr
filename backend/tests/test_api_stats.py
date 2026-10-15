"""Stats, series and CSV export over HTTP."""

from __future__ import annotations

import csv
import io
import math
import statistics
from typing import Any

import httpx
import pytest

from tests.helpers import make_topic, record, sleep_questions


def by_key(stats: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {q["key"]: q for q in stats["questions"]}


async def seed(client: httpx.AsyncClient) -> list[dict[str, Any]]:
    qs = [*sleep_questions(), {"key": "unused", "label": "Unused", "type": "int", "required": False}]
    await make_topic(client, questions=qs)
    rows = [
        ("2026-05-01T08:00:00Z", "phone", {"hours": 6, "wakeups": 0, "quality": "poor", "dream": "falling"}),
        ("2026-05-02T08:00:00Z", "phone", {"hours": 7, "wakeups": 1, "quality": "ok", "dream": "falling"}),
        ("2026-05-03T08:00:00Z", "watch", {"hours": 8, "wakeups": 1, "quality": "ok", "dream": "flying"}),
        ("2026-05-04T08:00:00Z", "phone", {"hours": 8, "wakeups": 3, "quality": "great"}),
    ]
    return [
        await record(client, "sleep-log", answers, source=source, captured_at=ts)
        for ts, source, answers in rows
    ]


async def stats(client: httpx.AsyncClient, **params: Any) -> dict[str, Any]:
    r = await client.get("/topics/sleep-log/stats", params=params)
    assert r.status_code == 200, r.text
    body: dict[str, Any] = r.json()
    return body


async def test_stats_empty_topic(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s = await stats(client)
    assert s["entry_count"] == 0
    assert s["first_captured_at"] is None
    assert s["sources"] == []
    q = by_key(s)
    assert list(q) == ["hours", "wakeups", "quality", "dream"]
    assert q["hours"]["count"] == 0
    assert q["hours"]["mean"] is None
    assert q["hours"]["histogram"] == []
    assert [o["share"] for o in q["quality"]["options"]] == [0.0, 0.0, 0.0]


async def test_numeric_stats(client: httpx.AsyncClient) -> None:
    await seed(client)
    s = await stats(client)
    assert s["entry_count"] == 4
    assert s["first_captured_at"] == "2026-05-01T08:00:00Z"
    assert s["last_captured_at"] == "2026-05-04T08:00:00Z"
    assert s["sources"] == [{"value": "phone", "count": 3}, {"value": "watch", "count": 1}]

    hours = by_key(s)["hours"]
    values = [6.0, 7.0, 8.0, 8.0]
    assert hours["type"] == "double"
    assert (hours["count"], hours["missing"]) == (4, 0)
    assert (hours["min"], hours["max"], hours["sum"]) == (6.0, 8.0, 29.0)
    assert hours["mean"] == pytest.approx(statistics.mean(values))
    assert hours["median"] == pytest.approx(statistics.median(values))
    assert hours["stddev"] == pytest.approx(statistics.stdev(values))
    hist = hours["histogram"]
    assert len(hist) == 10
    assert sum(b["count"] for b in hist) == hours["count"]
    assert hist[0] == {"lower": 6.0, "upper": pytest.approx(6.2), "count": 1}
    assert hist[5]["count"] == 1  # 7.0
    assert hist[-1]["count"] == 2  # max value lands in the last bin
    assert hist[-1]["upper"] == pytest.approx(8.0)

    wakeups = by_key(s)["wakeups"]
    assert wakeups["type"] == "int"
    # Small integer range: one bin per integer, centred on it.
    assert [(b["lower"], b["upper"], b["count"]) for b in wakeups["histogram"]] == [
        (-0.5, 0.5, 1),
        (0.5, 1.5, 2),
        (1.5, 2.5, 0),
        (2.5, 3.5, 1),
    ]


async def test_histogram_edge_cases(client: httpx.AsyncClient) -> None:
    qs = [
        {"key": "x", "label": "X", "type": "double"},
        {"key": "n", "label": "N", "type": "int"},
    ]
    await make_topic(client, "Edge", questions=qs)
    for x, n in [(2.5, 0), (2.5, 100), (2.5, 55)]:
        await record(client, "edge", {"x": x, "n": n})
    q = by_key((await client.get("/topics/edge/stats")).json())
    # All-equal doubles: a single non-degenerate range, everything in the first bin.
    hx = q["x"]["histogram"]
    assert sum(b["count"] for b in hx) == 3
    assert hx[0]["count"] == 3
    # Wide integer range: 10 equal-width bins.
    hn = q["n"]["histogram"]
    assert len(hn) == 10
    assert [b["count"] for b in hn] == [1, 0, 0, 0, 0, 1, 0, 0, 0, 1]
    assert math.isclose(hn[0]["upper"] - hn[0]["lower"], 10.0)


async def test_enum_and_str_stats(client: httpx.AsyncClient) -> None:
    entries = await seed(client)
    q = by_key(await stats(client))
    quality = q["quality"]
    assert (quality["count"], quality["missing"]) == (4, 0)
    assert quality["options"] == [
        {"value": "poor", "label": "Poor", "archived": False, "count": 1, "share": 0.25},
        {"value": "ok", "label": "OK", "archived": False, "count": 2, "share": 0.5},
        {"value": "great", "label": "Great", "archived": False, "count": 1, "share": 0.25},
    ]
    assert sum(o["share"] for o in quality["options"]) == pytest.approx(1.0)

    dream = q["dream"]
    assert (dream["count"], dream["missing"], dream["distinct"]) == (3, 1, 2)
    assert dream["top"] == [{"value": "falling", "count": 2}]  # singletons omitted
    assert [r["value"] for r in dream["recent"]] == ["flying", "falling", "falling"]
    assert dream["recent"][0]["entry_id"] == entries[2]["id"]
    assert dream["recent"][0]["captured_at"] == "2026-05-03T08:00:00Z"


async def test_removed_question_with_data_still_included(client: httpx.AsyncClient) -> None:
    await seed(client)
    qs = [q for q in sleep_questions() if q["key"] != "wakeups"]
    qs.append({"key": "nap", "label": "Nap", "type": "int", "required": False})
    r = await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    assert r.status_code == 201
    await record(client, "sleep-log", {"hours": 5, "quality": "ok", "nap": 1})

    s = await stats(client)
    # Current questions first (in order), then historic ones holding data.
    # 'unused' was removed and never answered, so it is omitted.
    assert [q["key"] for q in s["questions"]] == ["hours", "quality", "dream", "nap", "wakeups"]
    q = by_key(s)
    assert q["wakeups"]["count"] == 4
    assert q["wakeups"]["missing"] == 1
    assert q["nap"]["count"] == 1
    assert q["hours"]["count"] == 5


async def test_archived_option_counts(client: httpx.AsyncClient) -> None:
    await seed(client)
    qs = sleep_questions()
    qs[2]["options"][0]["archived"] = True
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    quality = by_key(await stats(client))["quality"]
    poor = quality["options"][0]
    assert (poor["value"], poor["archived"], poor["count"]) == ("poor", True, 1)


async def test_stats_filters(client: httpx.AsyncClient) -> None:
    await seed(client)
    s = await stats(client, captured_from="2026-05-02T00:00:00Z", captured_to="2026-05-04T00:00:00Z")
    assert s["entry_count"] == 2
    assert by_key(s)["hours"]["mean"] == 7.5
    assert by_key(s)["quality"]["options"][1]["share"] == 1.0

    s = await stats(client, source="watch")
    assert s["entry_count"] == 1
    assert s["sources"] == [{"value": "watch", "count": 1}]
    assert by_key(s)["hours"]["sum"] == 8.0

    s = await stats(client, version=2)
    assert s["entry_count"] == 0
    assert by_key(s)["hours"]["count"] == 0

    s = await stats(client, version=1, channel="api")
    assert s["entry_count"] == 4
    assert (await client.get("/topics/nope/stats")).status_code == 404


async def series(client: httpx.AsyncClient, key: str, **params: Any) -> dict[str, Any]:
    r = await client.get(f"/topics/sleep-log/questions/{key}/series", params=params)
    assert r.status_code == 200, r.text
    body: dict[str, Any] = r.json()
    return body


async def test_series_numeric_daily(client: httpx.AsyncClient) -> None:
    await seed(client)
    s = await series(client, "hours")
    assert (s["key"], s["type"], s["bucket"]) == ("hours", "double", "day")
    assert [(p["start"], p["count"], p["mean"]) for p in s["points"]] == [
        ("2026-05-01T00:00:00Z", 1, 6.0),
        ("2026-05-02T00:00:00Z", 1, 7.0),
        ("2026-05-03T00:00:00Z", 1, 8.0),
        ("2026-05-04T00:00:00Z", 1, 8.0),
    ]


async def test_series_week_month_and_enum(client: httpx.AsyncClient) -> None:
    await seed(client)
    week = await series(client, "wakeups", bucket="week")
    # 2026-05-01 is a Friday; ISO weeks start on Monday.
    assert [(p["start"], p["count"]) for p in week["points"]] == [
        ("2026-04-27T00:00:00Z", 3),
        ("2026-05-04T00:00:00Z", 1),
    ]
    assert week["points"][0]["min"] == 0.0
    assert week["points"][0]["max"] == 1.0
    assert week["points"][0]["mean"] == pytest.approx(2 / 3)

    month = await series(client, "quality", bucket="month")
    (point,) = month["points"]
    assert point["start"] == "2026-05-01T00:00:00Z"
    assert point["count"] == 4
    assert point["option_counts"] == {"poor": 1, "ok": 2, "great": 1}
    assert point["mean"] is None

    text = await series(client, "dream", bucket="month")
    assert text["points"][0]["count"] == 3
    assert text["points"][0]["option_counts"] == {}


async def test_series_timezone(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    for ts in ("2026-05-01T23:30:00Z", "2026-05-02T00:30:00Z"):
        await record(client, "sleep-log", {"hours": 7, "wakeups": 0, "quality": "ok"}, captured_at=ts)
    utc = await series(client, "hours")
    assert [p["start"] for p in utc["points"]] == ["2026-05-01T00:00:00Z", "2026-05-02T00:00:00Z"]
    ny = await series(client, "hours", tz="America/New_York")
    # Both are on May 1st in New York (UTC-4); bucket starts at local midnight.
    assert [(p["start"], p["count"]) for p in ny["points"]] == [("2026-05-01T04:00:00Z", 2)]
    tokyo = await series(client, "quality", tz="Asia/Tokyo")
    assert [(p["start"], p["count"]) for p in tokyo["points"]] == [("2026-05-01T15:00:00Z", 2)]


async def test_series_errors(client: httpx.AsyncClient) -> None:
    await seed(client)
    r = await client.get("/topics/sleep-log/questions/hours/series", params={"tz": "Mars/Olympus"})
    assert r.status_code == 400
    assert r.json()["code"] == "bad_request"
    assert "Mars/Olympus" in r.json()["detail"]
    r = await client.get("/topics/sleep-log/questions/hours/series", params={"tz": "../../etc/passwd"})
    assert r.status_code == 400
    r = await client.get("/topics/sleep-log/questions/nope/series")
    assert r.status_code == 404
    r = await client.get("/topics/sleep-log/questions/hours/series", params={"bucket": "year"})
    assert r.status_code == 422


async def test_series_filters_and_removed_question(client: httpx.AsyncClient) -> None:
    await seed(client)
    qs = [q for q in sleep_questions() if q["key"] != "wakeups"]
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    s = await series(client, "wakeups", source="phone")
    assert [p["count"] for p in s["points"]] == [1, 1, 1]


async def export(client: httpx.AsyncClient, **params: Any) -> list[list[str]]:
    r = await client.get("/topics/sleep-log/entries.csv", params=params)
    assert r.status_code == 200, r.text
    assert r.headers["content-type"].startswith("text/csv")
    assert r.headers["content-disposition"].startswith('attachment; filename="sleep-log-')
    return list(csv.reader(io.StringIO(r.text)))


async def test_csv_export(client: httpx.AsyncClient) -> None:
    entries = await seed(client)
    rows = await export(client)
    meta_cols = ["entry_id", "captured_at", "version", "source", "channel", "notes"]
    assert rows[0] == [*meta_cols, "hours", "wakeups", "quality", "dream", "unused"]
    assert len(rows) == 5
    assert rows[1] == [
        entries[0]["id"],
        "2026-05-01T08:00:00+00:00",
        "1",
        "phone",
        "api",
        "",
        "6.0",
        "0",
        "poor",
        "falling",
        "",
    ]
    assert rows[4][-2:] == ["", ""]  # unanswered -> empty cells

    # Historic columns: removed questions follow current ones.
    qs = [q for q in sleep_questions() if q["key"] != "wakeups"]
    qs.append({"key": "nap", "label": "Nap", "type": "int", "required": False})
    await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    await record(
        client,
        "sleep-log",
        {"hours": 5, "quality": "ok", "nap": 2},
        notes='said "hi", ok',
        captured_at="2026-06-01T00:00:00Z",
    )
    rows = await export(client)
    assert rows[0] == [*meta_cols, "hours", "quality", "dream", "nap", "wakeups", "unused"]
    assert rows[-1][2:] == ["2", "api", "api", 'said "hi", ok', "5.0", "ok", "", "2", "", ""]
    assert rows[1][-2:] == ["0", ""]


async def test_csv_export_filters_and_pages(client: httpx.AsyncClient) -> None:
    qs = [{"key": "n", "label": "N", "type": "int"}]
    await make_topic(client, "Sleep log", questions=qs)
    for i in range(520):  # more than one export page
        await record(client, "sleep-log", {"n": i}, captured_at=f"2026-01-01T00:{i // 60:02d}:{i % 60:02d}Z")
    rows = await export(client)
    assert len(rows) == 521
    assert [r[-1] for r in rows[1:]] == [str(i) for i in range(520)]
    rows = await export(client, captured_to="2026-01-01T00:00:10Z")
    assert len(rows) == 11
    assert (await client.get("/topics/nope/entries.csv")).status_code == 404
