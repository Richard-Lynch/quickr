"""Web Push: VAPID keys, subscriptions, delivery and the due-notification scheduler."""

from __future__ import annotations

import asyncio
import base64
import json
import re
import socket
from collections.abc import AsyncIterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
import requests
from cryptography.hazmat.primitives import serialization
from py_vapid import Vapid
from pywebpush import WebPushException
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app import push_guard
from app.config import Settings
from app.db import get_engine, get_sessionmaker
from app.models import PushSubscription, Topic
from app.services import push as push_svc
from app.services import scheduler
from app.services.push import web as web_push
from tests.helpers import backdate_schedule, make_topic, record

QUESTIONS = [{"key": "n", "label": "N", "type": "int"}]


def sub(n: int) -> dict[str, Any]:
    return {
        "endpoint": f"https://fcm.googleapis.com/fcm/send/{n}",
        "keys": {"p256dh": f"p256dh-{n}", "auth": f"auth-{n}"},
        "user_agent": "pytest",
    }


@dataclass
class Sent:
    endpoint: str
    payload: dict[str, Any]
    private_key: str | Vapid
    claims: dict[str, str | int]
    ttl: int


@pytest.fixture
def outbox(monkeypatch: pytest.MonkeyPatch) -> list[Sent]:
    """Replace the network sender; endpoints ending in /gone or /fail misbehave."""
    sent: list[Sent] = []

    def fake_deliver(
        subscription: dict[str, Any],
        data: str,
        private_key: str | Vapid,
        claims: dict[str, str | int],
        ttl: int,
    ) -> None:
        endpoint = subscription["endpoint"]
        if endpoint.endswith("/gone"):
            raise push_svc.PushGone("410")
        if endpoint.endswith("/fail"):
            raise push_svc.PushFailed("500")
        sent.append(Sent(endpoint, json.loads(data), private_key, claims, ttl))

    monkeypatch.setattr(web_push, "deliver", fake_deliver)
    return sent


@pytest.fixture
async def session(clean_db: None) -> AsyncIterator[AsyncSession]:
    async with get_sessionmaker()() as s:
        yield s


# --- VAPID keys ------------------------------------------------------------------


async def test_push_config_generates_and_persists_keys(client: httpx.AsyncClient) -> None:
    first = (await client.get("/push/config")).json()["public_key"]
    assert len(first) == 87  # base64url of a 65-byte uncompressed P-256 point
    assert first.startswith("B")  # 0x04 prefix
    assert (await client.get("/push/config")).json()["public_key"] == first

    async with get_sessionmaker()() as db:
        keys = await push_svc.get_vapid_keys(db)
    assert keys.public_key == first
    # The stored private key is usable by py_vapid / pywebpush and matches the public key.
    headers = Vapid.from_string(keys.private_key).sign(
        {"sub": "mailto:admin@localhost", "aud": "https://push.example.com"}
    )
    assert "authorization" in {k.lower() for k in headers}
    assert web_push._public_from_private(keys.private_key) == first


async def test_vapid_keys_from_env(clean_db: None, monkeypatch: pytest.MonkeyPatch) -> None:
    keys = push_svc.generate_vapid_keys()
    monkeypatch.setattr(web_push, "get_settings", lambda: Settings(vapid_private_key=keys.private_key))
    async with get_sessionmaker()() as db:
        assert await push_svc.get_vapid_keys(db) == keys  # public key derived
        stored = (await db.execute(text("SELECT count(*) FROM app_settings"))).scalar_one()
    assert stored == 0
    monkeypatch.setattr(
        web_push,
        "get_settings",
        lambda: Settings(vapid_private_key=keys.private_key, vapid_public_key="explicit"),
    )
    async with get_sessionmaker()() as db:
        assert (await push_svc.get_vapid_keys(db)).public_key == "explicit"


# --- subscriptions -----------------------------------------------------------------


async def test_subscribe_upserts_by_endpoint(client: httpx.AsyncClient) -> None:
    r = await client.post("/push/subscriptions", json=sub(1))
    assert r.status_code == 201
    created = r.json()
    assert set(created) == {"id", "endpoint", "created_at"}
    assert created["endpoint"] == sub(1)["endpoint"]

    changed = {**sub(1), "keys": {"p256dh": "new", "auth": "new-auth"}}
    again = (await client.post("/push/subscriptions", json=changed)).json()
    assert again["id"] == created["id"]
    async with get_sessionmaker()() as db:
        rows = (await db.execute(select(PushSubscription))).scalars().all()
    assert [(s.p256dh, s.auth, s.user_agent) for s in rows] == [("new", "new-auth", "pytest")]


async def test_subscription_validation(client: httpx.AsyncClient) -> None:
    for body, loc in [
        ({**sub(1), "endpoint": "http://fcm.googleapis.com/x"}, ["body", "endpoint"]),
        ({**sub(1), "endpoint": "not a url"}, ["body", "endpoint"]),
        ({**sub(1), "keys": {"p256dh": "", "auth": "a"}}, ["body", "keys", "p256dh"]),
        ({"endpoint": sub(1)["endpoint"]}, ["body", "keys"]),
    ]:
        r = await client.post("/push/subscriptions", json=body)
        assert r.status_code == 422
        assert [e["loc"] for e in r.json()["errors"]] == [loc], r.json()


async def test_unsubscribe_is_idempotent(client: httpx.AsyncClient) -> None:
    await client.post("/push/subscriptions", json=sub(1))
    for _ in range(2):
        r = await client.post("/push/subscriptions/delete", json={"endpoint": sub(1)["endpoint"]})
        assert r.status_code == 204
    async with get_sessionmaker()() as db:
        assert (await db.execute(select(PushSubscription))).first() is None


async def test_send_test_push(client: httpx.AsyncClient, outbox: list[Sent]) -> None:
    assert (await client.post("/push/test")).json() == {"sent": 0, "failed": 0}
    await client.post("/push/subscriptions", json=sub(1))
    await client.post("/push/subscriptions", json={**sub(2), "endpoint": "https://fcm.googleapis.com/gone"})
    await client.post("/push/subscriptions", json={**sub(3), "endpoint": "https://fcm.googleapis.com/fail"})
    r = await client.post("/push/test")
    assert r.status_code == 200
    assert r.json() == {"sent": 1, "failed": 2}
    assert len(outbox) == 1
    assert outbox[0].payload == {
        "title": "quickR",
        "body": "Test notification: push is working.",
        "url": "/",
        "tag": "test",
        "topic_slug": None,
    }
    assert outbox[0].claims == {"sub": "https://github.com/Richard-Lynch/quickr"}
    public = (await client.get("/push/config")).json()["public_key"]
    signer = outbox[0].private_key
    assert isinstance(signer, Vapid)
    raw = signer.public_key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    assert base64.urlsafe_b64encode(raw).rstrip(b"=").decode() == public
    # Regression: the default https:// subject has a path, which py_vapid's strict check
    # rejected ("Missing 'sub' from claims"), so every real send failed.
    headers = signer.sign({**outbox[0].claims, "aud": "https://fcm.googleapis.com"})
    assert "authorization" in {k.lower() for k in headers}

    async with get_sessionmaker()() as db:
        rows = {s.endpoint: s for s in (await db.execute(select(PushSubscription))).scalars()}
    assert "https://fcm.googleapis.com/gone" not in rows  # 404/410 -> deleted
    assert rows["https://fcm.googleapis.com/fail"].failure_count == 1
    assert rows[sub(1)["endpoint"]].last_success_at is not None


class _Response:
    def __init__(self, status_code: int) -> None:
        self.status_code = status_code
        self.text = "nope"


@pytest.mark.parametrize(
    ("status", "error"), [(404, push_svc.PushGone), (410, push_svc.PushGone), (500, push_svc.PushFailed)]
)
def test_deliver_maps_push_service_errors(
    monkeypatch: pytest.MonkeyPatch, status: int, error: type[Exception]
) -> None:
    calls: list[dict[str, Any]] = []

    def fake_webpush(**kwargs: Any) -> None:
        calls.append(kwargs)
        raise WebPushException("failed", response=_Response(status))

    monkeypatch.setattr(web_push, "webpush", fake_webpush)
    monkeypatch.setattr(web_push, "ensure_public", lambda host: None)
    claims: dict[str, str | int] = {"sub": "mailto:a@b"}
    with pytest.raises(error):
        web_push.deliver({"endpoint": "https://fcm.googleapis.com/x"}, "{}", "key", claims, 60)
    assert calls[0]["ttl"] == 60
    assert calls[0]["vapid_claims"] == claims
    assert calls[0]["vapid_claims"] is not claims  # pywebpush mutates claims; never share them
    assert isinstance(calls[0]["requests_session"], web_push._NoRedirectSession)


# --- scheduler -----------------------------------------------------------------------


async def _tick(now: datetime) -> int:
    async with get_sessionmaker()() as db:
        return await scheduler.tick(db, now=now)


async def test_tick_notifies_once_per_due_slot(client: httpx.AsyncClient, outbox: list[Sent]) -> None:
    await client.post("/push/subscriptions", json=sub(1))
    await client.post("/push/subscriptions", json=sub(2))
    t = await make_topic(
        client, "Water", QUESTIONS, schedule={"kind": "interval", "every_minutes": 60, "timezone": "UTC"}
    )
    await backdate_schedule("water", datetime.now(UTC) - timedelta(days=1))
    last = datetime.now(UTC) - timedelta(minutes=30)
    await record(client, "water", {"n": 1}, captured_at=last.isoformat())
    before = (await client.get("/topics/water")).json()

    now = datetime.now(UTC)
    assert await _tick(now) == 0  # not due yet
    assert outbox == []

    due_at = last + timedelta(minutes=60)
    assert await _tick(due_at + timedelta(minutes=1)) == 1
    assert sorted(s.endpoint for s in outbox) == [sub(1)["endpoint"], sub(2)["endpoint"]]
    assert outbox[0].payload == {
        "title": "Water",
        "body": "Time to log",
        "url": "/t/water/record",
        "tag": f"due-{t['id']}",
        "topic_slug": "water",
    }
    assert outbox[0].ttl == push_svc.DEFAULT_TTL_SECONDS

    # Same slot: no repeats, however many ticks.
    assert await _tick(due_at + timedelta(minutes=2)) == 0
    assert await _tick(due_at + timedelta(hours=5)) == 0
    assert len(outbox) == 2

    # Notifying is not an edit.
    after = (await client.get("/topics/water")).json()
    assert after["updated_at"] == before["updated_at"]

    # A new entry starts a new interval -> one more notification when that one is due.
    await record(client, "water", {"n": 2}, captured_at=due_at.isoformat())
    assert await _tick(due_at + timedelta(minutes=61)) == 1
    assert len(outbox) == 4


async def test_tick_overdue_message_and_daily_slots(client: httpx.AsyncClient, outbox: list[Sent]) -> None:
    await client.post("/push/subscriptions", json=sub(1))
    await make_topic(
        client, "Meds", QUESTIONS, schedule={"kind": "daily", "times": ["08:00", "20:00"], "timezone": "UTC"}
    )
    day = datetime(2026, 6, 1, tzinfo=UTC)
    await backdate_schedule("meds", day - timedelta(days=1))
    assert await _tick(day.replace(hour=11)) == 1  # first tick long after the slot
    assert outbox[-1].payload["body"] == "Overdue since 08:00"
    assert await _tick(day.replace(hour=12)) == 0
    assert await _tick(day.replace(hour=20, minute=1)) == 1  # next slot
    assert outbox[-1].payload["body"] == "Time to log"
    assert len(outbox) == 2


async def test_tick_skips_archived_unscheduled_and_silent(
    client: httpx.AsyncClient, outbox: list[Sent]
) -> None:
    await client.post("/push/subscriptions", json=sub(1))
    interval = {"kind": "interval", "every_minutes": 15, "timezone": "UTC"}
    await make_topic(client, "Archived", QUESTIONS, schedule=interval)
    await client.post("/topics/archived/archive")
    await make_topic(client, "Silent", QUESTIONS, schedule={**interval, "notify": False})
    await make_topic(client, "Plain", QUESTIONS)
    await make_topic(client, "Loud", QUESTIONS, schedule=interval)
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 1
    assert [s.payload["topic_slug"] for s in outbox] == ["loud"]


async def test_tick_without_subscriptions_still_marks_slot(
    client: httpx.AsyncClient, outbox: list[Sent]
) -> None:
    await make_topic(
        client, "Loud", QUESTIONS, schedule={"kind": "interval", "every_minutes": 15, "timezone": "UTC"}
    )
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 1
    await client.post("/push/subscriptions", json=sub(1))
    assert await _tick(later) == 0  # the stale slot is not re-sent to a new subscriber
    assert outbox == []


async def test_tick_removes_gone_subscriptions(client: httpx.AsyncClient, outbox: list[Sent]) -> None:
    await client.post("/push/subscriptions", json={**sub(1), "endpoint": "https://fcm.googleapis.com/gone"})
    await client.post("/push/subscriptions", json=sub(2))
    await make_topic(
        client, "Loud", QUESTIONS, schedule={"kind": "interval", "every_minutes": 15, "timezone": "UTC"}
    )
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 1
    async with get_sessionmaker()() as db:
        endpoints = (await db.execute(select(PushSubscription.endpoint))).scalars().all()
        notified = (await db.execute(select(Topic.last_notified_due_since))).scalar_one()
    assert endpoints == [sub(2)["endpoint"]]
    assert notified is not None


async def test_tick_skips_when_lock_is_held(client: httpx.AsyncClient, outbox: list[Sent]) -> None:
    await client.post("/push/subscriptions", json=sub(1))
    await make_topic(
        client, "Loud", QUESTIONS, schedule={"kind": "interval", "every_minutes": 15, "timezone": "UTC"}
    )
    later = datetime.now(UTC) + timedelta(hours=1)
    async with get_engine().connect() as other:
        await other.execute(text("SELECT pg_advisory_lock(:id)"), {"id": scheduler.ADVISORY_LOCK_ID})
        try:
            assert await _tick(later) == 0
        finally:
            await other.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": scheduler.ADVISORY_LOCK_ID})
    assert outbox == []
    assert await _tick(later) == 1


async def test_run_forever_survives_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = 0
    third_call = asyncio.Event()

    async def flaky(db: AsyncSession, *, now: datetime | None = None) -> int:
        nonlocal calls
        calls += 1
        if calls >= 3:
            third_call.set()
        raise RuntimeError("boom")

    monkeypatch.setattr(scheduler, "tick", flaky)
    task = asyncio.create_task(scheduler.run_forever(0.01))
    await asyncio.wait_for(third_call.wait(), 2)
    assert not task.done()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task


async def test_lifespan_starts_and_stops_scheduler(monkeypatch: pytest.MonkeyPatch) -> None:
    started = asyncio.Event()
    stopped = asyncio.Event()

    async def fake_run(interval: float) -> None:
        assert interval == 5
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            stopped.set()

    monkeypatch.setattr(scheduler, "run_forever", fake_run)
    monkeypatch.setattr(
        scheduler, "get_settings", lambda: Settings(scheduler_enabled=True, scheduler_interval_seconds=5)
    )
    async with scheduler.lifespan(None):
        await asyncio.wait_for(started.wait(), 1)
    assert stopped.is_set()

    monkeypatch.setattr(scheduler, "get_settings", lambda: Settings(scheduler_enabled=False))
    started.clear()
    async with scheduler.lifespan(None):
        await asyncio.sleep(0)
    assert not started.is_set()


# --- SSRF guard -------------------------------------------------------------------------


@pytest.mark.parametrize(
    "endpoint",
    [
        "https://fcm.googleapis.com/fcm/send/abc",
        "https://FCM.googleapis.com./fcm/send/abc",  # case + trailing dot
        "https://updates.push.services.mozilla.com/wpush/v2/abc",
        "https://web.push.apple.com/QK1x",
        "https://wns2-par02p.notify.windows.com/w/?token=abc",
        "https://fcm.googleapis.com:443/fcm/send/abc",
    ],
)
def test_allowlist_accepts_push_services(endpoint: str) -> None:
    assert push_guard.check_endpoint(endpoint)


@pytest.mark.parametrize(
    ("endpoint", "message"),
    [
        ("https://evil.example.com/x", "is not a known push service"),
        ("https://fcm.googleapis.com.evil.com/x", "is not a known push service"),
        ("https://notfcm.googleapis.com/x", "is not a known push service"),
        ("https://storage.googleapis.com/x", "is not a known push service"),
        ("https://localhost/x", "is not a known push service"),
        ("https://127.0.0.1/x", "is not a known push service"),
        ("https://[::1]/x", "is not a known push service"),
        ("https://fcm.googleapis.com:8443/x", "custom port"),
        ("https://user:pw@fcm.googleapis.com/x", "credentials"),
        ("http://fcm.googleapis.com/x", "https://"),
        ("https://fcm.googleapis.com:99999/x", "valid https:// URL"),
    ],
)
def test_allowlist_rejects(endpoint: str, message: str) -> None:
    with pytest.raises(push_guard.PushEndpointRejected, match=re.escape(message)):
        push_guard.check_endpoint(endpoint)


async def test_subscribe_rejects_unknown_hosts(client: httpx.AsyncClient) -> None:
    r = await client.post(
        "/push/subscriptions", json={**sub(1), "endpoint": "https://169.254.169.254/latest"}
    )
    assert r.status_code == 422
    assert r.json()["errors"] == [
        {
            "loc": ["body", "endpoint"],
            "message": "host '169.254.169.254' is not a known push service "
            "(set QUICKR_PUSH_ALLOWED_HOSTS to allow it)",
        }
    ]


def test_allowlist_is_extendable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        push_guard, "get_settings", lambda: Settings(push_allowed_hosts=["Push.Example.org."])
    )
    assert push_guard.check_endpoint("https://a.push.example.org/x") == "a.push.example.org"
    assert push_guard.check_endpoint("https://fcm.googleapis.com/x")  # defaults still apply
    with pytest.raises(push_guard.PushEndpointRejected):
        push_guard.check_endpoint("https://example.org/x")


def _resolve_to(monkeypatch: pytest.MonkeyPatch, *addresses: str) -> None:
    def fake_getaddrinfo(host: str, port: int, *args: Any, **kwargs: Any) -> list[Any]:
        return [
            (socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port))
            for a in addresses
        ]

    monkeypatch.setattr(socket, "getaddrinfo", fake_getaddrinfo)


@pytest.mark.parametrize(
    "addresses",
    [
        ("127.0.0.1",),
        ("10.1.2.3",),
        ("172.16.0.5",),
        ("192.168.1.10",),
        ("169.254.169.254",),
        ("100.64.0.1",),  # carrier-grade NAT
        ("0.0.0.0",),
        ("::1",),
        ("fd00::1",),
        ("fe80::1%en0",),
        ("::ffff:127.0.0.1",),
        ("142.250.1.1", "10.0.0.1"),  # any private address taints the host
    ],
)
def test_ensure_public_refuses_private_addresses(
    monkeypatch: pytest.MonkeyPatch, addresses: tuple[str, ...]
) -> None:
    _resolve_to(monkeypatch, *addresses)
    with pytest.raises(push_guard.PushEndpointRejected, match="non-public address"):
        push_guard.ensure_public("fcm.googleapis.com")


def test_ensure_public_accepts_global_and_handles_dns_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    _resolve_to(monkeypatch, "142.250.1.1", "2a00:1450:4009::200a")
    push_guard.ensure_public("fcm.googleapis.com")

    def broken(*args: Any, **kwargs: Any) -> list[Any]:
        raise socket.gaierror("nope")

    monkeypatch.setattr(socket, "getaddrinfo", broken)
    with pytest.raises(push_guard.PushEndpointRejected, match="cannot resolve"):
        push_guard.ensure_public("fcm.googleapis.com")


def test_deliver_refuses_private_ip_without_sending(monkeypatch: pytest.MonkeyPatch) -> None:
    sent: list[Any] = []
    monkeypatch.setattr(web_push, "webpush", lambda **kw: sent.append(kw))
    _resolve_to(monkeypatch, "10.0.0.5")
    with pytest.raises(push_svc.PushFailed, match="non-public"):
        web_push.deliver({"endpoint": "https://fcm.googleapis.com/x"}, "{}", "key", {"sub": "mailto:a@b"}, 60)
    assert sent == []


def test_deliver_drops_endpoints_no_longer_allowed(monkeypatch: pytest.MonkeyPatch) -> None:
    sent: list[Any] = []
    monkeypatch.setattr(web_push, "webpush", lambda **kw: sent.append(kw))
    with pytest.raises(push_svc.PushGone, match="no longer allowed"):
        web_push.deliver({"endpoint": "https://internal.local/x"}, "{}", "key", {"sub": "mailto:a@b"}, 60)
    assert sent == []


def test_no_redirect_session(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[dict[str, Any]] = []

    def fake_request(self: requests.Session, *args: Any, **kwargs: Any) -> Any:
        seen.append(kwargs)
        return "response"

    monkeypatch.setattr(requests.Session, "request", fake_request)
    session = web_push._NoRedirectSession()
    result: Any = session.post("https://fcm.googleapis.com/x", data=b"", allow_redirects=True)
    assert result == "response"
    assert seen[0]["allow_redirects"] is False
