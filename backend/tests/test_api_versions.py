"""Version check/publish over HTTP, and entries pinned to versions."""

from __future__ import annotations

from typing import Any

import httpx

from tests.helpers import make_topic, record, sleep_questions

ANSWERS = {"hours": 7.5, "wakeups": 1, "quality": "ok"}


def v2_questions() -> list[dict[str, Any]]:
    qs = sleep_questions()
    qs[0]["max"] = 16  # tighten
    qs = [q for q in qs if q["key"] != "wakeups"]  # remove
    qs.append(
        {"key": "nap", "label": "Napped?", "type": "enum", "options": [{"value": "yes", "label": "Yes"}]}
    )
    return qs


async def test_check_endpoint_reports_without_publishing(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post("/topics/sleep-log/versions/check", json={"questions": v2_questions()})
    assert r.status_code == 200
    report = r.json()
    assert report["ok"] is True
    assert report["next_version"] == 2
    kinds = {c["question_key"]: c["kind"] for c in report["changes"]}
    assert kinds == {"hours": "modified", "nap": "added", "wakeups": "removed"}
    levels = {(i["level"], i["question_key"]) for i in report["issues"]}
    assert ("warning", "hours") in levels
    assert ("warning", "wakeups") in levels
    assert ("info", "nap") in levels
    # Nothing was published.
    assert (await client.get("/topics/sleep-log")).json()["current_version"] == 1

    r = await client.post("/topics/sleep-log/versions/check", json={"questions": sleep_questions()})
    assert r.json()["ok"] is False

    bad = [*sleep_questions(), {"key": "hours", "label": "x", "type": "int"}]
    r = await client.post("/topics/sleep-log/versions/check", json={"questions": bad})
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {"loc": ["body", "questions", 4, "key"], "message": "duplicate question key 'hours'"}
    ]


async def test_publish_and_list_versions(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post(
        "/topics/sleep-log/versions",
        json={"questions": v2_questions(), "base_version": 1, "timer": None, "change_note": "drop wakeups"},
    )
    assert r.status_code == 201, r.text
    t = r.json()
    assert t["current_version"] == 2
    assert [q["key"] for q in t["questions"]] == ["hours", "quality", "dream", "nap"]

    versions = (await client.get("/topics/sleep-log/versions")).json()
    assert [v["version"] for v in versions] == [2, 1]
    assert versions[0]["change_note"] == "drop wakeups"
    assert versions[1]["change_note"] == "Initial version"
    assert [q["key"] for q in versions[1]["questions"]] == ["hours", "wakeups", "quality", "dream"]


async def test_publish_with_stale_base_version(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    body = {"questions": v2_questions(), "base_version": 1, "timer": None}
    assert (await client.post("/topics/sleep-log/versions", json=body)).status_code == 201
    r = await client.post("/topics/sleep-log/versions", json=body)
    assert r.status_code == 409
    assert r.json()["code"] == "conflict"
    assert "version 2" in r.json()["detail"]
    r = await client.post("/topics/sleep-log/versions", json={**body, "base_version": 5, "timer": None})
    assert r.status_code == 409


async def test_incompatible_publish_is_problem(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    qs = sleep_questions()
    qs[1]["type"] = "double"  # type change
    qs[2]["options"] = qs[2]["options"][:2]  # option removal
    r = await client.post(
        "/topics/sleep-log/versions", json={"questions": qs, "base_version": 1, "timer": None}
    )
    assert r.status_code == 422
    body = r.json()
    assert body["code"] == "incompatible_version"
    assert "wakeups: type cannot change (int -> double)" in body["detail"]
    assert "quality: option 'great' cannot be removed" in body["detail"]
    assert (await client.get("/topics/sleep-log")).json()["current_version"] == 1

    r = await client.post(
        "/topics/sleep-log/versions", json={"questions": sleep_questions(), "base_version": 1, "timer": None}
    )
    assert r.status_code == 422
    assert r.json()["detail"] == "no changes to publish"


async def test_entries_pinned_to_versions(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s1 = await record(client, "sleep-log", ANSWERS)
    assert s1["version"] == 1
    await client.post(
        "/topics/sleep-log/versions", json={"questions": v2_questions(), "base_version": 1, "timer": None}
    )

    # New entries default to the current version and use its rules.
    r = await client.post("/topics/sleep-log/entries", json={"answers": ANSWERS})
    assert r.status_code == 422
    errors = {tuple(e["loc"]): e["message"] for e in r.json()["errors"]}
    assert errors[("answers", "wakeups")] == "unknown question"
    assert errors[("answers", "nap")] == "required"

    s2 = await record(client, "sleep-log", {"hours": 8, "quality": "great", "nap": "yes"})
    assert s2["version"] == 2

    # Recording against an older version uses that version's config.
    s3 = await record(client, "sleep-log", {**ANSWERS, "hours": 20}, version=1)
    assert s3["version"] == 1
    r = await client.post(
        "/topics/sleep-log/entries", json={"answers": {**ANSWERS, "hours": 20}, "version": 2}
    )
    assert r.status_code == 422
    r = await client.post("/topics/sleep-log/entries", json={"answers": ANSWERS, "version": 9})
    assert r.status_code == 404

    # The old entry keeps its version and answers.
    old = (await client.get(f"/entries/{s1['id']}")).json()
    assert old["version"] == 1
    assert {a["key"] for a in old["answers"]} == {"hours", "wakeups", "quality"}

    # Editing an old entry validates against its own version.
    r = await client.patch(f"/entries/{s1['id']}", json={"answers": {"wakeups": 3}})
    assert r.status_code == 200, r.text
    assert r.json()["version"] == 1

    versions = (await client.get("/topics/sleep-log/versions")).json()
    assert {v["version"]: v["entry_count"] for v in versions} == {2: 1, 1: 2}

    by_version = (await client.get("/topics/sleep-log/entries", params={"version": 1})).json()
    assert by_version["total"] == 2


async def test_restore_removed_question(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await client.post(
        "/topics/sleep-log/versions", json={"questions": v2_questions(), "base_version": 1, "timer": None}
    )
    qs = [*v2_questions(), sleep_questions()[1]]
    r = await client.post("/topics/sleep-log/versions/check", json={"questions": qs})
    assert {c["question_key"]: c["kind"] for c in r.json()["changes"]} == {"wakeups": "restored"}
    r = await client.post(
        "/topics/sleep-log/versions", json={"questions": qs, "base_version": 2, "timer": None}
    )
    assert r.status_code == 201
    assert r.json()["current_version"] == 3


async def test_check_with_stale_base_version_conflicts(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    body = {"questions": v2_questions(), "base_version": 1}
    r = await client.post("/topics/sleep-log/versions/check", json=body)
    assert r.status_code == 200
    assert r.json()["ok"] is True
    assert (await client.post("/topics/sleep-log/versions", json={**body, "timer": None})).status_code == 201
    r = await client.post("/topics/sleep-log/versions/check", json=body)
    assert r.status_code == 409
    assert r.json()["errors"] == [{"loc": ["base_version"], "message": "current version is 2"}]


# ---------------------------------------------------------------------------
# Timed topics: versions carry a timer (docs/specs/timers.md §2.1)
# ---------------------------------------------------------------------------

STEPS = {"steps": [{"key": "load", "label": "Load"}, {"key": "rinse", "label": "Rinse"}]}


async def _timers(client: httpx.AsyncClient, ref: str = "sleep-log") -> list[Any]:
    """Each version's timer, oldest first."""
    versions = (await client.get(f"/topics/{ref}/versions")).json()
    return [v["timer"] for v in reversed(versions)]


async def test_create_topic_timer_is_optional(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await make_topic(client, "Dishwasher", timer=STEPS)
    await make_topic(client, "Stopwatch", timer={"steps": []})
    assert await _timers(client) == [None]
    assert await _timers(client, "dishwasher") == [STEPS]
    assert await _timers(client, "stopwatch") == [{"steps": []}]


async def test_publish_requires_timer(client: httpx.AsyncClient) -> None:
    """T11: leaving `timer` out is a 422, so no caller can switch timing off by omission;
    null turns it off."""
    await make_topic(client, timer=STEPS)
    r = await client.post("/topics/sleep-log/versions", json={"questions": v2_questions(), "base_version": 1})
    assert r.status_code == 422
    assert r.json()["errors"] == [{"loc": ["body", "timer"], "message": "Field required"}]
    assert await _timers(client) == [STEPS]

    renamed = {"steps": [{"key": "rinse", "label": "Rinse first"}, {"key": "load", "label": "Load"}]}
    body = {"questions": v2_questions(), "base_version": 1, "timer": renamed}
    assert (await client.post("/topics/sleep-log/versions", json=body)).status_code == 201
    body = {"questions": sleep_questions(), "base_version": 2, "timer": None}
    r = await client.post("/topics/sleep-log/versions", json=body)
    assert r.status_code == 201, r.text
    assert await _timers(client) == [STEPS, renamed, None]


async def test_timer_change_alone_publishes(client: httpx.AsyncClient) -> None:
    """The compatibility check ignores the timer, but turning timing on or off with the same
    questions is still a change; the same timer and questions is not."""
    await make_topic(client)
    same = {"questions": sleep_questions(), "base_version": 1, "timer": None}
    r = await client.post("/topics/sleep-log/versions", json=same)
    assert (r.status_code, r.json()["detail"]) == (422, "no changes to publish")

    r = await client.post("/topics/sleep-log/versions", json={**same, "timer": STEPS})
    assert r.status_code == 201, r.text
    r = await client.post("/topics/sleep-log/versions", json={**same, "base_version": 2, "timer": STEPS})
    assert (r.status_code, r.json()["detail"]) == (422, "no changes to publish")
    r = await client.post("/topics/sleep-log/versions", json={**same, "base_version": 2, "timer": None})
    assert r.status_code == 201, r.text
    assert await _timers(client) == [None, STEPS, None]

    # A blocking question error still blocks, whatever the timer does.
    retyped = sleep_questions()
    retyped[1]["type"] = "double"
    body = {"questions": retyped, "base_version": 3, "timer": STEPS}
    r = await client.post("/topics/sleep-log/versions", json=body)
    assert r.status_code == 422
    assert "wakeups: type cannot change" in r.json()["detail"]


def _steps(n: int) -> list[dict[str, str]]:
    return [{"key": f"s{i}", "label": f"Step {i}"} for i in range(n)]


async def test_step_validation_names_the_field(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    base = {"questions": v2_questions(), "base_version": 1}
    cases: list[tuple[Any, list[Any]]] = [
        ({"steps": [*_steps(2), {"key": "s0", "label": "Again"}]}, ["timer", "steps", 2, "key"]),
        ({"steps": [{"key": "Load", "label": "Load"}]}, ["timer", "steps", 0, "key"]),
        ({"steps": [{"key": "x" * 64, "label": "Long"}]}, ["timer", "steps", 0, "key"]),
        ({"steps": [{"key": "load", "label": ""}]}, ["timer", "steps", 0, "label"]),
        ({"steps": [{"key": "load", "label": "  "}]}, ["timer", "steps", 0, "label"]),
        ({"steps": [{"key": "load", "label": "x" * 201}]}, ["timer", "steps", 0, "label"]),
        ({"steps": [{"key": "load", "label": "Load", "extra": 1}]}, ["timer", "steps", 0, "extra"]),
        ({"steps": _steps(31)}, ["timer", "steps"]),
        ({}, ["timer", "steps"]),
        ({"steps": [], "laps": True}, ["timer", "laps"]),
    ]
    for timer, loc in cases:
        r = await client.post("/topics/sleep-log/versions", json={**base, "timer": timer})
        assert r.status_code == 422, timer
        assert [e["loc"] for e in r.json()["errors"]] == [["body", *loc]], timer
    r = await client.post("/topics", json={"name": "Dup", "questions": [], "timer": {"steps": _steps(31)}})
    assert [e["loc"] for e in r.json()["errors"]] == [["body", "timer", "steps"]]

    # Limits: 30 steps; a step may share a question's key; a label at 200 characters.
    timer = {"steps": [*_steps(29), {"key": "hours", "label": "x" * 200}]}
    r = await client.post("/topics/sleep-log/versions", json={**base, "timer": timer})
    assert r.status_code == 201, r.text
    assert await _timers(client) == [None, timer]


async def test_check_with_a_timer_counts_a_timer_change(client: httpx.AsyncClient) -> None:
    """checkTopicVersion's optional timer: a timer change alone passes, as publishing it does;
    without a timer the check compares questions only."""
    await make_topic(client)
    same = {"questions": sleep_questions(), "base_version": 1}
    check = "/topics/sleep-log/versions/check"
    r = await client.post(check, json=same)
    assert r.json()["ok"] is False
    r = await client.post(check, json={**same, "timer": None})
    assert (r.json()["ok"], r.json()["issues"][0]["message"]) == (False, "no changes to publish")
    r = await client.post(check, json={**same, "timer": STEPS})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "next_version": 2, "issues": [], "changes": []}

    # Timed now: the same timer is no change again; dropping it is one.
    assert (await client.post("/topics/sleep-log/versions", json={**same, "timer": STEPS})).status_code == 201
    same["base_version"] = 2
    assert (await client.post(check, json={**same, "timer": STEPS})).json()["ok"] is False
    assert (await client.post(check, json={**same, "timer": None})).json()["ok"] is True
    # Question errors still block, whatever the timer.
    retyped = sleep_questions()
    retyped[1]["type"] = "double"
    r = await client.post(check, json={"questions": retyped, "timer": None})
    assert r.json()["ok"] is False
    r = await client.post(check, json={**same, "timer": {"steps": [{"key": "Bad", "label": "x"}]}})
    assert [e["loc"] for e in r.json()["errors"]] == [["body", "timer", "steps", 0, "key"]]
