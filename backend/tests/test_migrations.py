"""Alembic migrations: head matches the ORM models, and downgrade/upgrade round-trips."""

from __future__ import annotations

from typing import Any

from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import Connection, text

from alembic import command
from app.db import get_engine
from app.models import Base
from tests.conftest import alembic_config


def _diff(conn: Connection) -> list[Any]:
    ctx = MigrationContext.configure(conn, opts={"compare_type": True})
    return list(compare_metadata(ctx, Base.metadata))


async def test_database_at_head(migrated_db: str) -> None:
    head = ScriptDirectory.from_config(alembic_config()).get_current_head()
    async with get_engine().connect() as conn:
        current = (await conn.execute(text("SELECT version_num FROM alembic_version"))).scalar_one()
    assert current == head


async def test_models_match_migrations(migrated_db: str) -> None:
    async with get_engine().connect() as conn:
        diff = await conn.run_sync(_diff)
    assert diff == [], f"models and migrations differ; generate a migration: {diff}"


async def test_downgrade_and_upgrade_roundtrip(migrated_db: str) -> None:
    # alembic/env.py runs its own event loop, so drive it from a worker thread.
    import asyncio

    await get_engine().dispose()
    cfg = alembic_config()
    await asyncio.to_thread(command.downgrade, cfg, "base")
    await asyncio.to_thread(command.upgrade, cfg, "head")
