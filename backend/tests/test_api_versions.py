"""Version check/publish over HTTP, and sessions pinned to versions."""

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
    assert r.status_code == 400


async def test_publish_and_list_versions(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    r = await client.post(
        "/topics/sleep-log/versions",
        json={"questions": v2_questions(), "base_version": 1, "change_note": "drop wakeups"},
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
    body = {"questions": v2_questions(), "base_version": 1}
    assert (await client.post("/topics/sleep-log/versions", json=body)).status_code == 201
    r = await client.post("/topics/sleep-log/versions", json=body)
    assert r.status_code == 409
    assert r.json()["code"] == "conflict"
    assert "version 2" in r.json()["detail"]
    r = await client.post("/topics/sleep-log/versions", json={**body, "base_version": 5})
    assert r.status_code == 409


async def test_incompatible_publish_is_problem(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    qs = sleep_questions()
    qs[1]["type"] = "double"  # type change
    qs[2]["options"] = qs[2]["options"][:2]  # option removal
    r = await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 1})
    assert r.status_code == 422
    body = r.json()
    assert body["code"] == "incompatible_version"
    assert "wakeups: type cannot change (int -> double)" in body["detail"]
    assert "quality: option 'great' cannot be removed" in body["detail"]
    assert (await client.get("/topics/sleep-log")).json()["current_version"] == 1

    r = await client.post(
        "/topics/sleep-log/versions", json={"questions": sleep_questions(), "base_version": 1}
    )
    assert r.status_code == 422
    assert r.json()["detail"] == "no changes to publish"


async def test_sessions_pinned_to_versions(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    s1 = await record(client, "sleep-log", ANSWERS)
    assert s1["version"] == 1
    await client.post("/topics/sleep-log/versions", json={"questions": v2_questions(), "base_version": 1})

    # New sessions default to the current version and use its rules.
    r = await client.post("/topics/sleep-log/sessions", json={"answers": ANSWERS})
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
        "/topics/sleep-log/sessions", json={"answers": {**ANSWERS, "hours": 20}, "version": 2}
    )
    assert r.status_code == 422
    r = await client.post("/topics/sleep-log/sessions", json={"answers": ANSWERS, "version": 9})
    assert r.status_code == 404

    # The old session keeps its version and answers.
    old = (await client.get(f"/sessions/{s1['id']}")).json()
    assert old["version"] == 1
    assert {a["key"] for a in old["answers"]} == {"hours", "wakeups", "quality"}

    # Editing an old session validates against its own version.
    r = await client.patch(f"/sessions/{s1['id']}", json={"answers": {"wakeups": 3}})
    assert r.status_code == 200, r.text
    assert r.json()["version"] == 1

    versions = (await client.get("/topics/sleep-log/versions")).json()
    assert {v["version"]: v["session_count"] for v in versions} == {2: 1, 1: 2}

    by_version = (await client.get("/topics/sleep-log/sessions", params={"version": 1})).json()
    assert by_version["total"] == 2


async def test_restore_removed_question(client: httpx.AsyncClient) -> None:
    await make_topic(client)
    await client.post("/topics/sleep-log/versions", json={"questions": v2_questions(), "base_version": 1})
    qs = [*v2_questions(), sleep_questions()[1]]
    r = await client.post("/topics/sleep-log/versions/check", json={"questions": qs})
    assert {c["question_key"]: c["kind"] for c in r.json()["changes"]} == {"wakeups": "restored"}
    r = await client.post("/topics/sleep-log/versions", json={"questions": qs, "base_version": 2})
    assert r.status_code == 201
    assert r.json()["current_version"] == 3
