"""Single topics: a topic with zero questions. Logging one records an entry with no answers.

There is no special type or field: every path that takes a topic's questions works with none.
"""

from __future__ import annotations

import csv
import io
from typing import Any

import httpx

from app.services.notification import descriptor
from tests.helpers import make_topic, record


async def single(client: httpx.AsyncClient, name: str = "Took vitamins") -> dict[str, Any]:
    # Not make_topic: it substitutes its default questions for an empty list.
    r = await client.post("/topics", json={"name": name, "questions": []})
    assert r.status_code == 201, r.text
    body: dict[str, Any] = r.json()
    return body


async def test_a_topic_can_have_no_questions(client: httpx.AsyncClient) -> None:
    t = await single(client)
    assert (t["slug"], t["current_version"], t["question_count"], t["questions"]) == (
        "took-vitamins",
        1,
        0,
        [],
    )
    assert (await client.get("/topics/took-vitamins")).json()["questions"] == []


async def test_logging_a_single_topic_stores_an_entry_with_no_answers(client: httpx.AsyncClient) -> None:
    await single(client)
    entry = await record(client, "took-vitamins", {})
    assert entry["answers"] == []
    assert entry["version"] == 1
    page = (await client.get("/topics/took-vitamins/entries")).json()
    assert [e["id"] for e in page["items"]] == [entry["id"]]
    topic = (await client.get("/topics/took-vitamins")).json()
    assert topic["entry_count"] == 1
    assert topic["last_captured_at"] is not None

    # An answer to a question the topic doesn't have is refused, as for any topic.
    r = await client.post("/topics/took-vitamins/entries", json={"answers": {"x": 1}})
    assert r.status_code == 422
    assert r.json()["errors"][0]["loc"] == ["answers", "x"]

    # Editing it keeps it answerless (notes only).
    r = await client.patch(f"/entries/{entry['id']}", json={"answers": {}, "notes": "with food"})
    assert r.status_code == 200, r.text
    assert (r.json()["answers"], r.json()["notes"]) == ([], "with food")


async def test_versions_can_go_to_and_from_no_questions(client: httpx.AsyncClient) -> None:
    await make_topic(client)  # Sleep log, 4 questions
    await record(client, "sleep-log", {"hours": 7.0, "wakeups": 1, "quality": "ok"})
    r = await client.post("/topics/sleep-log/versions", json={"questions": [], "base_version": 1})
    assert r.status_code == 201, r.text
    assert r.json()["current_version"] == 2
    assert r.json()["questions"] == []
    entry = await record(client, "sleep-log", {})
    assert (entry["version"], entry["answers"]) == (2, [])

    await single(client)
    qs = [{"key": "dose", "label": "Dose", "type": "int", "required": False}]
    check = await client.post("/topics/took-vitamins/versions/check", json={"questions": qs})
    assert check.status_code == 200, check.text
    assert check.json()["ok"] is True
    r = await client.post("/topics/took-vitamins/versions", json={"questions": qs, "base_version": 1})
    assert r.status_code == 201, r.text
    assert [q["key"] for q in r.json()["questions"]] == ["dose"]


async def test_stats_of_a_single_topic_are_counts_and_recency(client: httpx.AsyncClient) -> None:
    await single(client)
    await record(client, "took-vitamins", {}, captured_at="2026-01-01T08:00:00Z")
    await record(client, "took-vitamins", {}, captured_at="2026-01-02T08:00:00Z")
    r = await client.get("/topics/took-vitamins/stats")
    assert r.status_code == 200, r.text
    s = r.json()
    assert s["entry_count"] == 2
    assert s["first_captured_at"].startswith("2026-01-01")
    assert s["last_captured_at"].startswith("2026-01-02")
    assert s["questions"] == []


async def test_csv_of_a_single_topic_has_no_answer_columns(client: httpx.AsyncClient) -> None:
    await single(client)
    entry = await record(client, "took-vitamins", {}, notes="morning")
    r = await client.get("/topics/took-vitamins/entries.csv")
    assert r.status_code == 200, r.text
    rows = list(csv.DictReader(io.StringIO(r.text)))
    assert list(rows[0]) == ["entry_id", "captured_at", "version", "source", "channel", "notes"]
    assert (rows[0]["entry_id"], rows[0]["notes"]) == (entry["id"], "morning")


def test_a_single_topic_has_no_quick_log_descriptor() -> None:
    # Its reminder carries no question to answer (the APNs and Web Push quick_log stay null).
    assert descriptor([], counts={}, last=None) is None
