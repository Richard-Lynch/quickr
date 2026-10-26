"""``scripts/send_reminder.py``: a topic's real reminder, sent now, with the scheduler untouched."""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
from sqlalchemy import func, select

from app.db import get_sessionmaker
from app.models import PushSlotDelivery, Topic
from app.services import notification, scheduler
from app.services.push import web as web_push
from scripts import send_reminder
from tests.fake_apns import FakeApns, token
from tests.helpers import backdate_schedule
from tests.vectors import FIXTURES_DIR

VECTORS = {
    c["name"]: c for c in json.loads((FIXTURES_DIR / "notification-vectors.json").read_text())["cases"]
}
INTERVAL = {"kind": "interval", "every_minutes": 60, "timezone": "UTC"}
SUB = {
    "endpoint": "https://fcm.googleapis.com/fcm/send/1",
    "keys": {"p256dh": "p256dh-1", "auth": "auth-1"},
    "user_agent": "pytest",
}


@pytest.fixture
def web_outbox(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, Any]]:
    sent: list[dict[str, Any]] = []

    def fake_deliver(subscription: dict[str, Any], data: str, *args: Any) -> None:
        sent.append(json.loads(data))

    monkeypatch.setattr(web_push, "deliver", fake_deliver)
    return sent


async def _register_device(client: httpx.AsyncClient) -> None:
    r = await client.post("/push/apns/devices", json={"token": token(1), "environment": "sandbox"})
    assert r.is_success, r.text


async def _topic_from_vector(client: httpx.AsyncClient, name: str, vector: str) -> dict[str, Any]:
    case = VECTORS[vector]
    assert case["version"] == 1  # a new topic's version
    body = {"name": name, "questions": case["questions"], "timer": case["timer"], "schedule": INTERVAL}
    r = await client.post("/topics", json=body)
    assert r.status_code == 201, r.text
    topic: dict[str, Any] = r.json()
    await backdate_schedule(topic["slug"], datetime.now(UTC) - timedelta(days=1))
    return topic


def _expected_category(vector: str, server_id: str, topic_id: str) -> str:
    """The vector's category, for this server and topic: its hash input with the ids swapped."""
    case = VECTORS[vector]
    hashed = case["expected"]["hash_input"].replace(case["server_id"], server_id)
    hashed = hashed.replace(case["topic_id"], topic_id)
    return f"quickr.t.{topic_id}.{hashlib.sha256(hashed.encode()).hexdigest()[:16]}"


async def _scheduler_state() -> tuple[list[tuple[Any, ...]], int]:
    async with get_sessionmaker()() as db:
        topics = (
            await db.execute(
                select(Topic.slug, Topic.last_notified_due_since, Topic.updated_at, Topic.revision).order_by(
                    Topic.slug
                )
            )
        ).all()
        progress = await db.scalar(select(func.count()).select_from(PushSlotDelivery))
    return [tuple(t) for t in topics], progress or 0


async def _run(*argv: str) -> int:
    return await send_reminder.main(send_reminder.parser().parse_args(list(argv)))


async def test_sends_the_real_reminder_of_a_timed_and_a_log_topic(
    client: httpx.AsyncClient,
    fake_apns: FakeApns,
    web_outbox: list[dict[str, Any]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    timed = await _topic_from_vector(client, "Routine", "timed-no-steps")
    logged = await _topic_from_vector(client, "Mood", "enum-4")
    await _register_device(client)
    assert (await client.post("/push/subscriptions", json=SUB)).is_success
    server_id = (await client.get("/changes")).headers["x-quickr-server-id"]
    before = await _scheduler_state()

    slots = {"routine": "2026-10-26T08:00:00Z", "mood": "2026-10-26T09:00:00Z"}
    for slug, due_since in slots.items():
        assert await _run(slug, "--due-since", due_since) == 0
        out = capsys.readouterr().out
        assert "sent the reminder to 2 of 2 targets (apns: 1 sent, 0 failed of 1, web: 1 sent" in out

    assert await _scheduler_state() == before  # no slot marked, no progress, no edit
    assert len(fake_apns.sent) == 2
    assert len(web_outbox) == 2
    for topic, vector, (apns_sent, web_sent) in [
        (timed, "timed-no-steps", (fake_apns.sent[0], web_outbox[0])),
        (logged, "enum-4", (fake_apns.sent[1], web_outbox[1])),
    ]:
        expected = VECTORS[vector]["expected"]
        aps, quickr = apns_sent.body["aps"], apns_sent.body["quickr"]
        assert aps["category"] == _expected_category(vector, server_id, topic["id"])
        assert aps["thread-id"] == f"topic-{topic['id']}"
        assert quickr["quick_log"] == expected["quick_log"]
        assert quickr["due_since"] == slots[topic["slug"]]
        assert quickr["kind"] == "due"
        assert apns_sent.headers["apns-collapse-id"] == f"due-{topic['id']}"
        assert web_sent["quick_log"] == expected["quick_log"]
        assert web_sent["due_since"] == slots[topic["slug"]]
        assert web_sent["tag"] == f"due-{topic['id']}"

    # The scheduler still sends both slots as if nothing had happened.
    async with get_sessionmaker()() as db:
        assert await scheduler.tick(db) == 2


async def test_dry_run_prints_the_actions_and_sends_nothing(
    client: httpx.AsyncClient,
    fake_apns: FakeApns,
    web_outbox: list[dict[str, Any]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    timed = await _topic_from_vector(client, "Routine", "timed-no-steps")
    logged = await _topic_from_vector(client, "Mood", "enum-4")
    await _register_device(client)
    server_id = (await client.get("/changes")).headers["x-quickr-server-id"]
    before = await _scheduler_state()

    entry_ids = []
    for due_since in ("2026-10-26T08:00:00Z", "2026-10-26T08:00:01+00:00"):
        assert await _run("routine", "--due-since", due_since, "--dry-run", "--channel", "apns") == 0
        out = capsys.readouterr().out
        assert "actions: Start (start)" in out
        assert f"category {_expected_category('timed-no-steps', server_id, timed['id'])}" in out
        assert "dry run: nothing sent" in out
        entry_id = notification.action_entry_id(server_id, timed["id"], due_since.replace("+00:00", "Z"))
        assert f"action entry id (also the run id a Start makes): {entry_id}" in out
        entry_ids.append(entry_id)
    assert entry_ids[0] != entry_ids[1]  # a new slot: a fresh entry and run id

    assert await _run(logged["id"], "--dry-run") == 0
    out = capsys.readouterr().out
    titles = ", ".join(f"{a['title']} ({a['kind']})" for a in VECTORS["enum-4"]["expected"]["actions"])
    assert f"actions: {titles}" in out
    assert f"category {_expected_category('enum-4', server_id, logged['id'])}" in out
    rendered = json.loads(out[out.index("{") : out.rindex("}") + 1])
    assert rendered["apns"]["aps"]["category"] == _expected_category("enum-4", server_id, logged["id"])
    assert rendered["web"]["quick_log"] == VECTORS["enum-4"]["expected"]["quick_log"]

    assert fake_apns.sent == []
    assert web_outbox == []
    assert await _scheduler_state() == before


async def test_one_channel_and_unknown_topics(
    client: httpx.AsyncClient,
    fake_apns: FakeApns,
    web_outbox: list[dict[str, Any]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    await _topic_from_vector(client, "Mood", "enum-4")
    await _register_device(client)
    assert (await client.post("/push/subscriptions", json=SUB)).is_success

    assert await _run("mood", "--channel", "webpush") == 0
    assert "sent the reminder to 1 of 1 targets (web: 1 sent, 0 failed of 1)" in capsys.readouterr().out
    assert len(web_outbox) == 1
    assert fake_apns.sent == []

    assert await _run("nope") == 2
    assert "topic 'nope' not found" in capsys.readouterr().err


async def test_apns_channel_needs_apns(client: httpx.AsyncClient, capsys: pytest.CaptureFixture[str]) -> None:
    await _topic_from_vector(client, "Mood", "enum-4")
    assert await _run("mood", "--channel", "apns") == 2
    assert "APNs is not configured" in capsys.readouterr().err


def test_due_since_needs_a_timezone() -> None:
    with pytest.raises(SystemExit):
        send_reminder.parser().parse_args(["mood", "--due-since", "2026-10-26T08:00:00"])
    args = send_reminder.parser().parse_args(["mood", "--due-since", "2026-10-26T10:00:00.5+02:00"])
    assert args.due_since == datetime(2026, 10, 26, 8, tzinfo=UTC)
