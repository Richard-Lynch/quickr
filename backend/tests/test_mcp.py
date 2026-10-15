"""MCP server via the FastMCP in-memory transport."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any

import pytest
from fastmcp import Client
from fastmcp.exceptions import ToolError

from app.mcp_server import mcp
from tests.helpers import sleep_questions


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
        "topic_stats",
        "question_series",
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
            "publish_topic_version", {"ref": "sleep-log", "questions": sleep_questions(), "base_version": 1}
        )
    with pytest.raises(ToolError, match="based on version 7"):
        await mcp_client.call_tool(
            "publish_topic_version",
            {"ref": "sleep-log", "questions": sleep_questions()[:2], "base_version": 7},
        )
    dup = [*sleep_questions(), sleep_questions()[0]]
    with pytest.raises(ToolError, match="question keys must be unique"):
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
