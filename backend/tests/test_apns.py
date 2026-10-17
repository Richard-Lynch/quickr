"""APNs: the sender (over a fake APNs), device registration, and fan-out with Web Push."""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db import get_sessionmaker
from app.models import ApnsDevice, PushSubscription, Topic
from app.services import push as push_svc
from app.services import scheduler
from app.services.push import apns
from app.services.push import web as web_push
from app.services.push.apns import ApnsConfig, ApnsSender, ProviderToken, SigningKey
from tests.fake_apns import KEY_ID, TEAM_ID, TOPIC, FakeApns, new_key, token
from tests.helpers import make_topic

DUE = push_svc.Notification(
    kind="due",
    title="Water",
    body="Time to log",
    url="/t/water/record",
    tag="due-6f1c0000-0000-4000-8000-000000000001",
    topic_slug="water",
)
QUESTIONS = [{"key": "n", "label": "N", "type": "int"}]
INTERVAL = {"kind": "interval", "every_minutes": 15, "timezone": "UTC"}
WEB_SUB = {
    "endpoint": "https://fcm.googleapis.com/fcm/send/1",
    "keys": {"p256dh": "p256dh-1", "auth": "auth-1"},
}


def device(n: int = 1, **extra: Any) -> dict[str, Any]:
    return {"token": token(n), "environment": "sandbox", **extra}


@pytest.fixture
def web_outbox(monkeypatch: pytest.MonkeyPatch) -> list[dict[str, Any]]:
    """Web Push delivery mocked: endpoints ending in /fail fail."""
    sent: list[dict[str, Any]] = []

    def fake_deliver(subscription: dict[str, Any], data: str, *_: Any) -> None:
        if subscription["endpoint"].endswith("/fail"):
            raise push_svc.PushFailed("500")
        sent.append({"endpoint": subscription["endpoint"], **json.loads(data)})

    monkeypatch.setattr(web_push, "deliver", fake_deliver)
    return sent


async def _devices() -> dict[str, ApnsDevice]:
    async with get_sessionmaker()() as db:
        return {d.token: d for d in (await db.execute(select(ApnsDevice))).scalars()}


# --- the request ---------------------------------------------------------------------------


async def test_request_path_headers_and_provider_token(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    apns_id = await sender.post(token(1), "production", DUE, 3600)
    await sender.post(token(2), "sandbox", DUE, 60)
    assert apns_id == "apns-1"

    prod, sandbox = fake_apns.sent
    assert (prod.host, prod.path) == ("api.push.apple.com", f"/3/device/{token(1)}")
    assert (sandbox.host, sandbox.path) == ("api.sandbox.push.apple.com", f"/3/device/{token(2)}")
    assert {k: v for k, v in prod.headers.items() if k.startswith("apns-")} == {
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int(fake_apns.now) + 3600),
        "apns-collapse-id": DUE.tag,
    }
    assert sandbox.headers["apns-expiration"] == str(int(fake_apns.now) + 60)

    bearer = prod.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(bearer) == {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    assert prod.claims(fake_apns.key) == {"iss": TEAM_ID, "iat": int(fake_apns.now)}
    other, _ = new_key()
    with pytest.raises(jwt.InvalidSignatureError):
        prod.claims(other)
    # One key: both hosts share the cached token.
    assert sandbox.headers["authorization"] == prod.headers["authorization"]


async def test_payload_renders_the_notification(fake_apns: FakeApns) -> None:
    await fake_apns.sender().post(token(1), "sandbox", DUE, 60)
    assert fake_apns.sent[0].body == {
        "aps": {"alert": {"title": "Water", "body": "Time to log"}, "sound": "default"},
        "quickr": {"v": 1, "kind": "due", "url": "/t/water/record", "topic_slug": "water"},
    }
    assert "badge" not in fake_apns.sent[0].body["aps"]


async def test_worst_case_payload_fits_in_4096_bytes(fake_apns: FakeApns) -> None:
    worst = push_svc.Notification(
        kind="due",
        title="🌊" * 200,  # the longest topic name, 4 bytes a character
        body="Overdue since 23:59",
        url="/t/" + "a" * 64 + "/record",
        tag="due-6f1c0000-0000-4000-8000-000000000001",
        topic_slug="a" * 64,
    )
    await fake_apns.sender().post(token(1), "sandbox", worst, 60)
    sent = fake_apns.sent[0]
    assert sent.size <= apns.MAX_PAYLOAD_BYTES
    title = sent.body["aps"]["alert"]["title"]
    assert len(title) == 120
    assert title == "🌊" * 119 + "…"


async def test_oversized_payload_is_never_sent(fake_apns: FakeApns, caplog: pytest.LogCaptureFixture) -> None:
    huge = push_svc.Notification(kind="test", title="x", body="b" * 5000, url="/", tag="test")
    with caplog.at_level(logging.ERROR, logger=apns.__name__), pytest.raises(push_svc.PushFailed):
        await fake_apns.sender().post(token(1), "sandbox", huge, 60)
    assert fake_apns.sent == []
    assert "over the 4096 limit" in caplog.text


# --- responses --------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("status", "reason", "error", "logged_as_error"),
    [
        (410, "Unregistered", push_svc.PushGone, False),
        (410, "ExpiredToken", push_svc.PushGone, False),
        (400, "BadDeviceToken", push_svc.PushGone, False),
        (400, "DeviceTokenNotForTopic", push_svc.PushFailed, True),
        (400, "PayloadTooLarge", push_svc.PushFailed, True),
        (400, "BadCollapseId", push_svc.PushFailed, True),
        (400, "MissingTopic", push_svc.PushFailed, True),
        (413, "PayloadTooLarge", push_svc.PushFailed, True),
        (403, "InvalidProviderToken", push_svc.PushFailed, False),
        (429, "TooManyRequests", push_svc.PushFailed, False),
        (500, "InternalServerError", push_svc.PushFailed, False),
        (503, "ServiceUnavailable", push_svc.PushFailed, False),
    ],
)
async def test_error_map(
    fake_apns: FakeApns,
    caplog: pytest.LogCaptureFixture,
    status: int,
    reason: str,
    error: type[Exception],
    logged_as_error: bool,
) -> None:
    fake_apns.replies[token(1)] = [(status, reason)]
    with caplog.at_level(logging.ERROR, logger=apns.__name__), pytest.raises(error, match=reason):
        await fake_apns.sender().post(token(1), "sandbox", DUE, 60)
    assert len(fake_apns.sent) == 1  # never retried
    assert bool(caplog.records) == logged_as_error


async def test_transport_errors_are_failures(fake_apns: FakeApns) -> None:
    fake_apns.raises[token(1)] = httpx.ConnectTimeout("slow")
    with pytest.raises(push_svc.PushFailed, match="ConnectTimeout"):
        await fake_apns.sender().post(token(1), "sandbox", DUE, 60)


async def test_provider_token_is_cached_for_50_minutes(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    start = fake_apns.now
    for minutes in (0, 20, 49):
        fake_apns.now = start + minutes * 60
        await sender.post(token(1), "sandbox", DUE, 60)
    fake_apns.now = start + 50 * 60
    await sender.post(token(1), "sandbox", DUE, 60)
    tokens = [s.headers["authorization"] for s in fake_apns.sent]
    assert tokens[0] == tokens[1] == tokens[2] != tokens[3]
    assert [s.claims(fake_apns.key)["iat"] for s in fake_apns.sent] == [int(start)] * 3 + [
        int(start) + 50 * 60
    ]


async def test_expired_provider_token_is_renewed_once(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    await sender.post(token(2), "sandbox", DUE, 60)  # signs the token at "now"
    fake_apns.now += 21 * 60
    fake_apns.replies[token(1)] = [(403, "ExpiredProviderToken"), (200, "")]
    assert await sender.post(token(1), "sandbox", DUE, 60) == "apns-3"
    first, retry = fake_apns.sent[1:]
    assert first.headers["authorization"] != retry.headers["authorization"]
    assert retry.claims(fake_apns.key)["iat"] == int(fake_apns.now)

    # Rejected again: one retry only.
    fake_apns.now += 21 * 60
    fake_apns.replies[token(1)] = [(403, "ExpiredProviderToken")]
    with pytest.raises(push_svc.PushFailed, match="ExpiredProviderToken"):
        await sender.post(token(1), "sandbox", DUE, 60)
    assert len(fake_apns.sent) == 5


async def test_expired_provider_token_younger_than_20_minutes_is_not_resigned(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    fake_apns.replies[token(1)] = [(403, "ExpiredProviderToken")]
    fake_apns.now += 19 * 60  # (the token is signed on this first send)
    with pytest.raises(push_svc.PushFailed):
        await sender.post(token(1), "sandbox", DUE, 60)
    assert len(fake_apns.sent) == 1  # re-signing now would hit TooManyProviderTokenUpdates


def test_renew_uses_a_token_another_request_already_renewed() -> None:
    now = [1_800_000_000.0]
    _, pem = new_key()
    provider = ProviderToken(TEAM_ID, SigningKey(KEY_ID, pem), clock=lambda: now[0])
    old = provider.get()
    now[0] += 21 * 60
    assert provider.renew(old)
    new = provider.get()
    assert new != old
    assert provider.renew(old)  # a concurrent request rejected with the old one: just retry
    assert provider.get() == new
    assert not provider.renew(new)  # too young to re-sign


async def test_separate_sandbox_key(fake_apns: FakeApns) -> None:
    sandbox_private, sandbox_pem = new_key()
    sender = fake_apns.sender(sandbox_key=SigningKey("SANDBOXKEY", sandbox_pem))
    await sender.post(token(1), "production", DUE, 60)
    await sender.post(token(1), "sandbox", DUE, 60)
    prod, sandbox = fake_apns.sent
    assert jwt.get_unverified_header(prod.headers["authorization"][7:])["kid"] == KEY_ID
    assert jwt.get_unverified_header(sandbox.headers["authorization"][7:])["kid"] == "SANDBOXKEY"
    assert sandbox.claims(sandbox_private)["iss"] == TEAM_ID


async def test_clients_are_per_host_and_closed(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    await sender.post(token(1), "sandbox", DUE, 60)
    await sender.post(token(1), "sandbox", DUE, 60)
    await sender.post(token(1), "production", DUE, 60)
    clients = dict(sender._clients)
    assert set(clients) == {"sandbox", "production"}
    await sender.aclose()
    assert all(c.is_closed for c in clients.values())
    assert sender._clients == {}


# --- configuration ---------------------------------------------------------------------------


def test_config_is_off_unless_complete(caplog: pytest.LogCaptureFixture) -> None:
    _, pem = new_key()
    assert ApnsConfig.from_settings(Settings()) is None
    assert not caplog.records
    with caplog.at_level(logging.WARNING):
        assert ApnsConfig.from_settings(Settings(apns_team_id=TEAM_ID, apns_private_key=pem)) is None
    assert "partly configured" in caplog.text

    config = ApnsConfig.from_settings(
        Settings(apns_team_id=TEAM_ID, apns_key_id=KEY_ID, apns_private_key=pem.replace("\n", "\\n"))
    )
    assert config is not None
    assert config.topic == "com.bahumia.quickr"
    assert config.keys["production"] == config.keys["sandbox"] == SigningKey(KEY_ID, pem)


def test_config_reads_key_files(tmp_path: Path) -> None:
    _, pem = new_key()
    _, sandbox_pem = new_key()
    (tmp_path / "prod.p8").write_text(pem)
    (tmp_path / "sandbox.p8").write_text(sandbox_pem)
    config = ApnsConfig.from_settings(
        Settings(
            apns_team_id=TEAM_ID,
            apns_key_id=KEY_ID,
            apns_private_key_file=str(tmp_path / "prod.p8"),
            apns_sandbox_key_id="SANDBOXKEY",
            apns_sandbox_private_key_file=str(tmp_path / "sandbox.p8"),
            apns_topic="com.example.app",
        )
    )
    assert config is not None
    assert config.topic == "com.example.app"
    assert config.keys == {
        "production": SigningKey(KEY_ID, pem),
        "sandbox": SigningKey("SANDBOXKEY", sandbox_pem),
    }
    ApnsSender(config)  # the keys load


def _rsa_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()


@pytest.mark.parametrize(
    ("pem", "path"),
    [("not a key", None), (None, "/nonexistent/AuthKey.p8"), ("rsa", None)],
    ids=["garbage", "missing-file", "not-p256"],
)
def test_unloadable_key_turns_apns_off(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture, pem: str | None, path: str | None
) -> None:
    settings = Settings(
        apns_team_id=TEAM_ID,
        apns_key_id=KEY_ID,
        apns_private_key=_rsa_pem() if pem == "rsa" else pem,
        apns_private_key_file=path,
    )
    monkeypatch.setattr(apns, "get_settings", lambda: settings)
    monkeypatch.setattr(apns._Holder, "loaded", False)
    monkeypatch.setattr(apns._Holder, "sender", None)
    with caplog.at_level(logging.ERROR):
        assert apns.get_sender() is None
    assert "APNs is configured but its key can't be loaded" in caplog.text


async def test_get_sender_is_cached_and_closed_by_the_lifespan(monkeypatch: pytest.MonkeyPatch) -> None:
    _, pem = new_key()
    monkeypatch.setattr(
        apns, "get_settings", lambda: Settings(apns_team_id=TEAM_ID, apns_key_id=KEY_ID, apns_private_key=pem)
    )
    monkeypatch.setattr(apns._Holder, "loaded", False)
    monkeypatch.setattr(apns._Holder, "sender", None)
    async with apns.lifespan(None):
        sender = apns.get_sender()
        assert sender is not None
        assert apns.get_sender() is sender
        client = sender._client("sandbox")
    assert client.is_closed
    assert apns._Holder.sender is None


async def test_push_config_reports_apns(client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch) -> None:
    assert (await client.get("/push/config")).json()["apns_enabled"] is False
    sender = FakeApns.create().sender()
    monkeypatch.setattr(apns, "get_sender", lambda: sender)
    assert (await client.get("/push/config")).json()["apns_enabled"] is True


# --- registration ------------------------------------------------------------------------------


async def test_register_upserts_by_token(client: httpx.AsyncClient) -> None:
    upper = token(0xABC).upper()
    body = {**device(), "token": upper, "app_version": "1.0 (3)", "device_name": "Richie's iPhone"}
    r = await client.post("/push/apns/devices", json={**body, "bundle_id": "com.bahumia.quickr"})
    assert r.status_code == 201, r.text
    created = r.json()
    assert set(created) == {
        "id",
        "token",
        "environment",
        "bundle_id",
        "app_version",
        "device_name",
        "created_at",
        "updated_at",
    }
    assert created["token"] == upper.lower()
    assert (created["environment"], created["app_version"]) == ("sandbox", "1.0 (3)")

    async with get_sessionmaker()() as db:
        await db.execute(update(ApnsDevice).values(failure_count=7))
        await db.commit()
    again = await client.post(
        "/push/apns/devices",
        json={**body, "token": upper.lower(), "environment": "production", "app_version": ""},
    )
    assert again.status_code == 201
    assert again.json()["id"] == created["id"]
    assert again.json()["updated_at"] >= created["updated_at"]
    (stored,) = (await _devices()).values()
    assert (stored.environment, stored.app_version, stored.bundle_id, stored.failure_count) == (
        "production",
        None,
        None,
        0,
    )


@pytest.mark.parametrize(
    ("body", "loc"),
    [
        ({**device(), "token": "abc"}, ["body", "token"]),
        ({**device(), "token": "g" * 64}, ["body", "token"]),
        ({**device(), "token": "a" * 201}, ["body", "token"]),
        ({**device(), "environment": "development"}, ["body", "environment"]),
        ({"token": token(1)}, ["body", "environment"]),
        ({**device(), "app_version": "x" * 65}, ["body", "app_version"]),
        ({**device(), "device_name": "x" * 201}, ["body", "device_name"]),
        ({**device(), "bundle_id": "com.example/app"}, ["body", "bundle_id"]),
        ({**device(), "extra": 1}, ["body", "extra"]),
    ],
)
async def test_register_validation(client: httpx.AsyncClient, body: dict[str, Any], loc: list[str]) -> None:
    r = await client.post("/push/apns/devices", json=body)
    assert r.status_code == 422
    assert [e["loc"] for e in r.json()["errors"]] == [loc], r.json()


async def test_unregister_is_idempotent(client: httpx.AsyncClient) -> None:
    await client.post("/push/apns/devices", json=device(1))
    await client.post("/push/apns/devices", json=device(2))
    for _ in range(2):
        r = await client.post("/push/apns/devices/delete", json={"token": token(1).upper()})
        assert r.status_code == 204
    assert list(await _devices()) == [token(2)]
    r = await client.post("/push/apns/devices/delete", json={"token": "nope"})
    assert r.status_code == 422


# --- test pushes ---------------------------------------------------------------------------------


async def test_test_this_device(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    await client.post("/push/apns/devices", json=device(1))
    await client.post("/push/apns/devices", json=device(2))
    r = await client.post("/push/apns/devices/test", json={"token": token(1)})
    assert (r.status_code, r.json()) == (200, {"sent": 1, "failed": 0})
    assert [s.device for s in fake_apns.sent] == [token(1)]
    assert fake_apns.sent[0].headers["apns-collapse-id"] == "test"
    assert fake_apns.sent[0].body == {
        "aps": {
            "alert": {"title": "quickR", "body": "Test notification: push is working."},
            "sound": "default",
        },
        "quickr": {"v": 1, "kind": "test", "url": "/", "topic_slug": None},
    }
    devices = await _devices()
    assert devices[token(1)].last_success_at is not None
    assert devices[token(2)].last_success_at is None

    fake_apns.replies[token(2)] = [(410, "Unregistered")]
    r = await client.post("/push/apns/devices/test", json={"token": token(2)})
    assert r.json() == {"sent": 0, "failed": 1}
    assert list(await _devices()) == [token(1)]

    r = await client.post("/push/apns/devices/test", json={"token": token(2)})
    assert (r.status_code, r.json()["code"]) == (404, "not_found")


async def test_test_this_device_when_apns_is_off(client: httpx.AsyncClient) -> None:
    await client.post("/push/apns/devices", json=device(1))  # registering works anyway
    r = await client.post("/push/apns/devices/test", json={"token": token(1)})
    assert (r.status_code, r.json()["code"]) == (409, "apns_disabled")


async def test_test_push_fans_out_to_every_channel(
    client: httpx.AsyncClient, fake_apns: FakeApns, web_outbox: list[dict[str, Any]]
) -> None:
    await client.post("/push/subscriptions", json=WEB_SUB)
    await client.post("/push/apns/devices", json=device(1))
    await client.post("/push/apns/devices", json={**device(2), "environment": "production"})
    fake_apns.replies[token(2)] = [(500, "InternalServerError")]
    r = await client.post("/push/test")
    assert r.json() == {"sent": 2, "failed": 1}
    assert [s["endpoint"] for s in web_outbox] == [WEB_SUB["endpoint"]]
    assert sorted(s.device for s in fake_apns.sent) == [token(1), token(2)]
    assert (await _devices())[token(2)].failure_count == 1


# --- scheduler -------------------------------------------------------------------------------------


async def _tick(now: datetime, db: AsyncSession | None = None) -> int:
    if db is not None:
        return await scheduler.tick(db, now=now)
    async with get_sessionmaker()() as session:
        return await scheduler.tick(session, now=now)


async def test_tick_sends_one_notification_to_each_web_and_apns_target(
    client: httpx.AsyncClient, fake_apns: FakeApns, web_outbox: list[dict[str, Any]]
) -> None:
    await client.post("/push/subscriptions", json=WEB_SUB)
    await client.post("/push/apns/devices", json=device(1))
    topic = await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 1
    assert await _tick(later + timedelta(minutes=1)) == 0  # same slot

    assert len(web_outbox) == 1
    assert web_outbox[0]["tag"] == f"due-{topic['id']}"
    assert len(fake_apns.sent) == 1
    (sent,) = fake_apns.sent
    assert sent.device == token(1)
    assert sent.host == "api.sandbox.push.apple.com"
    assert sent.headers["apns-collapse-id"] == f"due-{topic['id']}"
    assert sent.body["aps"]["alert"] == {"title": "Water", "body": web_outbox[0]["body"]}
    assert sent.body["quickr"] == {"v": 1, "kind": "due", "url": "/t/water/record", "topic_slug": "water"}


async def test_tick_partial_failure_still_marks_the_slot(
    client: httpx.AsyncClient, fake_apns: FakeApns, web_outbox: list[dict[str, Any]]
) -> None:
    """Best-effort per target: one failing target doesn't hold back the others or the mark."""
    await client.post("/push/subscriptions", json={**WEB_SUB, "endpoint": "https://fcm.googleapis.com/fail"})
    await client.post("/push/apns/devices", json=device(1))
    await client.post("/push/apns/devices", json=device(2))
    fake_apns.replies[token(2)] = [(503, "ServiceUnavailable")]
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 1
    assert await _tick(later) == 0  # no retry for the failed targets
    assert sorted(s.device for s in fake_apns.sent) == [token(1), token(2)]
    devices = await _devices()
    assert (devices[token(1)].failure_count, devices[token(2)].failure_count) == (0, 1)
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(PushSubscription.failure_count))) == 1
        assert (await db.scalar(select(Topic.last_notified_due_since))) is not None


async def test_tick_commit_failure_resends_next_tick(
    client: httpx.AsyncClient, fake_apns: FakeApns, web_outbox: list[dict[str, Any]]
) -> None:
    """Send, then mark: a tick that can't commit leaves the slot unmarked, so it goes out again."""
    await client.post("/push/subscriptions", json=WEB_SUB)
    await client.post("/push/apns/devices", json=device(1))
    topic = await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    later = datetime.now(UTC) + timedelta(hours=1)

    async with get_sessionmaker()() as db:

        async def broken_commit() -> None:
            raise ConnectionError("database went away")

        real_commit = db.commit
        db.commit = broken_commit  # type: ignore[method-assign]
        with pytest.raises(ConnectionError):
            await _tick(later, db)
        db.commit = real_commit  # type: ignore[method-assign]
        await db.rollback()
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(Topic.last_notified_due_since))) is None

    assert await _tick(later) == 1
    assert await _tick(later) == 0
    assert len(web_outbox) == 2  # at least once: the slot went out twice, with one tag
    assert [s.headers["apns-collapse-id"] for s in fake_apns.sent] == [f"due-{topic['id']}"] * 2


async def test_tick_budget_leaves_the_rest_for_the_next_tick(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    await client.post("/push/apns/devices", json=device(1))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    await make_topic(client, "Meds", QUESTIONS, schedule=INTERVAL)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", -1.0)
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 1  # always makes progress
    assert await _tick(later) == 1
    assert await _tick(later) == 0
    assert [s.body["quickr"]["topic_slug"] for s in fake_apns.sent] == ["water", "meds"]


async def test_tick_marks_slots_in_one_statement(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    for name in ("Water", "Meds", "Walk"):
        await make_topic(client, name, QUESTIONS, schedule=INTERVAL)
    before = {t["slug"]: t["updated_at"] for t in (await client.get("/topics")).json()["items"]}
    calls: list[int] = []
    real = scheduler._mark_notified

    async def counting(db: AsyncSession, marks: list[Any]) -> None:
        calls.append(len(marks))
        await real(db, marks)

    monkeypatch.setattr(scheduler, "_mark_notified", counting)
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 3
    assert calls == [3]
    async with get_sessionmaker()() as db:
        marked = (await db.execute(select(Topic.last_notified_due_since))).scalars().all()
    assert len(marked) == 3
    assert all(m is not None for m in marked)
    after = {t["slug"]: t["updated_at"] for t in (await client.get("/topics")).json()["items"]}
    assert after == before  # notifying is not an edit


# --- pruning --------------------------------------------------------------------------------------


async def test_failing_targets_are_pruned_after_20_failures_and_30_silent_days(
    client: httpx.AsyncClient, fake_apns: FakeApns, web_outbox: list[dict[str, Any]]
) -> None:
    long_ago = datetime.now(UTC) - timedelta(days=31)
    recently = datetime.now(UTC) - timedelta(days=29)
    for n in range(1, 5):
        await client.post("/push/apns/devices", json=device(n))
        fake_apns.replies[token(n)] = [(500, "InternalServerError")]
    await client.post("/push/subscriptions", json={**WEB_SUB, "endpoint": "https://fcm.googleapis.com/fail"})
    async with get_sessionmaker()() as db:
        await db.execute(text("UPDATE apns_devices SET failure_count = 19, created_at = :t"), {"t": long_ago})
        # 1: never succeeded, registered 31 days ago -> pruned
        await db.execute(  # 2: last success 31 days ago -> pruned
            update(ApnsDevice).where(ApnsDevice.token == token(2)).values(last_success_at=long_ago)
        )
        await db.execute(  # 3: a success 29 days ago -> kept
            update(ApnsDevice).where(ApnsDevice.token == token(3)).values(last_success_at=recently)
        )
        await db.execute(  # 4: only 10 failures -> kept
            update(ApnsDevice).where(ApnsDevice.token == token(4)).values(failure_count=9)
        )
        await db.execute(  # the web subscription is pruned by the same rule
            update(PushSubscription).values(failure_count=19, created_at=long_ago)
        )
        await db.commit()

    r = await client.post("/push/test")
    assert r.json() == {"sent": 0, "failed": 5}
    devices = await _devices()
    assert sorted(devices) == [token(3), token(4)]
    assert (devices[token(3)].failure_count, devices[token(4)].failure_count) == (20, 10)
    async with get_sessionmaker()() as db:
        assert (await db.execute(select(PushSubscription))).first() is None


async def test_a_success_resets_the_failure_count(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    await client.post("/push/apns/devices", json=device(1))
    async with get_sessionmaker()() as db:
        await db.execute(update(ApnsDevice).values(failure_count=19))
        await db.commit()
    await client.post("/push/apns/devices/test", json={"token": token(1)})
    stored = (await _devices())[token(1)]
    assert stored.failure_count == 0
    assert stored.last_success_at is not None
