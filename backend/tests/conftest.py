"""Shared fixtures.

The test database (``QUICKR_TEST_DATABASE_URL``, default ``quickr_test`` on the
dev server, ``quickr_test_<worktree>_<hash>`` in a git worktree: see ``tools.test_database``)
is created if missing and migrated with Alembic -- never
``metadata.create_all`` -- so the migrations themselves are exercised. Tables
are truncated before every DB-backed test.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from tools import test_database  # SQLAlchemy only: imports no app settings

TEST_DATABASE_URL = test_database.url()
# Must happen before anything calls the lru_cached get_settings()/get_engine().
os.environ["QUICKR_DATABASE_URL"] = TEST_DATABASE_URL
# Tests drive scheduler.tick() directly; never start the background loop.
os.environ["QUICKR_SCHEDULER_ENABLED"] = "false"
os.environ.pop("QUICKR_VAPID_PRIVATE_KEY", None)
os.environ.pop("QUICKR_VAPID_PUBLIC_KEY", None)
for _name in [n for n in os.environ if n.startswith("QUICKR_APNS_")]:
    del os.environ[_name]  # APNs is off unless a test turns on the fake

import httpx  # noqa: E402
from alembic.config import Config  # noqa: E402
from sqlalchemy import text  # noqa: E402
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine  # noqa: E402

from alembic import command  # noqa: E402
from app.client_versions import API_LEVEL, CLIENT_HEADER  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.db import get_engine, get_sessionmaker  # noqa: E402
from app.services.push import apns  # noqa: E402
from tests.fake_apns import FakeApns  # noqa: E402

BACKEND_DIR = Path(__file__).resolve().parent.parent
TABLES = (
    "answers",
    "entries",
    "run_events",
    "run_aliases",
    "runs",
    "topic_versions",
    "topics",
    "push_subscriptions",
    "apns_devices",
    "live_activity_tokens",
    "push_slot_deliveries",
    "app_settings",
    "change_log",
    "deleted_ids",
)


def alembic_config() -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    return cfg


@pytest.fixture(scope="session")
def migrated_db() -> str:
    assert get_settings().database_url == TEST_DATABASE_URL
    asyncio.run(test_database.ensure(TEST_DATABASE_URL))
    # alembic/env.py drives its own event loop, so this must run outside ours.
    command.upgrade(alembic_config(), "head")
    return TEST_DATABASE_URL


@pytest.fixture
async def peer_engine(migrated_db: str) -> AsyncIterator[AsyncEngine]:
    """A second, empty database on the same server, as another worktree's test database or
    another quickR instance would be. Its name is unique to this fixture invocation, which
    drops it afterwards (``make test-db-prune`` clears ones a killed run left, after an hour). A lock wait
    there fails after 5 s instead of hanging."""
    peer = test_database.peer_url(migrated_db)
    await test_database.create(peer)
    try:
        engine = create_async_engine(peer, connect_args={"server_settings": {"lock_timeout": "5s"}})
        try:
            yield engine
        finally:
            await engine.dispose()
    finally:
        await test_database.drop(peer)


@pytest.fixture
async def clean_db(migrated_db: str) -> None:
    async with get_engine().begin() as conn:
        await conn.execute(text(f"TRUNCATE {', '.join(TABLES)} RESTART IDENTITY CASCADE"))


@pytest.fixture
async def db(clean_db: None) -> AsyncIterator[AsyncSession]:
    async with get_sessionmaker()() as session:
        yield session


# The shared client is a current build (docs/specs/client-versions.md §3.3), so a bump that
# raises the minimums refuses none of the tests; tests of the check itself use ``bare_client``.
CURRENT_CLIENT = {CLIENT_HEADER: f"web; level={API_LEVEL}; build=test"}


@pytest.fixture
async def bare_client(clean_db: None) -> AsyncIterator[httpx.AsyncClient]:
    """The API with no ``X-QuickR-Client``: not checked, or level 0 with an ``X-QuickR-Channel``."""
    from app.main import app

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test/api/v1") as c:
        yield c


@pytest.fixture
async def client(bare_client: httpx.AsyncClient) -> httpx.AsyncClient:
    """The API as a client at this server's level."""
    bare_client.headers.update(CURRENT_CLIENT)
    return bare_client


@pytest.fixture
def fake_apns(monkeypatch: pytest.MonkeyPatch) -> FakeApns:
    """APNs switched on, talking to a fake (``httpx.MockTransport``)."""
    fake = FakeApns.create()
    sender = fake.sender()
    monkeypatch.setattr(apns, "get_sender", lambda: sender)
    return fake
