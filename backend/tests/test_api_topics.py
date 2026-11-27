"""Topic CRUD, search, listing and archive lifecycle over HTTP."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy import event

from app.db import get_engine
from app.services.appearance import COLOR_NAMES
from tests.helpers import make_topic, normal_timer, record, sleep_questions


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


async def test_summary_and_detail_carry_the_current_versions_timer(client: httpx.AsyncClient) -> None:
    """``timer`` on TopicSummary and TopicDetail is the current version's (timers.md §2.1)."""
    steps = {"steps": [{"key": "pour", "label": "Pour"}, {"key": "drink", "label": "Drink"}]}
    timed = await make_topic(client, "Coffee", timer=steps)
    plain = await make_topic(client, "Plain")
    steps = normal_timer(steps)
    assert timed["timer"] == steps
    assert plain["timer"] is None

    def timers(page: dict[str, Any]) -> dict[str, Any]:
        return {t["slug"]: t["timer"] for t in page["items"]}

    assert timers((await client.get("/topics")).json()) == {"coffee": steps, "plain": None}
    assert (await client.patch("/topics/coffee", json={"description": "x"})).json()["timer"] == steps
    assert (await client.post("/topics/coffee/archive")).json()["timer"] == steps
    assert (
        timers((await client.get("/topics", params={"status": "all", "sort": "name"})).json())["coffee"]
        == steps
    )
    assert (await client.post("/topics/coffee/unarchive")).json()["timer"] == steps

    # A version without a timer makes the topic untimed; the next one with a timer, timed again.
    body = {"questions": timed["questions"], "base_version": 1, "timer": None}
    published = (await client.post("/topics/coffee/versions", json=body)).json()
    assert published["current_version"] == 2
    assert published["timer"] is None
    assert (await client.get("/topics/coffee")).json()["timer"] is None
    one_step = {"steps": [{"key": "brew", "label": "Brew"}]}
    body = {"questions": timed["questions"], "base_version": 2, "timer": one_step}
    one_step = normal_timer(one_step)
    assert (await client.post("/topics/coffee/versions", json=body)).json()["timer"] == one_step
    assert timers((await client.get("/topics")).json()) == {"coffee": one_step, "plain": None}


async def test_list_topics_loads_timers_without_a_query_per_topic(client: httpx.AsyncClient) -> None:
    steps = {"steps": [{"key": "go", "label": "Go"}]}
    for i in range(4):
        await make_topic(client, f"Timed {i}", timer=steps)
    statements: list[str] = []
    engine = get_engine().sync_engine

    def count(conn: Any, cursor: Any, statement: str, *_: Any) -> None:
        if "topic_versions" in statement:
            statements.append(statement)

    event.listen(engine, "before_cursor_execute", count)
    try:
        page = (await client.get("/topics", params={"sort": "name"})).json()
    finally:
        event.remove(engine, "before_cursor_execute", count)
    assert [t["timer"] for t in page["items"]] == [normal_timer(steps)] * 4
    assert len(statements) == 1  # the page's one joined select


# --- T2-M4: TopicSummary.last_entry (content-display.md §2) -----------------------------

SLEEP = {"hours": 7.5, "wakeups": 1, "quality": "ok"}
LOW_ID = "00000000-0000-4000-8000-000000000001"
HIGH_ID = "00000000-0000-4000-8000-000000000002"


async def test_last_entry_is_the_latest_counted_entry(client: httpx.AsyncClient) -> None:
    t = await make_topic(client)
    assert t["last_entry"] is None
    assert (await client.get("/topics/sleep-log")).json()["last_entry"] is None
    assert (await client.get("/topics")).json()["items"][0]["last_entry"] is None
    before_entries = (await client.get("/changes", params={"after": 0})).json()["head"]

    e1 = await record(client, "sleep-log", SLEEP, captured_at="2026-03-01T08:00:00Z")
    # Latest by captured_at, then by id (descending): insertion order does not count.
    high = await record(client, "sleep-log", SLEEP, id=HIGH_ID, captured_at="2026-03-02T08:00:00Z")
    low = await record(client, "sleep-log", SLEEP, id=LOW_ID, captured_at="2026-03-02T08:00:00Z")
    await record(client, "sleep-log", {**SLEEP, "dream": "earlier"}, captured_at="2026-02-01T08:00:00Z")
    assert (await client.get("/topics/sleep-log")).json()["last_entry"] == high
    assert (await client.get("/topics")).json()["items"][0]["last_entry"] == high
    assert high["answers"]  # the whole EntryOut, answers included
    # Creating entries does not re-send the topic either.
    created = (await client.get("/changes", params={"after": before_entries})).json()
    assert [i["kind"] for i in created["items"]] == ["entry"] * 4

    # The feed's topic item carries it too.
    feed = (await client.get("/changes", params={"after": 0})).json()
    topic_items = [i for i in feed["items"] if i["kind"] == "topic"]
    assert [i["topic"]["last_entry"] for i in topic_items] == [high]

    # It follows updates and deletes, back to null...
    r = await client.patch(f"/entries/{HIGH_ID}", json={"notes": "edited"})
    assert r.status_code == 200, r.text
    assert (await client.get("/topics/sleep-log")).json()["last_entry"] == r.json()
    assert (await client.delete(f"/entries/{HIGH_ID}")).status_code == 204
    assert (await client.get("/topics/sleep-log")).json()["last_entry"] == low
    assert (await client.delete(f"/entries/{LOW_ID}")).status_code == 204
    assert (await client.get("/topics")).json()["items"][0]["last_entry"] == e1
    for entry in (await client.get("/topics/sleep-log/entries")).json()["items"]:
        assert (await client.delete(f"/entries/{entry['id']}")).status_code == 204
    assert (await client.get("/topics/sleep-log")).json()["last_entry"] is None
    # ...but, like entry_count, it is derived: none of that re-sent the topic through the feed.
    tail = (await client.get("/changes", params={"after": feed["head"]})).json()
    assert tail["items"] == []  # the edited entry was deleted later on the page: latest seq wins
    assert sorted(d["kind"] for d in tail["deleted"]) == ["entry"] * 4


async def test_list_topics_loads_last_entries_without_a_query_per_topic(client: httpx.AsyncClient) -> None:
    engine = get_engine().sync_engine

    async def page_statements() -> tuple[list[dict[str, Any]], list[str]]:
        statements: list[str] = []

        def count(conn: Any, cursor: Any, statement: str, *_: Any) -> None:
            statements.append(statement)

        event.listen(engine, "before_cursor_execute", count)
        try:
            page = (await client.get("/topics")).json()
        finally:
            event.remove(engine, "before_cursor_execute", count)
        items: list[dict[str, Any]] = page["items"]
        return items, statements

    await make_topic(client, "Topic 0")
    await record(client, "topic-0", SLEEP)
    one_topic, for_one = await page_statements()
    for i in range(1, 5):
        await make_topic(client, f"Topic {i}")
        await record(client, f"topic-{i}", SLEEP, notes=f"entry {i}")
    five_topics, for_five = await page_statements()

    assert [len(t["last_entry"]["answers"]) for t in one_topic] == [3]
    notes = ["", "entry 1", "entry 2", "entry 3", "entry 4"]
    assert sorted(t["last_entry"]["notes"] for t in five_topics) == notes
    # One joined select for the page, then one answers load for all of its entries, whatever the page size.
    assert len(for_five) == len(for_one)
    assert sum("FROM answers" in s for s in for_five) == 1


# end T2-M4


# T2-M3: topic appearance (docs/specs/appearance.md §1, §5, §8, §16)

EMPTY_APPEARANCE: dict[str, Any] = {"color": None, "icon": None, "tags": []}
THEMED: dict[str, Any] = {
    "color": "teal",
    "icon": {"kind": "emoji", "value": "💧"},
    "tags": ["Health", "daily"],
}


async def test_appearance_defaults_and_create(client: httpx.AsyncClient) -> None:
    plain = await make_topic(client, "Plain")
    assert plain["appearance"] == EMPTY_APPEARANCE
    explicit_null = await make_topic(client, "Null", appearance=None)
    assert explicit_null["appearance"] == EMPTY_APPEARANCE
    themed = await make_topic(client, "Water", appearance=THEMED)
    assert themed["appearance"] == THEMED
    # Stored forms: VS16 added after a text-presentation pictograph, tags trimmed and collapsed.
    t = await make_topic(
        client,
        "Smile",
        appearance={"icon": {"kind": "emoji", "value": "☺"}, "tags": ["  early   morning "]},
    )
    assert t["appearance"] == {
        "color": None,
        "icon": {"kind": "emoji", "value": "☺️"},
        "tags": ["early morning"],
    }
    # Every read carries it: detail, list, and the feed's topic item.
    assert (await client.get("/topics/water")).json()["appearance"] == THEMED
    listed = (await client.get("/topics", params={"sort": "name"})).json()["items"]
    assert {i["slug"]: i["appearance"] for i in listed}["water"] == THEMED


async def test_appearance_patch_semantics(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Water", appearance=THEMED)

    async def patch(body: dict[str, Any]) -> dict[str, Any]:
        r = await client.patch("/topics/water", json=body)
        assert r.status_code == 200, r.text
        out: dict[str, Any] = r.json()["appearance"]
        return out

    # An omitted field is unchanged; {} changes nothing.
    assert await patch({"appearance": {}}) == THEMED
    assert await patch({"name": "Water"}) == THEMED
    assert await patch({"appearance": {"color": "pink"}}) == {**THEMED, "color": "pink"}
    # null clears colour and icon; [] clears the tags.
    assert await patch({"appearance": {"color": None}}) == {**THEMED, "color": None}
    assert await patch({"appearance": {"icon": None}}) == {**THEMED, "color": None, "icon": None}
    assert await patch({"appearance": {"tags": []}}) == EMPTY_APPEARANCE
    assert await patch({"appearance": {"tags": ["b", "a"]}}) == {**EMPTY_APPEARANCE, "tags": ["b", "a"]}


@pytest.mark.parametrize(
    ("appearance", "loc", "message"),
    [
        (None, ["body", "appearance"], "clear fields individually (color: null, icon: null, tags: [])"),
        ({"tags": None}, ["body", "appearance", "tags"], "send [] to clear the tags"),
        ({"color": "mauve"}, ["body", "appearance", "color"], None),
        ({"icon": {"kind": "emoji", "value": "abc"}}, ["body", "appearance", "icon", "value"], None),
        ({"icon": {"kind": "emoji", "value": "5️"}}, ["body", "appearance", "icon", "value"], None),
        ({"icon": {"kind": "symbol", "value": "💧"}}, ["body", "appearance", "icon", "kind"], None),
        ({"tags": ["a", "b", "c", "  "]}, ["body", "appearance", "tags", 3], "must not be empty"),
        ({"tags": ["Gym", "gym"]}, ["body", "appearance", "tags", 1], None),
        ({"tags": ["x" * 25]}, ["body", "appearance", "tags", 0], "at most 24 characters"),
        ({"tags": [f"t{i}" for i in range(11)]}, ["body", "appearance", "tags"], "at most 10 tags"),
        ({"shape": "round"}, ["body", "appearance", "shape"], None),
    ],
)
async def test_appearance_errors_have_dotted_paths(
    client: httpx.AsyncClient, appearance: Any, loc: list[str | int], message: str | None
) -> None:
    await make_topic(client, "Water")
    r = await client.patch("/topics/water", json={"appearance": appearance})
    assert r.status_code == 422, r.text
    body = r.json()
    assert body["code"] == "invalid_request"
    assert [e["loc"] for e in body["errors"]] == [loc]
    if message is not None:
        assert body["errors"][0]["message"] == message
    # Create validates the same way (at the same path), except that null is allowed there.
    if appearance is not None and "tags" in appearance and appearance["tags"] is not None:
        r = await client.post("/topics", json={"name": "New", "questions": [], "appearance": appearance})
        assert r.status_code == 422
        assert [e["loc"] for e in r.json()["errors"]] == [loc]


async def test_appearance_patch_bumps_revision_and_resends_the_topic(client: httpx.AsyncClient) -> None:
    t = await make_topic(client, "Water")
    head = (await client.get("/changes", params={"limit": 500})).json()["head"]
    r = await client.patch("/topics/water", json={"appearance": {"color": "blue"}})
    assert r.status_code == 200
    assert r.json()["revision"] == t["revision"] + 1
    page = (await client.get("/changes", params={"after": head})).json()
    assert [(i["kind"], i["topic"]["id"]) for i in page["items"]] == [("topic", t["id"])]
    assert page["items"][0]["topic"]["appearance"] == {**EMPTY_APPEARANCE, "color": "blue"}
    assert page["items"][0]["topic"]["revision"] == t["revision"] + 1
    # expected_revision guards an appearance change like any other.
    stale = await client.patch("/topics/water", json={"appearance": {"tags": ["x"]}, "expected_revision": 1})
    assert stale.status_code == 409
    assert stale.json()["code"] == "stale_revision"


async def test_list_topics_tag_filter_matches_the_stored_spelling(client: httpx.AsyncClient) -> None:
    await make_topic(client, "Water", appearance={"tags": ["Health", "daily"]})
    await make_topic(client, "Gym", appearance={"tags": ["health"]})
    await make_topic(client, "Plain")
    archived = await make_topic(client, "Old", appearance={"tags": ["Health"]})
    await client.post(f"/topics/{archived['id']}/archive")

    async def slugs(**params: Any) -> list[str]:
        r = await client.get("/topics", params={"sort": "name", **params})
        assert r.status_code == 200, r.text
        assert r.json()["total"] == len(r.json()["items"])
        return [i["slug"] for i in r.json()["items"]]

    assert await slugs(tag="Health") == ["water"]
    assert await slugs(tag="health") == ["gym"]
    assert await slugs(tag="Health", status="all") == ["old", "water"]
    assert await slugs(tag="daily", sort="due") == ["water"]
    assert await slugs(tag="Heal") == []
    assert await slugs(tag="") == []
    assert (await client.get("/topics", params={"tag": "x" * 25})).status_code == 422


async def test_limits_carry_the_appearance_rows(client: httpx.AsyncClient) -> None:
    limits = (await client.get("/limits")).json()
    assert limits["max_tags"] == 10
    assert limits["max_tag_length"] == 24
    assert limits["max_icon_length"] == 16
    assert limits["color_names"] == list(COLOR_NAMES)
    assert len(COLOR_NAMES) == 12


# end T2-M3
