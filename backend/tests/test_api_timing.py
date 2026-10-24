"""``getTopicTiming`` over HTTP (docs/specs/timers.md §9.2).

Each timing-stats vector is seeded as a topic (its versions, with each version's steps) and
entries with the vector's ``timing``; the endpoint must answer the vector's ``expected``.
"""

from __future__ import annotations

import copy
import json
from typing import Any
from uuid import UUID

import httpx
import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Channel, Entry, Topic, TopicVersion
from app.services import run_fold
from app.services.timing_stats import timing_stats
from tests.helpers import make_topic, record
from tests.test_timing_stats_vectors import stats_json, to_entry
from tests.vectors import FIXTURES_DIR

VECTORS = json.loads((FIXTURES_DIR / "timing-stats-vectors.json").read_text())["cases"]
CASES = {c["name"]: c for c in VECTORS}
SLUG = "routine"


async def seed(db: AsyncSession, case: dict[str, Any], versions_of: dict[int, int] | None = None) -> None:
    """The case's topic and entries; entry ``i`` (0-based) is recorded against version
    ``versions_of[i]``, by default the current one."""
    topic = Topic(slug=SLUG, name="Routine", current_version=case["current_version"])
    db.add(topic)
    rows: dict[int, TopicVersion] = {}
    for number, steps in case["versions"].items():
        rows[int(number)] = TopicVersion(
            topic=topic, version=int(number), questions=[], timer=None if steps is None else {"steps": steps}
        )
        db.add(rows[int(number)])
    await db.flush()
    for i, e in enumerate(case["entries"]):
        version = rows[(versions_of or {}).get(i, case["current_version"])]
        db.add(
            Entry(
                id=UUID(e["entry_id"]),
                topic_id=topic.id,
                topic_version_id=version.id,
                version=version.version,
                source="test",
                channel=Channel.api,
                captured_at=run_fold.from_ms(run_fold.parse_instant(e["captured_at"])),
                timing=e["timing"],
            )
        )
    await db.commit()


async def timing(client: httpx.AsyncClient, ref: str = SLUG, **params: Any) -> dict[str, Any]:
    r = await client.get(f"/topics/{ref}/timing", params=params)
    assert r.status_code == 200, r.text
    body: dict[str, Any] = r.json()
    return body


def expected(case: dict[str, Any], indices: list[int]) -> dict[str, Any]:
    """The reference stats over a subset of the case's entries, with every version."""
    versions = {
        int(n): None if s is None else [run_fold.Step(x["key"], x["label"]) for x in s]
        for n, s in case["versions"].items()
    }
    entries = [to_entry(case["entries"][i]) for i in indices]
    return stats_json(timing_stats(entries, versions, case["current_version"]))


@pytest.mark.parametrize("name", list(CASES))
async def test_endpoint_matches_the_vectors(name: str, db: AsyncSession, client: httpx.AsyncClient) -> None:
    await seed(db, CASES[name])
    assert await timing(client) == CASES[name]["expected"]


async def test_from_and_to_filter_on_captured_at(db: AsyncSession, client: httpx.AsyncClient) -> None:
    case = CASES["skipped-steps"]
    await seed(db, case)
    at = [e["captured_at"] for e in case["entries"]]
    # captured_from is inclusive, captured_to exclusive: entries 1 and 2 of 0 to 3.
    body = await timing(client, captured_from=at[1], captured_to=at[3])
    assert body == expected(case, [1, 2])
    assert [p["entry_id"] for p in body["series"]] == [case["entries"][i]["entry_id"] for i in (1, 2)]
    assert await timing(client, captured_from=at[3]) == expected(case, [3])


async def test_version_filter_keeps_the_latest_labels(db: AsyncSession, client: httpx.AsyncClient) -> None:
    case = CASES["renamed-and-removed-steps"]
    await seed(db, case, versions_of={0: 1, 1: 2, 2: 3, 3: 3})
    body = await timing(client, version=1)
    assert body == expected(case, [0])
    assert [(s["key"], s["label"], s["current"]) for s in body["steps"]] == [
        ("shower", "Wash", True),
        ("brekkie", "Breakfast", True),
        ("teeth", "Teeth", False),
    ]


async def test_a_removed_step_keeps_its_last_versions_label(
    db: AsyncSession, client: httpx.AsyncClient
) -> None:
    """Labels come from every version, not only the current one or those in range: 'teeth' is
    renamed in v2 and removed in v3, and its only run was on v1."""
    case = copy.deepcopy(CASES["renamed-and-removed-steps"])
    case["versions"]["2"].append({"key": "teeth", "label": "Brush teeth"})
    await seed(db, case, versions_of={0: 1, 1: 2, 2: 3, 3: 3})
    body = await timing(client)
    assert body == expected(case, [0, 1, 2, 3])
    assert {s["key"]: s["label"] for s in body["steps"]}["teeth"] == "Brush teeth"
    assert await timing(client, version=1) == expected(case, [0])


async def test_untimed_topic_answers_zero_counts(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await record(client, "sleep-log", {"hours": 7, "wakeups": 0, "quality": "ok"})
    assert await timing(client, "sleep-log") == CASES["empty"]["expected"]


async def test_unknown_topic_is_not_found(client: httpx.AsyncClient) -> None:
    r = await client.get("/topics/nope/timing")
    assert r.status_code == 404
    assert r.json()["code"] == "not_found"
