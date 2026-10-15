"""Alembic migrations: head matches the ORM models, and downgrade/upgrade round-trips."""

from __future__ import annotations

from typing import Any

import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import Connection, text
from sqlalchemy.ext.asyncio import AsyncConnection

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


INITIAL = "c05f3d88ef9b"
T = "00000000-0000-0000-0000-00000000000"  # + digit: fixed UUIDs for raw SQL


async def _alembic(fn: Any, revision: str) -> None:
    import asyncio

    await get_engine().dispose()
    await asyncio.to_thread(fn, alembic_config(), revision)


async def _insert_v1_data(conn: AsyncConnection) -> None:
    """A v1 (``sessions``) database with one topic, session and answer."""
    await conn.execute(
        text(
            "INSERT INTO topics (id, slug, name, description, status, current_version)"
            f" VALUES ('{T}1', 'demo', 'Demo', '', 'active', 1)"
        )
    )
    await conn.execute(
        text(
            "INSERT INTO topic_versions (id, topic_id, version, questions, change_note) VALUES"
            f""" ('{T}2', '{T}1', 1, '[{{"type": "int", "key": "n", "label": "N"}}]', '')"""
        )
    )
    await conn.execute(
        text(
            "INSERT INTO sessions (id, topic_id, topic_version_id, version, source, channel,"
            f" captured_at, notes, meta) VALUES ('{T}3', '{T}1', '{T}2', 1, 'phone', 'ui',"
            " '2026-01-01T08:00:00Z', 'hi', '{}')"
        )
    )
    await conn.execute(
        text(
            "INSERT INTO answers (id, session_id, topic_id, question_key, question_type, position,"
            f" value_int) VALUES ('{T}4', '{T}3', '{T}1', 'n', 'int', 0, 42)"
        )
    )


async def test_upgrade_and_downgrade_preserve_data(clean_db: None) -> None:
    """Upgrade a v1 database holding sessions to head, then back: no data is lost."""
    await _alembic(command.downgrade, INITIAL)
    try:
        async with get_engine().begin() as conn:
            await _insert_v1_data(conn)

        await _alembic(command.upgrade, "head")
        async with get_engine().connect() as conn:
            entry = (
                await conn.execute(text("SELECT id::text, source, channel::text, notes FROM entries"))
            ).one()
            assert tuple(entry) == (f"{T}3", "phone", "ui", "hi")
            answer = (await conn.execute(text("SELECT entry_id::text, value_int FROM answers"))).one()
            assert tuple(answer) == (f"{T}3", 42)
            names = set(
                (
                    await conn.execute(
                        text(
                            "SELECT conname FROM pg_constraint"
                            " WHERE conrelid IN ('entries'::regclass, 'answers'::regclass)"
                        )
                    )
                ).scalars()
            )
            assert {"entries_pkey", "answers_entry_id_fkey", "uq_answer_entry_key"} <= names
            assert not any("session" in n for n in names)
            assert (
                await conn.scalar(text("SELECT count(*) FROM pg_type WHERE typname = 'entry_channel'")) == 1
            )

        await _alembic(command.downgrade, INITIAL)
        async with get_engine().connect() as conn:
            assert tuple((await conn.execute(text("SELECT source, channel::text FROM sessions"))).one()) == (
                "phone",
                "ui",
            )
            assert (await conn.execute(text("SELECT session_id::text FROM answers"))).scalar_one() == f"{T}3"
    finally:
        await _alembic(command.upgrade, "head")


async def _answer(conn: AsyncConnection, n: int, key: str, qtype: str, values: str) -> None:
    await conn.execute(
        text(
            "INSERT INTO answers (id, entry_id, topic_id, question_key, question_type, position,"
            f" value_int, value_str, value_list) VALUES ('{T}{n:x}', '{T}3', '{T}1', '{key}', '{qtype}', 0,"
            f" {values})"
        )
    )


async def test_answer_check_constraint_and_multi_select_downgrade(clean_db: None) -> None:
    from sqlalchemy.exc import IntegrityError

    rename_rev = "a1e2b3c4d5f6"
    await _alembic(command.downgrade, INITIAL)
    async with get_engine().begin() as conn:
        await _insert_v1_data(conn)
    await _alembic(command.upgrade, "head")
    try:
        async with get_engine().begin() as conn:
            await _answer(conn, 5, "one", "enum", "NULL, 'a', NULL")
            await _answer(conn, 6, "many", "enum", "NULL, NULL, ARRAY['a', 'b']")
        # Invalid shapes are rejected by ck_answer_typed_value.
        for n, values in [
            (7, "NULL, 'a', ARRAY['a']"),  # both
            (8, "NULL, NULL, ARRAY[]::text[]"),  # empty list
            (9, "NULL, NULL, NULL"),  # neither
            (10, "1, NULL, ARRAY['a']"),  # int + list
        ]:
            with pytest.raises(IntegrityError):
                async with get_engine().begin() as conn:
                    await _answer(conn, n, f"bad{n}", "enum", values)
        with pytest.raises(IntegrityError):
            async with get_engine().begin() as conn:
                await _answer(conn, 11, "s", "str", "NULL, 'x', ARRAY['x']")

        # v1 cannot represent multi-select answers: downgrade drops only those.
        await _alembic(command.downgrade, rename_rev)
        async with get_engine().connect() as conn:
            keys = (await conn.execute(text("SELECT question_key FROM answers ORDER BY 1"))).scalars().all()
        assert keys == ["n", "one"]
    finally:
        await _alembic(command.upgrade, "head")
