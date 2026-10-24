"""Live Activity tokens and pushes (docs/specs/timers.md §6, §10.3): spec case T14.

APNs is a fake (``fake_apns``, an ``httpx.MockTransport``): no request leaves the process. The
sender runs as the run endpoint's background task, which the ASGI test client awaits before it
returns, so a test sees every push its request caused once the call returns, unless it stalls
the fake.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
from sqlalchemy import select

from app.db import get_sessionmaker
from app.models import ApnsDevice, LiveActivityToken, Run
from app.services.push import apns
from app.services.push import live_activity as la
from app.services.push.apns import MAX_PAYLOAD_BYTES
from tests.fake_apns import TOPIC, FakeApns, Sent, token
from tests.helpers import feed_locks
from tests.test_api_runs import Driver, frozen_clock, timed

NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)
STEPS = [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}]
PHONE_A = token(0xA)  # APNs device tokens
PHONE_B = token(0xB)


@pytest.fixture(autouse=True)
def _clock(monkeypatch: pytest.MonkeyPatch) -> None:
    frozen_clock(monkeypatch, NOW)


def la_token(n: int) -> str:
    """A well-formed Live Activity token (longer than a device token)."""
    return f"{n:0160x}"


def device(phone: str, *, live_activity: bool = True) -> dict[str, Any]:
    return {"apns_token": phone, "live_activity": live_activity}


async def register(client: httpx.AsyncClient, status: int = 201, **body: Any) -> Any:
    body = {"environment": "production", **body}
    for key in ("topic_id", "run_id"):
        if isinstance(body.get(key), UUID):
            body[key] = str(body[key])
    r = await client.post("/push/apns/live-activities", json=body)
    assert r.status_code == status, r.text
    return r.json() if r.content else None


async def start_token(client: httpx.AsyncClient, n: int, phone: str) -> str:
    await register(client, token=la_token(n), kind="start", device_token=phone)
    return la_token(n)


async def update_token(client: httpx.AsyncClient, n: int, phone: str, topic_id: str, run_id: str) -> str:
    await register(
        client, token=la_token(n), kind="update", device_token=phone, topic_id=topic_id, run_id=run_id
    )
    return la_token(n)


async def tokens() -> dict[str, LiveActivityToken]:
    async with get_sessionmaker()() as db:
        return {t.token: t for t in (await db.execute(select(LiveActivityToken))).scalars()}


def to(fake: FakeApns, tok: str) -> list[Sent]:
    return [s for s in fake.sent if s.device == tok]


def aps(sent: Sent) -> dict[str, Any]:
    body: dict[str, Any] = sent.body["aps"]
    return body


async def routine(client: httpx.AsyncClient, name: str = "Routine") -> dict[str, Any]:
    return await timed(client, name, steps=STEPS)


# --- registration -----------------------------------------------------------------------------


async def test_register_both_kinds_and_delete(client: httpx.AsyncClient) -> None:
    topic_id, run_id = str(uuid4()), str(uuid4())
    out = await register(client, token=la_token(1).upper(), kind="start", device_token=PHONE_A.upper())
    assert out["token"] == la_token(1)
    assert out["device_token"] == PHONE_A
    assert out["topic_id"] is None
    out = await register(
        client, token=la_token(2), kind="update", device_token=PHONE_A, topic_id=topic_id, run_id=run_id
    )
    assert (out["kind"], out["topic_id"], out["run_id"]) == ("update", topic_id, run_id)
    assert set(await tokens()) == {la_token(1), la_token(2)}

    for _ in range(2):  # idempotent
        r = await client.post("/push/apns/live-activities/delete", json={"token": la_token(2)})
        assert r.status_code == 204
    assert set(await tokens()) == {la_token(1)}


async def test_register_checks_the_fields_for_its_kind(client: httpx.AsyncClient) -> None:
    await register(client, 422, token=la_token(1), kind="update", device_token=PHONE_A, topic_id=str(uuid4()))
    await register(client, 422, token=la_token(1), kind="start", device_token=PHONE_A, run_id=str(uuid4()))
    await register(client, 422, token="xyz", kind="start", device_token=PHONE_A)
    assert await tokens() == {}


async def test_a_new_push_to_start_token_replaces_the_devices_older_one(client: httpx.AsyncClient) -> None:
    await start_token(client, 1, PHONE_A)
    await start_token(client, 2, PHONE_B)
    await update_token(client, 3, PHONE_A, str(uuid4()), str(uuid4()))
    await start_token(client, 4, PHONE_A)
    await start_token(client, 4, PHONE_A)  # a refresh keeps it
    assert set(await tokens()) == {la_token(2), la_token(3), la_token(4)}


# --- push-to-start --------------------------------------------------------------------------


async def test_push_to_start_skips_the_device_that_started_its_own(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    a, b = await start_token(client, 1, PHONE_A), await start_token(client, 2, PHONE_B)
    topic = await routine(client, "Morning routine")
    await Driver(client, topic).start(device=device(PHONE_A))

    assert to(fake_apns, a) == []
    [sent] = to(fake_apns, b)
    assert sent.headers["apns-push-type"] == "liveactivity"
    assert sent.headers["apns-topic"] == f"{TOPIC}.push-type.liveactivity"
    assert sent.headers["apns-priority"] == "10"
    assert sent.headers["authorization"].startswith("bearer ")
    body = aps(sent)
    assert body["event"] == "start"
    assert body["timestamp"] == int(fake_apns.now)
    assert body["attributes-type"] == "RunActivityAttributes"
    assert body["attributes"]["topic_id"] == topic["id"]
    assert body["attributes"]["topic_name"] == "Morning routine"
    assert body["input-push-token"] == 1
    assert body["content-state"]["label"] == "Shower"
    assert body["content-state"]["revision"] == 1
    assert sent.size <= MAX_PAYLOAD_BYTES


async def test_push_to_start_reaches_a_device_without_its_own_activity(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    a = await start_token(client, 1, PHONE_A)
    await Driver(client, await routine(client)).start(device=device(PHONE_A, live_activity=False))
    assert [aps(s)["event"] for s in to(fake_apns, a)] == ["start"]


async def test_no_push_to_start_for_a_merge_or_a_replay(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    topic = await routine(client)
    first = Driver(client, topic)
    await first.start()  # from the PWA: no device
    b = await start_token(client, 2, PHONE_B)
    await first.start(status=200)  # a replay
    await Driver(client, topic).start(5, status=201)  # merged into the open run
    assert to(fake_apns, b) == []


# --- updates ----------------------------------------------------------------------------------


async def test_update_skips_the_originating_device_and_carries_the_latest_state(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    topic = await routine(client)
    run = Driver(client, topic)
    await run.start()
    a = await update_token(client, 1, PHONE_A, topic["id"], run.id)
    b = await update_token(client, 2, PHONE_B, topic["id"], run.id)
    other = await update_token(client, 3, PHONE_B, str(uuid4()), str(uuid4()))  # another run

    await run.tap("next", 60, seg=0, device=device(PHONE_A))
    assert to(fake_apns, a) == []
    assert to(fake_apns, other) == []
    [sent] = to(fake_apns, b)
    state = aps(sent)["content-state"]
    assert aps(sent)["event"] == "update"
    assert "stale-date" in aps(sent)
    assert (state["seg"], state["label"], state["revision"], state["status"]) == (
        1,
        "Breakfast",
        2,
        "running",
    )

    await run.tap("pause", 90)  # the PWA: every iPhone hears of it
    assert [aps(s)["content-state"]["status"] for s in to(fake_apns, a)] == ["paused"]


async def test_an_alias_runs_tokens_get_the_merged_runs_updates(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    topic = await routine(client)
    run, loser = Driver(client, topic), Driver(client, topic)
    await run.start()
    await loser.start(5, status=201)  # merged: loser.id is an alias
    b = await update_token(client, 2, PHONE_B, topic["id"], loser.id)
    await run.tap("next", 60, seg=0)
    assert [aps(s)["content-state"]["run_id"] for s in to(fake_apns, b)] == [run.id]


async def test_sends_are_serialised_per_topic_with_the_state_at_send_time(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    topic = await routine(client)
    run = Driver(client, topic)
    await run.start()
    a = await update_token(client, 1, PHONE_A, topic["id"], run.id)
    b = await update_token(client, 2, PHONE_B, topic["id"], run.id)

    fake_apns.quota = 0  # every send stalls until allowed
    first = asyncio.create_task(run.tap("next", 60, seg=0))
    await fake_apns.wait_started(2)  # one push, to both tokens
    # The first push is in flight, and the event's transaction is committed: no feed lock held.
    async with get_sessionmaker()() as db:
        assert await feed_locks(db) == 0
        assert (await db.get_one(Run, UUID(run.id))).revision == 2
    async with asyncio.timeout(5):  # they only queue: neither waits for the stalled send
        await run.tap("pause", 70)  # queued
        # Replaces the queued one. Phone A's own tap, but merged with the PWA's pause, which A
        # hasn't seen: A gets the push too.
        await run.tap("lap", 80, seg=1, device=device(PHONE_A))
    assert fake_apns.max_in_flight == 2
    fake_apns.allow()
    await first

    sent = to(fake_apns, b)
    assert [aps(s)["content-state"]["revision"] for s in sent] == [2, 4]
    assert [aps(s)["content-state"]["revision"] for s in fake_apns.sent] == [2, 2, 4, 4]  # never interleaved
    assert aps(sent[-1])["content-state"]["status"] == "paused"
    assert aps(sent[-1])["content-state"]["seg"] == 2
    assert [aps(s)["content-state"]["revision"] for s in to(fake_apns, a)] == [2, 4]


async def test_topics_are_not_serialised_with_each_other(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    one, two = await routine(client, "One"), await routine(client, "Two")
    r1, r2 = Driver(client, one), Driver(client, two)
    await r1.start()
    await r2.start()
    await update_token(client, 1, PHONE_B, one["id"], r1.id)
    await update_token(client, 2, PHONE_B, two["id"], r2.id)
    fake_apns.quota = 0
    tasks = [asyncio.create_task(r1.tap("next", 60, seg=0)), asyncio.create_task(r2.tap("next", 60, seg=0))]
    await fake_apns.wait_started(2)
    assert fake_apns.max_in_flight == 2
    fake_apns.allow()
    await asyncio.gather(*tasks)


# --- end --------------------------------------------------------------------------------------


async def test_end_drops_only_the_ended_runs_update_tokens(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    topic = await routine(client)
    run, loser = Driver(client, topic), Driver(client, topic)
    await run.start()
    await loser.start(5, status=201)
    a = await update_token(client, 1, PHONE_A, topic["id"], run.id)
    b = await update_token(client, 2, PHONE_B, topic["id"], loser.id)  # the alias's
    newer = await update_token(client, 3, PHONE_B, topic["id"], str(uuid4()))  # a newer run, in the gap
    starts = await start_token(client, 4, PHONE_B)

    await run.tap("stop", 300, device=device(PHONE_A))
    assert to(fake_apns, a) == []  # it ended locally
    assert to(fake_apns, newer) == []
    [sent] = to(fake_apns, b)
    body = aps(sent)
    assert body["event"] == "end"
    assert body["content-state"]["status"] == "stopped"
    assert body["content-state"]["active_ms"] == 300_000
    assert body["dismissal-date"] == body["timestamp"] + la.DISMISS_SECONDS
    assert set(await tokens()) == {newer, starts}


async def test_end_when_finishing_and_discarded(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    topic = await timed(
        client,
        "Asked",
        steps=STEPS,
        questions=[{"key": "mood", "label": "Mood", "type": "int", "min": 0, "max": 9}],
    )
    run = Driver(client, topic)
    await run.start()
    b = await update_token(client, 2, PHONE_B, topic["id"], run.id)
    await run.tap("stop", 60)  # required answers missing: finishing
    [sent] = to(fake_apns, b)
    assert (aps(sent)["event"], aps(sent)["content-state"]["status"]) == ("end", "finishing")

    other = Driver(client, await routine(client))
    await other.start()
    c = await update_token(client, 3, PHONE_B, other.topic["id"], other.id)
    await other.tap("discard", 30)
    [sent] = to(fake_apns, c)
    assert aps(sent)["content-state"]["status"] == "discarded"
    assert aps(sent)["dismissal-date"] <= aps(sent)["timestamp"]
    assert await tokens() == {}


# --- failures ---------------------------------------------------------------------------------


@pytest.mark.parametrize(("status", "reason"), [(410, "Unregistered"), (400, "BadDeviceToken")])
async def test_a_gone_token_drops_only_that_token(
    client: httpx.AsyncClient, fake_apns: FakeApns, status: int, reason: str
) -> None:
    r = await client.post("/push/apns/devices", json={"token": PHONE_B, "environment": "production"})
    assert r.status_code == 201
    async with get_sessionmaker()() as db, db.begin():
        (await db.scalar(select(ApnsDevice).where(ApnsDevice.token == PHONE_B))).failure_count = 3  # type: ignore[union-attr]
    topic = await routine(client)
    run = Driver(client, topic)
    await run.start()
    gone = await update_token(client, 1, PHONE_B, topic["id"], run.id)
    kept = await update_token(client, 2, PHONE_B, topic["id"], run.id)
    failing = await update_token(client, 3, PHONE_B, topic["id"], run.id)
    starts = await start_token(client, 4, PHONE_B)
    fake_apns.replies[gone] = [(status, reason)]
    fake_apns.replies[failing] = [(500, "InternalServerError")]

    await run.tap("next", 60, seg=0)
    assert len(fake_apns.sent) == 3
    assert set(await tokens()) == {kept, failing, starts}
    async with get_sessionmaker()() as db:
        phone = await db.scalar(select(ApnsDevice).where(ApnsDevice.token == PHONE_B))
        assert phone is not None
        assert phone.failure_count == 3
        assert phone.last_success_at is None


async def test_nothing_is_sent_when_apns_is_off(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(apns, "get_sender", lambda: None)
    topic = await routine(client)
    run = Driver(client, topic)
    await start_token(client, 1, PHONE_B)
    await run.start()
    await update_token(client, 2, PHONE_B, topic["id"], run.id)
    await run.tap("stop", 60)
    assert len(await tokens()) == 2  # nothing ended by push, nothing dropped
