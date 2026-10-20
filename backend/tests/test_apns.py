"""APNs: the sender (over a fake APNs), device registration, and fan-out with Web Push."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import httpx
import jwt
import pytest
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from pywebpush import WebPushException
from sqlalchemy import event, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db import get_engine, get_sessionmaker
from app.models import ApnsDevice, PushSlotDelivery, PushSubscription, Topic
from app.schemas.api import QuickLogDescriptor
from app.schemas.questions import DoubleQuestion, EnumOption, EnumQuestion, StrQuestion
from app.services import notification, scheduler
from app.services import push as push_svc
from app.services.push import apns
from app.services.push import web as web_push
from app.services.push.apns import ApnsConfig, ApnsSender, ProviderToken, SigningKey
from tests.fake_apns import KEY_ID, TEAM_ID, TOPIC, FakeApns, new_key, token
from tests.helpers import backdate_schedule, make_topic, record

SERVER_ID = "0b9e0000-0000-4000-8000-0000000000aa"
TOPIC_ID = UUID("6f1c0000-0000-4000-8000-000000000001")
DUE = push_svc.Notification(
    kind="due",
    title="Water",
    body="Time to log",
    url="/t/water/record",
    tag=f"due-{TOPIC_ID}",
    topic_slug="water",
    server_id=SERVER_ID,
    topic_id=TOPIC_ID,
    version=3,
    due_since=datetime(2026, 10, 17, 10, 0, 0, 999999, tzinfo=ZoneInfo("Europe/Berlin")),
)
# The category ids' hashes: they change only with the actions (notifications.md §4.3).
CATEGORY_HASHES = {"enum-3": "ac13c7153ebee78d", "enum-6": "d83ae3e8e449bdf4", "double": "746b872f70e41f41"}
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


def _enum(n: int, *, key: str = "mood", label: str = "Option {i}") -> EnumQuestion:
    options = [EnumOption(value=f"o{i}", label=label.format(i=i)) for i in range(n)]
    return EnumQuestion(key=key, label=key.title(), type="enum", options=options)


def _due(quick_log: QuickLogDescriptor | None, **overrides: Any) -> push_svc.Notification:
    return replace(DUE, quick_log=quick_log, **overrides)


async def _render(fake_apns: FakeApns, n: push_svc.Notification) -> dict[str, Any]:
    await fake_apns.sender().post(token(1), "sandbox", n, 60)
    sent = fake_apns.sent[-1]
    assert sent.size <= apns.MAX_PAYLOAD_BYTES
    assert "badge" not in sent.body["aps"]
    body: dict[str, Any] = sent.body
    return body


QUICKR = {
    "v": 1,
    "kind": "due",
    "server_id": SERVER_ID,
    "topic_id": str(TOPIC_ID),
    "topic_slug": "water",
    "version": 3,
    "due_since": "2026-10-17T08:00:00Z",  # 10:00:00.999999 in Berlin: UTC, whole seconds
    "url": "/t/water/record",
}


async def test_payload_with_up_to_4_options(fake_apns: FakeApns) -> None:
    quick_log = notification.descriptor([_enum(3)], counts={"o2": 9}, last=None)
    assert await _render(fake_apns, _due(quick_log)) == {
        "aps": {
            "alert": {"title": "Water", "body": "Time to log"},
            "sound": "default",
            "thread-id": f"topic-{TOPIC_ID}",
            "category": f"quickr.t.{TOPIC_ID}.{CATEGORY_HASHES['enum-3']}",
            "mutable-content": 1,
            "relevance-score": 0.8,
        },
        "quickr": {
            **QUICKR,
            "quick_log": {
                "type": "enum",
                "key": "mood",
                "label": "Mood",
                "options": [  # all of them, in question order (counts don't matter)
                    {"value": "o0", "label": "Option 0"},
                    {"value": "o1", "label": "Option 1"},
                    {"value": "o2", "label": "Option 2"},
                ],
                "total_options": 3,
            },
        },
    }


async def test_payload_with_6_options_shows_the_3_most_used_and_says_so(fake_apns: FakeApns) -> None:
    quick_log = notification.descriptor([_enum(6)], counts={"o4": 5, "o1": 2, "o3": 2, "o0": 1}, last=None)
    body = await _render(fake_apns, _due(quick_log))
    assert body["aps"]["alert"] == {"title": "Water", "body": "Time to log · 3 of 6 shown, More for all"}
    assert body["aps"]["category"] == f"quickr.t.{TOPIC_ID}.{CATEGORY_HASHES['enum-6']}"
    assert body["quickr"]["quick_log"] == {
        "type": "enum",
        "key": "mood",
        "label": "Mood",
        "options": [  # most-used first; o1 and o3 tie, so question order
            {"value": "o4", "label": "Option 4"},
            {"value": "o1", "label": "Option 1"},
            {"value": "o3", "label": "Option 3"},
        ],
        "total_options": 6,
    }


async def test_payload_for_a_number_with_its_last_value(fake_apns: FakeApns) -> None:
    hours = DoubleQuestion(key="hours", label="Sleep", type="double", unit="h", min=0, max=24, decimals=1)
    body = await _render(fake_apns, _due(notification.descriptor([hours], counts={}, last=7.5)))
    assert body["aps"]["alert"] == {"title": "Water", "body": "Time to log"}
    assert body["aps"]["category"] == f"quickr.t.{TOPIC_ID}.{CATEGORY_HASHES['double']}"
    assert body["quickr"] == {
        **QUICKR,
        "quick_log": {
            "type": "double",
            "key": "hours",
            "label": "Sleep",
            "unit": "h",
            "min": 0,
            "max": 24,
            "decimals": 1,
            "last_value": 7.5,
        },
    }


async def test_payload_for_a_topic_that_cant_be_logged_from_a_notification(fake_apns: FakeApns) -> None:
    note = StrQuestion(key="note", label="Note", type="str")
    assert notification.descriptor([note], counts={}, last=None) is None
    assert await _render(fake_apns, _due(None)) == {
        "aps": {
            "alert": {"title": "Water", "body": "Time to log"},
            "sound": "default",
            "thread-id": f"topic-{TOPIC_ID}",
            "mutable-content": 1,
            "relevance-score": 0.8,
        },
        "quickr": {**QUICKR, "quick_log": None},
    }


@pytest.mark.parametrize(
    ("char", "encoded"),
    [
        ("🌊", 4),  # 4 bytes in UTF-8
        ("\u0001", 6),  # JSON escapes control characters: \u0001
    ],
)
async def test_worst_case_payloads_fit_in_4096_bytes(fake_apns: FakeApns, char: str, encoded: int) -> None:
    """notifications.md §2.2: a 200-character name, 4 options with 63-character values and
    200-character labels, a 64-character key, a 32-character unit, every character as wide
    as JSON can make it."""
    assert len(json.dumps(char, ensure_ascii=False).encode()) == encoded + 2
    key = "k" * 64  # one more than a key can have
    label = char * 200  # the longest label
    options = [EnumOption(value=f"v{i}".ljust(63, "v"), label=label) for i in range(6)]
    widest = [
        EnumQuestion.model_construct(key=key, label=label, type="enum", options=options[:n], multiple=False)
        for n in (4, 6)
    ]
    number = DoubleQuestion.model_construct(
        key=key,
        label=label,
        type="double",
        unit=char * 32,
        min=-1.7976931348623157e308,
        max=None,
        decimals=10,
    )
    descriptors = [notification.descriptor([q], counts={}, last=None) for q in widest]
    descriptors.append(notification.descriptor([number], counts={}, last=-2.2250738585072014e-308))
    for quick_log in descriptors:
        assert quick_log is not None
        worst = _due(
            quick_log,
            title=char * 200,
            body="Overdue since Wed 23:59",
            url="/t/" + "a" * 64 + "/record",
            topic_slug="a" * 64,
        )
        body = await _render(fake_apns, worst)
        assert body["aps"]["alert"]["title"] == char * 119 + "…"
        assert body["quickr"]["quick_log"]["label"] == char * 63 + "…"
        assert "badge" not in body["aps"]
    enum_4 = fake_apns.sent[0]
    assert [o["label"] for o in enum_4.body["quickr"]["quick_log"]["options"]] == [char * 63 + "…"] * 4
    assert max(sent.size for sent in fake_apns.sent) == enum_4.size  # 4 options is the widest


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


@pytest.mark.parametrize(
    "sandbox",
    [
        {"apns_sandbox_key_id": "SANDBOXKEY"},
        {"apns_sandbox_private_key": "pem"},
        {"apns_sandbox_private_key_file": "/x.p8"},
    ],
    ids=["id-only", "pem-only", "file-only"],
)
def test_partial_sandbox_override_is_an_error(sandbox: dict[str, str]) -> None:
    """Never a silent fallback to the default key, which may be limited to production."""
    _, pem = new_key()
    settings = Settings.model_validate(
        {"apns_team_id": TEAM_ID, "apns_key_id": KEY_ID, "apns_private_key": pem, **sandbox}
    )
    with pytest.raises(ValueError, match="QUICKR_APNS_SANDBOX_KEY_ID"):
        ApnsConfig.from_settings(settings)


def test_partial_sandbox_override_turns_apns_off(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    _, pem = new_key()
    settings = Settings(
        apns_team_id=TEAM_ID, apns_key_id=KEY_ID, apns_private_key=pem, apns_sandbox_key_id="S"
    )
    monkeypatch.setattr(apns, "get_settings", lambda: settings)
    monkeypatch.setattr(apns._Holder, "loaded", False)
    monkeypatch.setattr(apns._Holder, "sender", None)
    with caplog.at_level(logging.ERROR):
        assert apns.get_sender() is None
    assert "sandbox key override" in caplog.text


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
        "aps": {  # no thread-id, no category
            "alert": {"title": "quickR", "body": "Test notification: push is working."},
            "sound": "default",
            "mutable-content": 1,
            "relevance-score": 0.8,
        },
        "quickr": {
            "v": 1,
            "kind": "test",
            "server_id": None,
            "topic_id": None,
            "topic_slug": None,
            "version": None,
            "due_since": None,
            "url": "/",
            "quick_log": None,
        },
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


# A tick budget the answered sends and the tick's queries fit in with room to spare on a
# loaded machine. The fake's quota decides which sends a tick cuts off, not wall time.
BUDGET = 1.0


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
    assert sent.body["aps"]["thread-id"] == f"topic-{topic['id']}"
    # The same fields on both channels.
    assert sent.body["quickr"] == {k: v for k, v in web_outbox[0].items() if k in sent.body["quickr"]}
    assert sent.body["quickr"]["topic_id"] == topic["id"]
    assert sent.body["quickr"]["quick_log"]["type"] == "int"


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


async def test_tick_budget_bounds_delivery(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The budget cuts delivery off mid-topic (here in its third batch of 8). The slot stays
    unmarked, the targets reached are recorded, and the next tick sends to the rest only."""
    for n in range(20):
        await client.post("/push/apns/devices", json=device(n))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    fake_apns.delay = 0.05  # a whole batch is in flight at once
    fake_apns.allow(16)  # two batches answered; the third stalls past the budget
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    later = datetime.now(UTC) + timedelta(hours=1)
    loop = asyncio.get_running_loop()
    started: list[float] = []
    real_progress = scheduler._slot_progress

    async def last_read(db: AsyncSession) -> Any:  # the budget starts once the reads are done
        try:
            return await real_progress(db)
        finally:
            started.append(loop.time())

    monkeypatch.setattr(scheduler, "_slot_progress", last_read)
    async with asyncio.timeout(BUDGET + 5):  # stopped at the budget, not waiting on the third batch
        assert await _tick(later) == 0
    assert loop.time() - started[0] >= BUDGET  # the whole budget, counted from the reads
    assert len(fake_apns.sent) == 16
    assert fake_apns.max_in_flight == push_svc.MAX_CONCURRENT_SENDS
    devices = await _devices()
    assert sum(d.last_success_at is not None for d in devices.values()) == 16
    assert all(d.failure_count == 0 for d in devices.values())  # cut off is not a failure
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(Topic.last_notified_due_since))) is None
        assert (await db.scalar(select(func.count()).select_from(PushSlotDelivery))) == 16

    fake_apns.allow()
    assert await _tick(later) == 1  # the same budget: the last 4 fit
    assert sorted(s.device for s in fake_apns.sent) == sorted(token(n) for n in range(20))
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(func.count()).select_from(PushSlotDelivery))) == 0
    assert await _tick(later) == 0


async def test_slow_preparation_never_eats_the_delivery_budget(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Reading descriptors (rankings, last values) for many topics can take longer than the
    whole budget: the budget only starts after them, so every tick still delivers."""
    await client.post("/push/apns/devices", json=device(1))
    for name in ("Water", "Meds", "Walk"):
        await make_topic(client, name, QUESTIONS, schedule=INTERVAL)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    real = scheduler.prepare_quick_logs

    async def slow(db: AsyncSession, questions: dict[UUID, list[Any]]) -> dict[UUID, Any]:
        await asyncio.sleep(BUDGET + 0.2)  # longer than the whole budget
        return await real(db, questions)

    monkeypatch.setattr(scheduler, "prepare_quick_logs", slow)
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 3
    assert len(fake_apns.sent) == 3
    assert all(s.body["quickr"]["quick_log"] is not None for s in fake_apns.sent)


async def test_preparation_reads_in_at_most_two_queries(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    six = [
        {
            "key": "mood",
            "label": "Mood",
            "type": "enum",
            "options": [{"value": f"o{i}", "label": f"O{i}"} for i in range(6)],
        }
    ]
    four = [{**six[0], "options": six[0]["options"][:4]}]
    for i in range(3):
        await make_topic(client, f"Six {i}", six, schedule=INTERVAL)
        await make_topic(client, f"Four {i}", four, schedule=INTERVAL)
        await make_topic(client, f"Number {i}", QUESTIONS, schedule=INTERVAL)
        await record(client, f"six-{i}", {"mood": f"o{5 - i}"})
        await record(client, f"number-{i}", {"n": i})
    statements: list[str] = []
    engine = get_engine().sync_engine

    def count(conn: Any, cursor: Any, statement: str, *_: Any) -> None:
        if "FROM answers" in statement:
            statements.append(statement)

    event.listen(engine, "before_cursor_execute", count)
    try:
        async with get_sessionmaker()() as db:
            questions = await scheduler._questions(
                db, [(t.id, 1) for t in (await db.execute(select(Topic))).scalars()]
            )
            slugs = {t.id: t.slug for t in (await db.execute(select(Topic))).scalars()}
            quick_logs = await scheduler.prepare_quick_logs(db, questions)
    finally:
        event.remove(engine, "before_cursor_execute", count)
    assert len(statements) == 2  # one ranking (the 6-option enums only), one latest-value
    by_slug = {slugs[topic_id]: q for topic_id, q in quick_logs.items()}
    assert [o.value for o in by_slug["six-2"].options] == ["o3", "o0", "o1"]  # type: ignore[union-attr]
    assert by_slug["number-2"].last_value == 2  # type: ignore[union-attr]


async def test_repeated_short_ticks_reach_every_target_once_and_every_topic(
    client: httpx.AsyncClient,
    fake_apns: FakeApns,
    web_outbox: list[dict[str, Any]],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With the same insufficient budget every tick, a fan-out larger than a tick still
    completes: every target gets each slot exactly once, and the later topic follows."""
    for n in range(20):
        await client.post("/push/apns/devices", json=device(n))
    await client.post("/push/subscriptions", json=WEB_SUB)
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    await make_topic(client, "Meds", QUESTIONS, schedule=INTERVAL)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    later = datetime.now(UTC) + timedelta(hours=1)
    notified = []
    for _ in range(6):
        fake_apns.allow(16)  # two batches of 8 a tick; the rest stall past the budget
        notified.append(await _tick(later))
    assert sum(notified) == 2
    assert notified[-2:] == [0, 0]
    per_target: dict[tuple[str, str], int] = {}
    for sent in fake_apns.sent:
        key = (sent.body["quickr"]["topic_slug"], sent.device)
        per_target[key] = per_target.get(key, 0) + 1
    assert per_target == {(slug, token(n)): 1 for slug in ("water", "meds") for n in range(20)}
    assert sorted(w["topic_slug"] for w in web_outbox) == ["meds", "water"]
    async with get_sessionmaker()() as db:
        marked = (await db.execute(select(Topic.last_notified_due_since))).scalars().all()
        assert all(m is not None for m in marked)
        assert (await db.scalar(select(func.count()).select_from(PushSlotDelivery))) == 0


async def test_oldest_slot_goes_first(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    await client.post("/push/apns/devices", json=device(1))
    await make_topic(client, "Newer", QUESTIONS, schedule=INTERVAL)
    await make_topic(client, "Older", QUESTIONS, schedule=INTERVAL)
    await backdate_schedule("older", datetime.now(UTC) - timedelta(days=1))
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 2
    assert [s.body["quickr"]["topic_slug"] for s in fake_apns.sent] == ["older", "newer"]


async def _age_progress(days: int) -> int:
    """Backdate every progress row; returns how many there are."""
    async with get_sessionmaker()() as db:
        await db.execute(update(PushSlotDelivery).values(created_at=datetime.now(UTC) - timedelta(days=days)))
        await db.commit()
        return int(await db.scalar(select(func.count()).select_from(PushSlotDelivery)) or 0)


async def _progress_count() -> int:
    async with get_sessionmaker()() as db:
        return int(await db.scalar(select(func.count()).select_from(PushSlotDelivery)) or 0)


async def test_progress_of_a_slot_still_due_survives_the_ttl(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A fan-out slower than the TTL (an outage, a tiny budget) still resumes: no target
    gets the slot twice."""
    for n in range(20):
        await client.post("/push/apns/devices", json=device(n))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    fake_apns.allow(16)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 0
    assert await _age_progress(days=3) == 16  # older than the TTL, but the slot is still due

    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", -1.0)  # a tick that sends nothing
    assert await _tick(later) == 0
    assert await _progress_count() == 16

    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    fake_apns.allow()
    assert await _tick(later) == 1
    assert sorted(s.device for s in fake_apns.sent) == sorted(token(n) for n in range(20))
    assert await _progress_count() == 0


async def test_progress_of_an_abandoned_slot_is_pruned_after_the_ttl(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    for n in range(20):
        await client.post("/push/apns/devices", json=device(n))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    fake_apns.allow(16)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", BUDGET)
    later = datetime.now(UTC) + timedelta(hours=1)
    assert await _tick(later) == 0
    assert await _progress_count() == 16
    await record(client, "water", {"n": 1}, captured_at=later.isoformat())  # satisfies the slot

    assert await _tick(later) == 0
    assert await _progress_count() == 16  # abandoned, but younger than the TTL
    await _age_progress(days=3)
    assert await _tick(later) == 0
    assert await _progress_count() == 0


async def test_stale_slot_progress_is_pruned(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    topic = await make_topic(client, "Water", QUESTIONS)
    async with get_sessionmaker()() as db:
        for age in (1, 3):
            db.add(
                PushSlotDelivery(
                    topic_id=topic["id"],
                    due_since=datetime.now(UTC) - timedelta(days=age),
                    target_kind="apns",
                    target_id=uuid4(),
                    created_at=datetime.now(UTC) - timedelta(days=age),
                )
            )
        await db.commit()
    assert await _tick(datetime.now(UTC)) == 0
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(func.count()).select_from(PushSlotDelivery))) == 1


async def test_tick_past_its_budget_sends_nothing_more(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch
) -> None:
    await client.post("/push/apns/devices", json=device(1))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    monkeypatch.setattr(scheduler, "TICK_BUDGET_SECONDS", -1.0)
    assert await _tick(datetime.now(UTC) + timedelta(hours=1)) == 0
    assert fake_apns.sent == []


async def test_tick_holds_no_target_row_locks_while_sending(
    client: httpx.AsyncClient, fake_apns: FakeApns
) -> None:
    """While a tick waits on APNs for its second topic, registering the device it already
    notified (feed lock + upsert of that row) is not blocked: the tick's bookkeeping is
    only written just before its commit."""
    await client.post("/push/apns/devices", json=device(1))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    await make_topic(client, "Meds", QUESTIONS, schedule=INTERVAL)
    fake_apns.allow(1)  # water's send is answered; meds' stalls until allowed
    tick = asyncio.create_task(_tick(datetime.now(UTC) + timedelta(hours=1)))
    async with asyncio.timeout(5):  # a blocked upsert would wait on the stalled tick for good
        await fake_apns.wait_started(2)  # water done, meds in flight
        r = await client.post("/push/apns/devices", json={**device(1), "app_version": "2.0"})
    assert r.status_code == 201
    assert not tick.done()
    fake_apns.allow()
    assert await tick == 2
    stored = (await _devices())[token(1)]
    assert (stored.app_version, stored.last_success_at is not None) == ("2.0", True)


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


async def test_a_closed_sender_never_reconnects(fake_apns: FakeApns) -> None:
    sender = fake_apns.sender()
    await sender.post(token(1), "sandbox", DUE, 60)
    await sender.aclose()
    with pytest.raises(push_svc.PushFailed, match="closed"):
        await sender.post(token(1), "production", DUE, 60)
    assert sender._clients == {}
    assert len(fake_apns.sent) == 1


async def test_app_shutdown_stops_the_scheduler_before_closing_apns(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A scheduler tick suspended in an APNs request at shutdown: the scheduler is cancelled
    (the request with it, the slot unmarked) before the connections close, and nothing
    reopens one afterwards."""
    from app.main import app

    await client.post("/push/apns/devices", json=device(1))
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    await backdate_schedule("water", datetime.now(UTC) - timedelta(days=1))
    fake = FakeApns.create()
    fake.delay = 60
    sender = fake.sender()
    real_aclose = sender.aclose

    async def recording_aclose() -> None:
        fake.events.append("connections closed")
        await real_aclose()

    monkeypatch.setattr(sender, "aclose", recording_aclose)
    monkeypatch.setattr(apns, "_load", lambda: sender)
    monkeypatch.setattr(
        scheduler, "get_settings", lambda: Settings(scheduler_enabled=True, scheduler_interval_seconds=3600)
    )
    async with app.router.lifespan_context(app):
        async with asyncio.timeout(5):
            await fake.wait_started()
    assert fake.events == ["request cancelled", "connections closed"]
    assert sender._clients == {}
    assert apns.get_sender() is None
    async with get_sessionmaker()() as db:
        assert (await db.scalar(select(Topic.last_notified_due_since))) is None


# --- tokens and endpoints stay out of the logs -----------------------------------------------


async def test_script_logs_no_device_token(
    fake_apns: FakeApns,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
    capsys: pytest.CaptureFixture[str],
) -> None:
    from scripts import apns_send

    config = ApnsConfig(team_id=TEAM_ID, topic=TOPIC, keys={})
    monkeypatch.setattr(ApnsConfig, "from_settings", lambda _settings: config)
    monkeypatch.setattr(apns_send, "ApnsSender", lambda _config: fake_apns.sender())
    caplog.set_level(logging.INFO)  # what the script's logging config turns on
    args = argparse.Namespace(token=token(0xBEEF).upper(), env="sandbox", title="t", body="b")
    assert await apns_send.main(args) == 0
    assert "HTTP Request: POST https://api.sandbox.push.apple.com/3/device/<token>" in caplog.text
    output = caplog.text + capsys.readouterr().out
    assert "apns-id apns-1" in output
    assert token(0xBEEF) not in output.lower()


async def test_transport_failures_log_no_device_token(
    client: httpx.AsyncClient, fake_apns: FakeApns, caplog: pytest.LogCaptureFixture
) -> None:
    url = f"https://api.sandbox.push.apple.com/3/device/{token(1)}"
    fake_apns.raises[token(1)] = httpx.ConnectError(f"connection to {url} failed")
    with pytest.raises(push_svc.PushFailed) as failure:
        await fake_apns.sender().post(token(1), "sandbox", DUE, 60)
    assert token(1) not in str(failure.value)
    assert failure.value.__cause__ is None
    assert failure.value.__suppress_context__

    await client.post("/push/apns/devices", json=device(1))
    with caplog.at_level(logging.DEBUG):
        r = await client.post("/push/apns/devices/test", json={"token": token(1)})
    assert r.json() == {"sent": 0, "failed": 1}
    assert "ConnectError" in caplog.text
    assert token(1) not in caplog.text


async def test_web_push_failures_log_no_endpoint(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    secret = "fcm/send/SECRET-capability"
    endpoint = f"https://fcm.googleapis.com/{secret}"
    monkeypatch.setattr(web_push, "ensure_public", lambda host: None)
    errors: list[Exception] = [
        requests.ConnectionError(f"Max retries exceeded with url: /{secret}"),
        WebPushException(f"Push failed: 500 {endpoint}", response=_Response(500, endpoint)),
        WebPushException(f"Push failed: 410 {endpoint}", response=_Response(410, endpoint)),
    ]

    def failing_webpush(**_: Any) -> None:
        raise errors.pop(0)

    monkeypatch.setattr(web_push, "webpush", failing_webpush)
    await client.post("/push/subscriptions", json={**WEB_SUB, "endpoint": endpoint})
    with caplog.at_level(logging.DEBUG):
        assert (await client.post("/push/test")).json() == {"sent": 0, "failed": 1}  # connection error
        assert (await client.post("/push/test")).json() == {"sent": 0, "failed": 1}  # 500
        assert (await client.post("/push/test")).json() == {"sent": 0, "failed": 1}  # 410: deleted
    assert "fcm.googleapis.com answered 500" in caplog.text
    assert "SECRET" not in caplog.text

    # urllib3's debug request line (requests logs one per send) has its path redacted.
    with caplog.at_level(logging.DEBUG):
        logging.getLogger("urllib3.connectionpool").debug(
            '%s://%s:%s "%s %s %s" %s %s',
            "https",
            "fcm.googleapis.com",
            443,
            "POST",
            f"/{secret}",
            "HTTP/1.1",
            201,
            0,
        )
    assert '"POST <path> HTTP/1.1" 201' in caplog.text
    assert "SECRET" not in caplog.text


class _Response:
    def __init__(self, status_code: int, text: str) -> None:
        self.status_code = status_code
        self.text = text
