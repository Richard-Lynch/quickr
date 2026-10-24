"""MCP server via the FastMCP in-memory transport."""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastmcp import Client
from fastmcp.exceptions import ToolError

from app.mcp_server import mcp
from tests.helpers import backdate_schedule, sleep_questions
from tests.test_api_runs import frozen_clock


@pytest.fixture
async def mcp_client(clean_db: None) -> AsyncIterator[Client[Any]]:
    async with Client(mcp) as c:
        yield c


async def call(client: Client[Any], tool: str, **args: Any) -> dict[str, Any]:
    result = await client.call_tool(tool, args)
    assert not result.is_error
    assert result.structured_content is not None
    return result.structured_content


async def test_lists_tools_with_schemas(mcp_client: Client[Any]) -> None:
    tools = {t.name: t for t in await mcp_client.list_tools()}
    assert set(tools) == {
        "list_topics",
        "get_topic",
        "create_topic",
        "update_topic",
        "set_topic_archived",
        "list_topic_versions",
        "check_topic_version",
        "publish_topic_version",
        "record_entry",
        "list_entries",
        "update_entry",
        "delete_entry",
        "list_due_topics",
        "topic_stats",
        "question_series",
        "start_run",
        "run_action",
        "list_runs",
        "edit_run_timing",
    }
    for tool in tools.values():
        assert tool.description
        assert tool.input_schema["type"] == "object"
    assert set(tools["record_entry"].input_schema["required"]) == {"ref", "answers"}
    assert tools["create_topic"].output_schema is not None
    assert "questions" in tools["create_topic"].output_schema["properties"]


async def test_create_record_stats_publish(mcp_client: Client[Any]) -> None:
    topic = await call(mcp_client, "create_topic", name="Sleep log", questions=sleep_questions())
    assert topic["slug"] == "sleep-log"
    assert topic["current_version"] == 1
    assert [q["key"] for q in topic["questions"]] == ["hours", "wakeups", "quality", "dream"]

    s1 = await call(
        mcp_client,
        "record_entry",
        ref="sleep-log",
        answers={"hours": 7.5, "wakeups": 1, "quality": "ok"},
        captured_at="2026-05-01T08:00:00Z",
    )
    assert (s1["channel"], s1["source"], s1["version"]) == ("mcp", "mcp", 1)
    assert s1["answers"][0] == {"key": "hours", "type": "double", "value": 7.5}
    s2 = await call(
        mcp_client,
        "record_entry",
        ref=topic["id"],
        answers={"hours": 6.5, "wakeups": 3, "quality": "poor"},
        source="claude",
        meta={"conversation": "abc"},
    )
    assert (s2["source"], s2["meta"]) == ("claude", {"conversation": "abc"})

    stats = await call(mcp_client, "topic_stats", ref="sleep-log")
    assert stats["entry_count"] == 2
    by_key = {q["key"]: q for q in stats["questions"]}
    assert by_key["hours"]["mean"] == 7.0
    assert by_key["hours"]["type"] == "double"
    assert {o["value"]: o["count"] for o in by_key["quality"]["options"]} == {"poor": 1, "ok": 1, "great": 0}

    stats = await call(mcp_client, "topic_stats", ref="sleep-log", captured_to="2026-05-02T00:00:00Z")
    assert stats["entry_count"] == 1

    new_qs = [*sleep_questions(), {"key": "nap", "label": "Nap", "type": "int", "required": False}]
    report = await call(mcp_client, "check_topic_version", ref="sleep-log", questions=new_qs)
    assert report["ok"] is True
    assert report["changes"] == [{"kind": "added", "question_key": "nap", "details": []}]

    published = await call(
        mcp_client,
        "publish_topic_version",
        ref="sleep-log",
        questions=new_qs,
        base_version=1,
        timer=None,
        change_note="nap",
    )
    assert published["current_version"] == 2
    assert published["questions"][-1]["key"] == "nap"

    versions = await mcp_client.call_tool("list_topic_versions", {"ref": "sleep-log"})
    assert [v["version"] for v in versions.structured_content["result"]] == [2, 1]  # type: ignore[index]

    page = await call(mcp_client, "list_entries", ref="sleep-log")
    assert page["total"] == 2

    updated = await call(mcp_client, "update_entry", entry_id=s1["id"], answers={"wakeups": 2})
    assert {a["key"]: a["value"] for a in updated["answers"]}["wakeups"] == 2
    assert updated["version"] == 1

    series = await call(mcp_client, "question_series", ref="sleep-log", key="hours", bucket="month")
    assert sum(p["count"] for p in series["points"]) == 2

    deleted = await mcp_client.call_tool("delete_entry", {"entry_id": s2["id"]})
    assert deleted.data == "deleted"

    listed = await call(mcp_client, "list_topics", query="sleep")
    assert [t["slug"] for t in listed["items"]] == ["sleep-log"]


async def test_record_entry_errors_include_field_details(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Sleep log", questions=sleep_questions())
    with pytest.raises(ToolError) as exc:
        await mcp_client.call_tool(
            "record_entry", {"ref": "sleep-log", "answers": {"hours": 30, "quality": "superb", "ghost": 1}}
        )
    msg = str(exc.value)
    assert msg.startswith("one or more answers are invalid: ")
    assert "answers.ghost: unknown question" in msg
    assert "answers.hours: must be <= 24" in msg
    assert "answers.wakeups: required" in msg
    assert "answers.quality: must be one of: great, ok, poor" in msg

    result = await mcp_client.call_tool(
        "record_entry", {"ref": "sleep-log", "answers": {}}, raise_on_error=False
    )
    assert result.is_error


async def test_domain_errors_are_surfaced(mcp_client: Client[Any]) -> None:
    with pytest.raises(ToolError, match="topic 'nope' not found"):
        await mcp_client.call_tool("get_topic", {"ref": "nope"})

    await call(mcp_client, "create_topic", name="Sleep log", questions=sleep_questions())
    with pytest.raises(ToolError, match="already in use"):
        await mcp_client.call_tool("create_topic", {"name": "Sleep log", "questions": sleep_questions()})
    with pytest.raises(ToolError, match="no changes to publish"):
        await mcp_client.call_tool(
            "publish_topic_version",
            {"ref": "sleep-log", "questions": sleep_questions(), "base_version": 1, "timer": None},
        )
    with pytest.raises(ToolError, match="based on version 7"):
        await mcp_client.call_tool(
            "publish_topic_version",
            {"ref": "sleep-log", "questions": sleep_questions()[:2], "base_version": 7, "timer": None},
        )
    dup = [*sleep_questions(), sleep_questions()[0]]
    with pytest.raises(ToolError, match=r"duplicate question key .hours."):
        await mcp_client.call_tool("check_topic_version", {"ref": "sleep-log", "questions": dup})
    await call(mcp_client, "set_topic_archived", ref="sleep-log", archived=True)
    with pytest.raises(ToolError, match="archived"):
        await mcp_client.call_tool(
            "record_entry", {"ref": "sleep-log", "answers": {"hours": 1, "wakeups": 0, "quality": "ok"}}
        )


async def test_argument_validation_errors(mcp_client: Client[Any]) -> None:
    with pytest.raises(ToolError):
        await mcp_client.call_tool("create_topic", {"name": "", "questions": sleep_questions()})
    with pytest.raises(ToolError):
        await mcp_client.call_tool("list_topics", {"limit": 0})


async def test_unexpected_errors_are_masked(mcp_client: Client[Any], monkeypatch: pytest.MonkeyPatch) -> None:
    from app.services import topics as topic_svc

    async def boom(*args: object, **kwargs: object) -> None:
        raise RuntimeError("secret internals")

    monkeypatch.setattr(topic_svc, "list_topics", boom)
    with pytest.raises(ToolError) as exc:
        await mcp_client.call_tool("list_topics", {})
    assert "secret" not in str(exc.value)


async def test_schedules_and_due_topics(mcp_client: Client[Any]) -> None:
    interval = {"kind": "interval", "every_minutes": 60, "timezone": "UTC"}
    t = await call(mcp_client, "create_topic", name="Water", questions=sleep_questions(), schedule=interval)
    assert t["schedule"]["every_minutes"] == 60
    assert t["due"]["is_due"] is False  # due one interval after the schedule was set
    await call(mcp_client, "create_topic", name="Plain", questions=sleep_questions())
    assert (await call(mcp_client, "list_due_topics"))["items"] == []
    await backdate_schedule("water", datetime.now(UTC) - timedelta(hours=2))

    due = await call(mcp_client, "list_due_topics")
    assert [x["slug"] for x in due["items"]] == ["water"]
    listed = await call(mcp_client, "list_topics", due_only=True)
    assert listed["total"] == 1
    by_name = await call(mcp_client, "list_topics", sort="name")
    assert [x["slug"] for x in by_name["items"]] == ["plain", "water"]

    updated = await call(mcp_client, "update_topic", ref="water", schedule={**interval, "every_minutes": 30})
    assert updated["schedule"]["every_minutes"] == 30
    kept = await call(mcp_client, "update_topic", ref="water", description="drink")
    assert kept["schedule"]["every_minutes"] == 30
    cleared = await call(mcp_client, "update_topic", ref="water", clear_schedule=True)
    assert (cleared["schedule"], cleared["due"]) == (None, None)
    assert (await call(mcp_client, "list_due_topics"))["items"] == []


async def test_record_entry_idempotent_and_multi_select(mcp_client: Client[Any]) -> None:
    questions = [
        *sleep_questions(),
        {
            "key": "factors",
            "label": "Factors",
            "type": "enum",
            "multiple": True,
            "required": False,
            "options": [{"value": "coffee", "label": "Coffee"}, {"value": "screens", "label": "Screens"}],
        },
    ]
    await call(mcp_client, "create_topic", name="Sleep log", questions=questions)
    answers = {"hours": 7, "wakeups": 0, "quality": "ok", "factors": ["screens", "coffee"]}
    entry_id = "6f1c1d1e-0000-4000-8000-000000000001"
    first = await call(mcp_client, "record_entry", ref="sleep-log", answers=answers, id=entry_id)
    assert first["id"] == entry_id
    assert first["answers"][-1] == {"key": "factors", "type": "enum_list", "value": ["coffee", "screens"]}
    again = await call(mcp_client, "record_entry", ref="sleep-log", answers=answers, id=entry_id)
    assert again == first
    assert (await call(mcp_client, "list_entries", ref="sleep-log"))["total"] == 1


async def test_validation_errors_inside_tools_are_described(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Sleep log", questions=sleep_questions())
    with pytest.raises(ToolError, match="invalid arguments: captured_at: must not be more than 24 hours"):
        await mcp_client.call_tool(
            "record_entry",
            {
                "ref": "sleep-log",
                "answers": {"hours": 1, "wakeups": 0, "quality": "ok"},
                "captured_at": "2999-01-01T00:00:00Z",
            },
        )
    with pytest.raises(ToolError, match="invalid arguments: name: "):
        await mcp_client.call_tool("update_topic", {"ref": "sleep-log", "name": ""})


async def test_single_topics_through_mcp(mcp_client: Client[Any]) -> None:
    # A single topic (no questions): created, logged with no answers, and its stats.
    topic = await call(mcp_client, "create_topic", name="Took vitamins", questions=[])
    assert topic["questions"] == []
    entry = await call(mcp_client, "record_entry", ref="took-vitamins", answers={})
    assert entry["answers"] == []
    stats = await call(mcp_client, "topic_stats", ref="took-vitamins")
    assert stats["entry_count"] == 1
    assert stats["questions"] == []
    # Unchanged (still none) is "no changes"; adding a question is a normal new version.
    same = await call(mcp_client, "check_topic_version", ref="took-vitamins", questions=[])
    assert same["ok"] is False
    dose = [{"key": "dose", "label": "Dose", "type": "int", "required": False}]
    report = await call(mcp_client, "check_topic_version", ref="took-vitamins", questions=dose)
    assert report["ok"] is True
    assert report["changes"] == [{"kind": "added", "question_key": "dose", "details": []}]


async def test_publish_requires_timer(mcp_client: Client[Any]) -> None:
    timer = {"steps": [{"key": "load", "label": "Load"}]}
    await call(mcp_client, "create_topic", name="Dishwasher", questions=[], timer=timer)
    tools = {t.name: t for t in await mcp_client.list_tools()}
    assert "timer" in tools["publish_topic_version"].input_schema["required"]
    assert "timer" not in tools["create_topic"].input_schema.get("required", [])

    qs = [
        {"key": "full", "label": "Full load?", "type": "enum", "options": [{"value": "yes", "label": "Yes"}]}
    ]
    with pytest.raises(ToolError, match="timer"):
        await mcp_client.call_tool(
            "publish_topic_version", {"ref": "dishwasher", "questions": qs, "base_version": 1}
        )
    with pytest.raises(ToolError, match="duplicate step key 'load'"):
        await mcp_client.call_tool(
            "publish_topic_version",
            {
                "ref": "dishwasher",
                "questions": qs,
                "base_version": 1,
                "timer": {"steps": [timer["steps"][0]] * 2},
            },
        )
    await call(
        mcp_client, "publish_topic_version", ref="dishwasher", questions=qs, base_version=1, timer=timer
    )
    await call(
        mcp_client, "publish_topic_version", ref="dishwasher", questions=qs, base_version=2, timer=None
    )
    versions = (await mcp_client.call_tool("list_topic_versions", {"ref": "dishwasher"})).structured_content
    assert [v["timer"] for v in versions["result"]] == [None, timer, timer]  # type: ignore[index]


# --- runs (timers.md §11.6) ---------------------------------------------------------------------

ROUTINE = {"steps": [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}]}
MOOD = [{"key": "mood", "label": "Mood", "type": "int", "min": 0, "max": 10}]


@pytest.fixture
def may_day(monkeypatch: pytest.MonkeyPatch) -> None:
    """The server clock at noon on 2026-05-01, for runs with explicit `at`s that morning."""
    frozen_clock(monkeypatch, datetime(2026, 5, 1, 12, tzinfo=UTC))


@pytest.mark.usefixtures("may_day")
async def test_start_run(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Routine", questions=[], timer=ROUTINE)
    started = await call(mcp_client, "start_run", ref="routine", at="2026-05-01T08:00:00.0009Z")
    run = started["run"]
    assert (started["event"]["effect"], run["status"], run["version"]) == ("applied", "running", 1)
    assert run["started_at"] == "2026-05-01T08:00:00Z"  # truncated to the millisecond
    assert started["event"]["id"] == run["id"]
    assert run["events"][0]["source"] == "mcp"
    assert run["state"]["open"]["step"] == "shower"
    # A second start merges into the open run; `at` defaults to now.
    again = await call(mcp_client, "start_run", ref="routine")
    assert (again["event"]["reason"], again["run"]["id"]) == ("merged", run["id"])
    await call(mcp_client, "create_topic", name="Plain", questions=[])
    with pytest.raises(ToolError, match="not timed"):
        await mcp_client.call_tool("start_run", {"ref": "plain"})


async def test_run_action_fills_seg_step_and_pause_id(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Routine", questions=[], timer=ROUTINE)
    run_id = (await call(mcp_client, "start_run", ref="routine"))["run"]["id"]

    async def act(action: str, **args: Any) -> dict[str, Any]:
        return await call(mcp_client, "run_action", run_id=run_id, action=action, **args)

    with pytest.raises(ToolError, match="isn't paused"):
        await mcp_client.call_tool("run_action", {"run_id": run_id, "action": "resume"})
    nxt = await act("next")
    assert (nxt["event"]["effect"], nxt["run"]["events"][-1]["seg"]) == ("applied", 0)
    assert nxt["run"]["state"]["open"]["step"] == "breakfast"
    pause = await act("pause")
    resume = await act("resume")
    assert resume["event"]["effect"] == "applied"
    assert resume["run"]["events"][-1]["pause_id"] == pause["event"]["id"]
    skip = await act("skip")
    assert skip["run"]["events"][-1]["step"] == "breakfast"
    assert (skip["run"]["state"]["skipped"], skip["run"]["state"]["open"]["kind"]) == (["breakfast"], "lap")
    with pytest.raises(ToolError, match="no step left to skip"):
        await mcp_client.call_tool("run_action", {"run_id": run_id, "action": "skip"})
    lap = await act("lap")
    assert lap["run"]["events"][-1]["seg"] == 1
    # Taps without `at` are strictly after the run's latest one (timers.md §5.1).
    ats = [e["at"] for e in lap["run"]["events"]]
    assert ats == sorted(set(ats))
    stopped = await act("stop", notes="done")
    assert (stopped["run"]["status"], stopped["entry"]["notes"]) == ("stopped", "done")
    assert [s["kind"] for s in stopped["entry"]["timing"]["segments"]] == ["step", "lap", "lap"]
    with pytest.raises(ToolError, match="nothing is open"):
        await mcp_client.call_tool("run_action", {"run_id": run_id, "action": "next"})
    assert (await act("stop"))["event"]["reason"] == "already_closed"


async def test_run_action_finish_and_discard(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Routine", questions=MOOD, timer=ROUTINE)
    first = (await call(mcp_client, "start_run", ref="routine"))["run"]["id"]
    with pytest.raises(ToolError, match="hasn't stopped"):
        await mcp_client.call_tool(
            "run_action", {"run_id": first, "action": "finish", "answers": {"mood": 5}}
        )
    stop = await call(mcp_client, "run_action", run_id=first, action="stop")
    assert (stop["run"]["status"], stop["entry"]) == ("finishing", None)
    with pytest.raises(ToolError, match="mood"):
        await mcp_client.call_tool(
            "run_action", {"run_id": first, "action": "finish", "answers": {"mood": 11}}
        )
    finish = await call(mcp_client, "run_action", run_id=first, action="finish", answers={"mood": 5})
    assert finish["entry"]["answers"] == [{"key": "mood", "type": "int", "value": 5}]
    with pytest.raises(ToolError, match="answers"):
        await mcp_client.call_tool("run_action", {"run_id": first, "action": "pause", "answers": {"mood": 1}})

    second = (await call(mcp_client, "start_run", ref="routine"))["run"]["id"]
    discard = await call(mcp_client, "run_action", run_id=second, action="discard")
    assert discard["run"]["status"] == "discarded"


async def test_list_runs(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Routine", questions=MOOD, timer=ROUTINE)
    await call(mcp_client, "create_topic", name="Tea", questions=[], timer={"steps": []})
    finishing = (await call(mcp_client, "start_run", ref="routine"))["run"]["id"]
    await call(mcp_client, "run_action", run_id=finishing, action="stop")
    running = (await call(mcp_client, "start_run", ref="tea"))["run"]["id"]

    async def ids(**args: Any) -> list[tuple[str, str]]:
        result = (await mcp_client.call_tool("list_runs", args)).structured_content
        assert result is not None
        return [(r["id"], r["status"]) for r in result["result"]]

    assert await ids() == [(finishing, "finishing"), (running, "running")]
    assert await ids(status="open") == [(running, "running")]
    assert await ids(status="finishing") == [(finishing, "finishing")]
    with pytest.raises(ToolError):
        await mcp_client.call_tool("list_runs", {"status": "stopped"})


@pytest.mark.usefixtures("may_day")
async def test_edit_run_timing(mcp_client: Client[Any]) -> None:
    await call(mcp_client, "create_topic", name="Routine", questions=[], timer=ROUTINE)
    run_id = (await call(mcp_client, "start_run", ref="routine", at="2026-05-01T08:00:00Z"))["run"]["id"]
    await call(mcp_client, "run_action", run_id=run_id, action="next", at="2026-05-01T08:05:00Z")
    entry = (await call(mcp_client, "run_action", run_id=run_id, action="stop", at="2026-05-01T08:20:00Z"))[
        "entry"
    ]
    timing = {
        "started_at": "2026-05-01T08:00:00Z",
        "segments": [
            {"kind": "step", "step": "shower", "ended_at": "2026-05-01T08:10:00Z"},
            {"kind": "step", "step": "breakfast", "ended_at": "2026-05-01T08:25:00Z"},
        ],
        "skipped": [],
        "pauses": [{"start": "2026-05-01T08:12:00Z", "end": "2026-05-01T08:13:00Z"}],
    }
    edited = await call(
        mcp_client,
        "edit_run_timing",
        entry_id=entry["id"],
        timing=timing,
        expected_revision=entry["revision"],
    )
    assert (edited["captured_at"], edited["revision"]) == ("2026-05-01T08:25:00Z", entry["revision"] + 1)
    assert (edited["timing"]["edited"], edited["timing"]["active_ms"]) == (True, 24 * 60_000)
    with pytest.raises(ToolError, match="current revision"):
        await mcp_client.call_tool(
            "edit_run_timing",
            {"entry_id": entry["id"], "timing": timing, "expected_revision": entry["revision"]},
        )
    bad = {**timing, "segments": [{"kind": "step", "step": "coffee", "ended_at": "2026-05-01T08:25:00Z"}]}
    with pytest.raises(ToolError, match="not a step"):
        await mcp_client.call_tool(
            "edit_run_timing",
            {"entry_id": entry["id"], "timing": bad, "expected_revision": edited["revision"]},
        )
    with pytest.raises(ToolError, match="edit the run's times"):
        await mcp_client.call_tool(
            "update_entry", {"entry_id": entry["id"], "captured_at": "2026-05-01T09:00:00Z"}
        )
    # The run is frozen: a late tap is void, run_edited.
    late = await call(mcp_client, "run_action", run_id=run_id, action="stop", at="2026-05-01T08:30:00Z")
    assert late["event"]["reason"] == "run_edited"


async def test_timing_switched_off_mid_run(mcp_client: Client[Any]) -> None:
    """T11 through MCP: a run started on the timed version stops against it after a publish
    with timer null; a new start is refused."""
    await call(mcp_client, "create_topic", name="Routine", questions=[], timer=ROUTINE)
    run_id = (await call(mcp_client, "start_run", ref="routine"))["run"]["id"]
    await call(mcp_client, "publish_topic_version", ref="routine", questions=[], base_version=1, timer=None)
    stopped = await call(mcp_client, "run_action", run_id=run_id, action="stop")
    assert (stopped["entry"]["version"], stopped["entry"]["timing"]["segments"][0]["label"]) == (1, "Shower")
    with pytest.raises(ToolError, match="not timed"):
        await mcp_client.call_tool("start_run", {"ref": "routine"})
