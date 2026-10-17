"""Payload helpers shared by API tests."""

from __future__ import annotations

import asyncio
from datetime import datetime
from typing import Any

import httpx
from sqlalchemy import text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.models import Topic
from app.services.feed import FEED_LOCK_ID


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


async def backdate_schedule(slug: str, to: datetime) -> None:
    """Pretend the topic's schedule was set at ``to`` (due status ignores anything earlier)."""
    async with get_sessionmaker()() as db:
        await db.execute(
            update(Topic)
            .where(Topic.slug == slug)
            .values(schedule_updated_at=to, updated_at=Topic.updated_at)
        )
        await db.commit()


async def wait_for_lock_waiter(db: AsyncSession) -> bool:
    """Poll until some session is blocked waiting for the feed lock."""
    stmt = text("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = :id AND NOT granted")
    try:
        async with asyncio.timeout(5):
            while not await db.scalar(stmt, {"id": FEED_LOCK_ID}):
                await db.rollback()
                await asyncio.sleep(0.01)
    except TimeoutError:
        return False
    finally:
        await db.rollback()
    return True
