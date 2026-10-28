"""Client API levels and forced updates (docs/specs/client-versions.md): spec cases V1-V5.

The tests raise the minimums by replacing ``client_versions.current``; ``resolve`` is tested on
its own against ``Settings``. The shipped levels are read from shared/api-level.json, so a bump
needs no edits here. ``client`` is the bare client: no ``X-QuickR-Client`` unless a test sends one.
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx
import pytest
from sqlalchemy import select, text

from app import client_versions
from app.client_versions import Client, Levels, parse_client, request_client
from app.config import Settings
from app.db import get_sessionmaker
from app.models import ApnsDevice, LiveActivityToken
from app.services import scheduler
from app.services.push import apns
from app.services.push import web as web_push
from tests.conftest import TABLES
from tests.fake_apns import FakeApns, token
from tests.helpers import make_topic, record
from tests.test_api_runs import NOW, Driver, at, frozen_clock, timed
from tests.test_live_activity import aps, la_token, to

# The minimums a later breaking change would set: both 2, at api_level 2.
RAISED = Levels(api_level=2, min_client_level={"ios": 2, "web": 2}, ios_update_url="itms-beta://")
OLD_IOS = {"X-QuickR-Client": "ios; level=1; build=20261028.120000", "X-QuickR-Channel": "ios"}
NEW_IOS = {"X-QuickR-Client": "ios; level=2; build=20261029.120000", "X-QuickR-Channel": "ios"}
OLD_WEB = {"X-QuickR-Client": "web; level=1; build=2026-10-28T12:00:00Z", "X-QuickR-Channel": "ui"}
LEVEL_HEADERS = ("x-quickr-api-level", "x-quickr-min-client-level")
SHIPPED = json.loads((Path(__file__).resolve().parents[2] / "shared/api-level.json").read_text())
QUESTIONS = [{"key": "n", "label": "N", "type": "int"}]
INTERVAL = {"kind": "interval", "every_minutes": 15, "timezone": "UTC"}


@pytest.fixture
def client(bare_client: httpx.AsyncClient) -> httpx.AsyncClient:
    """These tests choose each request's client headers themselves."""
    return bare_client


@pytest.fixture
def clock(monkeypatch: pytest.MonkeyPatch) -> None:
    """The runs' clock (``tests.test_api_runs``): taps are stamped relative to it."""
    frozen_clock(monkeypatch, NOW)


@pytest.fixture
def raised(monkeypatch: pytest.MonkeyPatch) -> Levels:
    monkeypatch.setattr(client_versions, "current", lambda: RAISED)
    return RAISED


async def row_counts() -> dict[str, int]:
    async with get_sessionmaker()() as db:
        return {t: int(await db.scalar(text(f"SELECT count(*) FROM {t}")) or 0) for t in TABLES}


def assert_outdated(r: httpx.Response, *, client_level: int, minimum: int = 2) -> None:
    assert r.status_code == 426, r.text
    assert r.headers["content-type"] == "application/problem+json"
    assert r.json() == {
        "code": "client_outdated",
        "detail": client_versions.OUTDATED_DETAIL,
        "errors": [],
        "min_client_level": minimum,
        "client_level": client_level,
    }


# --- V1: the level headers on every response ---------------------------------------------------


async def test_level_headers_on_every_response(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, raised: Levels
) -> None:
    from app.services import topics as topic_svc

    async def boom(*_: Any, **__: Any) -> None:
        raise RuntimeError("boom")

    await make_topic(client)
    responses = [
        await client.get("/health"),
        await client.get("/topics"),  # 2xx
        await client.get("/topics/nope"),  # 404
        await client.post("/topics", json={}),  # 422
        await client.get("/topics", headers=OLD_IOS),  # 426
        await client.get("/client-versions", headers=OLD_IOS),
    ]
    with monkeypatch.context() as m:
        m.setattr(topic_svc, "list_topics", boom)
        responses.append(await client.get("/topics"))  # an unhandled 500
    assert [r.status_code for r in responses] == [200, 200, 404, 422, 426, 200, 500]
    for r in responses:
        assert r.headers["x-quickr-api-level"] == "2"
        assert r.headers["x-quickr-min-client-level"] == "ios=2, web=2"
    outdated, served = responses[4], responses[1]
    # The client checks the identity before it decodes a Problem.
    for header in ("x-quickr-server-id", "x-quickr-epoch"):
        assert outdated.headers[header] == served.headers[header]
    assert outdated.headers["x-quickr-server-time"].isdigit()


async def test_the_shipped_levels_on_the_wire(client: httpx.AsyncClient) -> None:
    r = await client.get("/health")
    minimums = SHIPPED["min_client_level"]
    assert r.headers["x-quickr-api-level"] == str(client_versions.API_LEVEL) == str(SHIPPED["api_level"])
    assert r.headers["x-quickr-min-client-level"] == f"ios={minimums['ios']}, web={minimums['web']}"
    assert "x-quickr-api-level" not in (await client.get("http://test/api/v10/health")).headers


async def test_level_headers_are_exposed_to_browsers(client: httpx.AsyncClient) -> None:
    r = await client.get("/health", headers={"Origin": "http://localhost:5180"})
    exposed = {h.strip().lower() for h in r.headers["access-control-expose-headers"].split(",")}
    assert set(LEVEL_HEADERS) <= exposed


async def test_get_client_versions(client: httpx.AsyncClient) -> None:
    r = await client.get("/client-versions")
    assert r.status_code == 200
    assert r.json() == {**SHIPPED, "update_url": {"ios": "itms-beta://"}}


# --- V2: below the minimum, refused before any effect -----------------------------------------


@pytest.mark.usefixtures("clock")
async def test_refused_before_any_write(client: httpx.AsyncClient, raised: Levels) -> None:
    topic = await timed(client, "Routine", steps=[{"key": "a", "label": "A"}])
    await make_topic(client)
    entry = await record(client, "sleep-log", {"hours": 7.5, "wakeups": 1, "quality": "ok"})
    run = Driver(client, topic)
    await run.start()
    before = await row_counts()
    requests = [
        client.post("/topics", json={"name": "New", "questions": QUESTIONS}, headers=OLD_IOS),
        client.patch("/topics/sleep-log", json={"name": "Renamed"}, headers=OLD_IOS),
        client.delete(f"/entries/{entry['id']}", headers=OLD_IOS),
        client.get("/topics", headers=OLD_IOS),
        client.post(
            f"/runs/{run.id}/events",
            json={"id": str(uuid4()), "type": "lap", "at": at(30)},
            headers=OLD_IOS,
        ),
        client.post("/topics", json={"name": "Web", "questions": QUESTIONS}, headers=OLD_WEB),
    ]
    for request in requests:
        assert_outdated(await request, client_level=1)
    assert await row_counts() == before


async def test_at_or_above_the_minimum_is_served(client: httpx.AsyncClient, raised: Levels) -> None:
    r = await client.post("/topics", json={"name": "New", "questions": QUESTIONS}, headers=NEW_IOS)
    assert r.status_code == 201, r.text
    above = {"X-QuickR-Client": "web; level=7; build=x"}  # a client newer than the server: warned only
    assert (await client.get("/topics", headers=above)).status_code == 200


@pytest.mark.parametrize("platform", ["ios", "web"])
async def test_the_shipped_minimums(client: httpx.AsyncClient, platform: str) -> None:
    """A client at its shipped minimum is served; one below it (if any can be) is refused."""
    minimum = SHIPPED["min_client_level"][platform]
    at_minimum = {"X-QuickR-Client": f"{platform}; level={minimum}; build=x"}
    r = await client.post("/topics", json={"name": "New", "questions": QUESTIONS}, headers=at_minimum)
    assert r.status_code == 201, r.text
    pre_cv = {"X-QuickR-Channel": "ios" if platform == "ios" else "ui"}  # level 0
    r = await client.get("/topics", headers=pre_cv)
    if minimum == 0:
        assert r.status_code == 200, r.text
    else:
        assert_outdated(r, client_level=0, minimum=minimum)


# --- V3: who is checked -----------------------------------------------------------------------


@pytest.mark.parametrize("channel", ["ios", "ui"])
async def test_a_channel_without_a_client_header_is_level_0(
    client: httpx.AsyncClient, raised: Levels, channel: str
) -> None:
    assert_outdated(await client.get("/topics", headers={"X-QuickR-Channel": channel}), client_level=0)


@pytest.mark.parametrize("channel", [None, "api", "mcp"])
async def test_requests_from_no_known_client_are_not_checked(
    client: httpx.AsyncClient, raised: Levels, channel: str | None
) -> None:
    headers = {} if channel is None else {"X-QuickR-Channel": channel}
    assert (await client.get("/topics", headers=headers)).status_code == 200


async def test_never_refused(client: httpx.AsyncClient, raised: Levels) -> None:
    assert (await client.get("/health", headers=OLD_IOS)).status_code == 200
    r = await client.get("/client-versions", headers=OLD_IOS)
    assert r.status_code == 200
    assert r.json()["min_client_level"] == {"ios": 2, "web": 2}
    preflight = {
        **OLD_WEB,
        "Origin": "http://localhost:5180",
        "Access-Control-Request-Method": "POST",
    }
    assert (await client.options("/topics", headers=preflight)).status_code == 200
    # A bare OPTIONS reaches the router (405), never the check.
    assert (await client.options("/topics", headers=OLD_IOS)).status_code == 405


async def test_a_malformed_client_header_is_level_0(client: httpx.AsyncClient, raised: Levels) -> None:
    for value in ["ios", "ios; level=two", "ios; level=-1", "android; level=5", ""]:
        r = await client.get("/topics", headers={"X-QuickR-Client": value})
        assert_outdated(r, client_level=0)


def test_parse_client() -> None:
    assert parse_client("ios; level=3; build=20261022.005113") == Client("ios", 3, "20261022.005113")
    assert parse_client("web;level=2;build=2026-10-28T12:00:00Z") == Client("web", 2, "2026-10-28T12:00:00Z")
    assert parse_client("ios; build=1; level=1") == Client("ios", 1, "1")
    assert parse_client("ios; level=1") == Client("ios", 1)
    assert parse_client("ios; level=\u0661") == Client("ios", 0)  # a non-ASCII digit
    assert parse_client("tv; level=1") == Client(None, 0)
    assert request_client({}) is None
    assert request_client({"X-QuickR-Channel": "api"}) is None
    assert request_client({"X-QuickR-Channel": "ui"}) == Client("web", 0)
    # An unreadable platform falls back on the channel, then on the strictest minimum.
    assert request_client({"X-QuickR-Client": "?", "X-QuickR-Channel": "ui"}) == Client("web", 0)
    assert RAISED.minimum(None) == 2
    assert Levels(3, {"ios": 1, "web": 3}, "").minimum(None) == 3


# --- V4: the environment's overrides ----------------------------------------------------------


@pytest.fixture
def built_in(monkeypatch: pytest.MonkeyPatch) -> None:
    """A built-in file at api_level 3 with both minimums at 2."""
    monkeypatch.setattr(client_versions, "API_LEVEL", 3)
    monkeypatch.setattr(client_versions, "MIN_CLIENT_LEVEL", {"ios": 2, "web": 2})


def settings(**values: Any) -> Settings:
    return Settings(_env_file=None, **values)


@pytest.mark.usefixtures("built_in")
def test_an_override_raises_the_minimum(caplog: pytest.LogCaptureFixture) -> None:
    levels = client_versions.resolve(settings(min_client_level_ios=3))
    assert dict(levels.min_client_level) == {"ios": 3, "web": 2}
    assert levels.api_level == 3
    assert not caplog.records


@pytest.mark.usefixtures("built_in")
def test_an_override_never_lowers_the_minimum(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING, "app.client_versions"):
        levels = client_versions.resolve(settings(min_client_level_web=1))
    assert dict(levels.min_client_level) == {"ios": 2, "web": 2}
    [warning] = caplog.records
    assert "QUICKR_MIN_CLIENT_LEVEL_WEB=1 is below the built-in minimum 2; ignored" in warning.getMessage()


@pytest.mark.usefixtures("built_in")
def test_an_override_above_the_api_level_is_clamped(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.WARNING, "app.client_versions"):
        levels = client_versions.resolve(settings(min_client_level_ios=9, min_client_level_web=3))
    assert dict(levels.min_client_level) == {"ios": 3, "web": 3}
    [warning] = caplog.records
    assert "QUICKR_MIN_CLIENT_LEVEL_IOS=9 is above the API level 3" in warning.getMessage()


@pytest.mark.usefixtures("built_in")
def test_overrides_and_the_update_url_come_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("QUICKR_MIN_CLIENT_LEVEL_IOS", "3")
    monkeypatch.setenv("QUICKR_IOS_UPDATE_URL", "https://testflight.apple.com/join/abc")
    levels = client_versions.resolve(Settings(_env_file=None))
    assert dict(levels.min_client_level) == {"ios": 3, "web": 2}
    assert levels.ios_update_url == "https://testflight.apple.com/join/abc"


@pytest.mark.usefixtures("built_in")
async def test_get_client_versions_reports_the_overrides(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    levels = client_versions.resolve(settings(min_client_level_ios=3, ios_update_url="itms-beta://x"))
    monkeypatch.setattr(client_versions, "current", lambda: levels)
    r = await client.get("/client-versions")
    assert r.json() == {
        "api_level": 3,
        "min_client_level": {"ios": 3, "web": 2},
        "update_url": {"ios": "itms-beta://x"},
    }
    assert r.headers["x-quickr-min-client-level"] == "ios=3, web=2"
    assert_outdated(
        await client.get("/topics", headers={"X-QuickR-Client": "ios; level=2; build=x"}),
        client_level=2,
        minimum=3,
    )
    assert (
        await client.get("/topics", headers={"X-QuickR-Client": "web; level=2; build=x"})
    ).status_code == 200


def test_the_built_in_file_is_checked(tmp_path: Any) -> None:
    path = tmp_path / "api_level.json"
    path.write_text('{"api_level": 1, "min_client_level": {"ios": 2, "web": 0}}')
    with pytest.raises(ValueError, match="at most api_level"):
        client_versions._load(path)
    path.write_text('{"api_level": "1", "min_client_level": {"ios": 0, "web": 0}}')
    with pytest.raises(ValueError, match="non-negative integers"):
        client_versions._load(path)


# --- V5: pushes to outdated devices -----------------------------------------------------------


async def stored_levels(model: type[ApnsDevice] | type[LiveActivityToken]) -> dict[str, int]:
    async with get_sessionmaker()() as db:
        rows = await db.execute(select(model.token, model.client_level))
        return dict(rows.all())


async def test_registrations_store_the_client_level(client: httpx.AsyncClient, raised: Levels) -> None:
    device = {"token": token(1), "environment": "sandbox"}
    r = await client.post("/push/apns/devices", json=device, headers=NEW_IOS)
    assert r.status_code == 201, r.text
    assert "client_level" not in r.json()
    await client.post("/push/apns/devices", json={**device, "token": token(2)})  # no header: 0
    assert await stored_levels(ApnsDevice) == {token(1): 2, token(2): 0}

    start = {"token": la_token(1), "kind": "start", "device_token": token(1), "environment": "production"}
    r = await client.post("/push/apns/live-activities", json=start, headers=NEW_IOS)
    assert r.status_code == 201, r.text
    await client.post(
        "/push/apns/live-activities", json={**start, "token": la_token(2), "device_token": token(3)}
    )
    assert await stored_levels(LiveActivityToken) == {la_token(1): 2, la_token(2): 0}

    # An older build is refused, so its level is never stored; an update refreshes it.
    assert_outdated(await client.post("/push/apns/devices", json=device, headers=OLD_IOS), client_level=1)
    level_3 = {"X-QuickR-Client": "ios; level=3; build=y"}
    await client.post("/push/apns/devices", json={**device, "token": token(2)}, headers=level_3)
    assert await stored_levels(ApnsDevice) == {token(1): 2, token(2): 3}


async def test_a_reminder_to_a_device_below_the_minimum_is_display_only(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch, raised: Levels
) -> None:
    monkeypatch.setattr(web_push, "deliver", lambda *_: None)
    await client.post(
        "/push/apns/devices", json={"token": token(1), "environment": "sandbox"}, headers=NEW_IOS
    )
    await client.post("/push/apns/devices", json={"token": token(2), "environment": "sandbox"})  # pre-CV: 0
    await make_topic(client, "Water", QUESTIONS, schedule=INTERVAL)
    async with get_sessionmaker()() as db:
        assert await scheduler.tick(db, now=datetime.now(UTC) + timedelta(hours=1)) == 1

    sent = {s.device: s.body for s in fake_apns.sent}
    current, old = sent[token(1)], sent[token(2)]
    assert "category" in current["aps"]
    assert current["quickr"]["quick_log"]["type"] == "int"
    assert "category" not in old["aps"]
    assert old["quickr"]["quick_log"] is None
    assert (
        old["aps"]["alert"]["body"] == current["aps"]["alert"]["body"] + " · update quickR to log from here"
    )
    assert old["aps"]["alert"]["body"].endswith("· update quickR to log from here")
    assert old["quickr"]["topic_id"] == current["quickr"]["topic_id"]


async def test_a_timed_topics_reminder_below_the_minimum_has_no_start(
    client: httpx.AsyncClient, fake_apns: FakeApns, monkeypatch: pytest.MonkeyPatch, raised: Levels
) -> None:
    """A timed topic's reminder offers Start (timers.md §10.2); below the minimum it doesn't."""
    monkeypatch.setattr(web_push, "deliver", lambda *_: None)
    await client.post(
        "/push/apns/devices", json={"token": token(1), "environment": "sandbox"}, headers=NEW_IOS
    )
    await client.post("/push/apns/devices", json={"token": token(2), "environment": "sandbox"})  # pre-CV: 0
    await timed(client, "Routine", steps=[{"key": "a", "label": "A"}], schedule=INTERVAL)
    async with get_sessionmaker()() as db:
        assert await scheduler.tick(db, now=datetime.now(UTC) + timedelta(hours=1)) == 1

    sent = {s.device: s.body for s in fake_apns.sent}
    current, old = sent[token(1)], sent[token(2)]
    assert current["quickr"]["quick_log"] == {"type": "timed"}
    assert current["aps"]["category"].startswith("quickr.t.")
    assert "category" not in old["aps"]
    assert old["quickr"]["quick_log"] is None
    assert old["aps"]["alert"]["body"].endswith(" · update quickR to log from here")


def test_display_only_leaves_other_notifications_alone() -> None:
    from app.services.push import TEST_NOTIFICATION

    assert apns.display_only(TEST_NOTIFICATION) is TEST_NOTIFICATION


@pytest.mark.usefixtures("clock")
async def test_no_live_activity_pushes_to_a_token_below_the_minimum(
    client: httpx.AsyncClient, fake_apns: FakeApns, raised: Levels
) -> None:
    """Neither token's phone has an ``apns_devices`` row (notifications denied): the level is the
    token's own."""

    async def register(n: int, headers: dict[str, str], **body: Any) -> str:
        body = {"token": la_token(n), "device_token": token(n), "environment": "production", **body}
        r = await client.post("/push/apns/live-activities", json=body, headers=headers)
        assert r.status_code == 201, r.text
        return la_token(n)

    old_start = await register(1, {}, kind="start")
    new_start = await register(2, NEW_IOS, kind="start")
    topic = await timed(client, "Routine", steps=[{"key": "a", "label": "A"}, {"key": "b", "label": "B"}])
    run = Driver(client, topic)
    await run.start()
    old_update = await register(3, {}, kind="update", topic_id=topic["id"], run_id=run.id)
    new_update = await register(4, NEW_IOS, kind="update", topic_id=topic["id"], run_id=run.id)
    await run.tap("next", 60, seg=0)
    await run.tap("stop", 120)
    async with get_sessionmaker()() as db:
        assert (await db.scalar(text("SELECT count(*) FROM apns_devices"))) == 0

    assert [aps(s)["event"] for s in to(fake_apns, new_start)] == ["start"]
    assert [aps(s)["event"] for s in to(fake_apns, new_update)] == ["update", "end"]
    assert to(fake_apns, old_start) == []
    assert to(fake_apns, old_update) == []

    # A late token for the closed run gets its end only at the minimum.
    late_old = await register(5, {}, kind="update", topic_id=topic["id"], run_id=run.id)
    late_new = await register(6, NEW_IOS, kind="update", topic_id=topic["id"], run_id=run.id)
    assert to(fake_apns, late_old) == []
    assert [aps(s)["event"] for s in to(fake_apns, late_new)] == ["end"]
