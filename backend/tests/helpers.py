"""Payload helpers shared by API tests."""

from __future__ import annotations

from typing import Any

import httpx


def sleep_questions() -> list[dict[str, Any]]:
    return [
        {"key": "hours", "label": "Hours slept", "type": "double", "min": 0, "max": 24, "unit": "h"},
        {"key": "wakeups", "label": "Times woke up", "type": "int", "min": 0, "max": 20},
        {
            "key": "quality",
            "label": "Sleep quality",
            "type": "enum",
            "options": [
                {"value": "poor", "label": "Poor"},
                {"value": "ok", "label": "OK"},
                {"value": "great", "label": "Great"},
            ],
        },
        {"key": "dream", "label": "Dream journal", "type": "str", "required": False, "multiline": True},
    ]


async def make_topic(
    client: httpx.AsyncClient,
    name: str = "Sleep log",
    questions: list[dict[str, Any]] | None = None,
    **extra: Any,
) -> dict[str, Any]:
    r = await client.post(
        "/topics", json={"name": name, "questions": questions or sleep_questions(), **extra}
    )
    assert r.status_code == 201, r.text
    body: dict[str, Any] = r.json()
    return body


async def record(
    client: httpx.AsyncClient, ref: str, answers: dict[str, Any], **extra: Any
) -> dict[str, Any]:
    r = await client.post(f"/topics/{ref}/entries", json={"answers": answers, **extra})
    assert r.status_code == 201, r.text
    body: dict[str, Any] = r.json()
    return body
