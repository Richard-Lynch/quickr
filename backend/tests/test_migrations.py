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


SCHEDULE_JSON = '{"kind": "interval", "every_minutes": 60, "timezone": "UTC", "notify": true}'


async def test_schedule_updated_at_backfilled_from_created_at(clean_db: None) -> None:
    await _alembic(command.downgrade, INITIAL)
    try:
        async with get_engine().begin() as conn:
            await _insert_v1_data(conn)
            await conn.execute(
                text(
                    "INSERT INTO topics (id, slug, name, description, status, current_version, created_at)"
                    f" VALUES ('{T}9', 'plain', 'Plain', '', 'active', 1, '2026-01-01T00:00:00Z')"
                )
            )
        await _alembic(command.upgrade, "c3a4b5c6d7e8")  # schedules exist, the reference point does not
        async with get_engine().begin() as conn:
            await conn.execute(
                text("UPDATE topics SET schedule = CAST(:s AS jsonb) WHERE slug = 'demo'"),
                {"s": SCHEDULE_JSON},
            )
        await _alembic(command.upgrade, "head")
        async with get_engine().connect() as conn:
            result = await conn.execute(text("SELECT slug, schedule_updated_at = created_at FROM topics"))
            rows = {row[0]: row[1] for row in result}  # dict(result) would use Result.keys()
        assert rows == {"demo": True, "plain": None}  # unscheduled topics stay NULL
    finally:
        await _alembic(command.upgrade, "head")


async def test_ios_channel_downgrade_remaps_to_api(clean_db: None) -> None:
    """``alembic check`` ignores enum values, so the rebuild of entry_channel is tested directly."""
    ios_rev, before_ios = "e5c6d7e8f9a0", "d4b5c6d7e8f9"
    await _alembic(command.downgrade, ios_rev)
    try:
        async with get_engine().begin() as conn:
            await _insert_v1_data_at_head(conn, channel="ios")
        await _alembic(command.downgrade, before_ios)
        async with get_engine().connect() as conn:
            assert (await conn.scalar(text("SELECT channel::text FROM entries"))) == "api"
            labels = (
                await conn.execute(text("SELECT unnest(enum_range(NULL::entry_channel))::text"))
            ).scalars()
            assert list(labels) == ["ui", "api", "mcp"]
            assert not await conn.scalar(text("SELECT 1 FROM pg_type WHERE typname = 'entry_channel_old'"))
        await _alembic(command.upgrade, ios_rev)
        async with get_engine().begin() as conn:
            await conn.execute(text("UPDATE entries SET channel = 'ios'"))
            assert (await conn.scalar(text("SELECT channel::text FROM entries"))) == "ios"
    finally:
        await _alembic(command.upgrade, "head")


async def _insert_v1_data_at_head(conn: AsyncConnection, channel: str) -> None:
    """One topic, version and entry (entries table, current column set)."""
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
            "INSERT INTO entries (id, topic_id, topic_version_id, version, source, channel,"
            f" captured_at, notes, meta) VALUES ('{T}3', '{T}1', '{T}2', 1, 'phone', '{channel}',"
            " '2026-01-01T08:00:00Z', '', '{}')"
        )
    )


async def test_change_feed_backfill(clean_db: None) -> None:
    """Existing data gets one upsert row per entity, so a fresh client bootstraps from after=0."""
    from app.db import get_sessionmaker
    from app.services.changes import list_changes

    before_feed = "e5c6d7e8f9a0"
    await _alembic(command.downgrade, before_feed)
    try:
        async with get_engine().begin() as conn:
            await _insert_v1_data_at_head(conn, channel="ios")
        await _alembic(command.upgrade, "head")
        async with get_engine().connect() as conn:
            rows = (
                await conn.execute(text("SELECT seq, kind::text, op::text, entity_id::text FROM change_log"))
            ).all()
            assert [tuple(r) for r in rows] == [
                (1, "topic", "upsert", f"{T}1"),
                (2, "version", "upsert", f"{T}2"),
                (3, "entry", "upsert", f"{T}3"),
            ]
            revisions = (
                await conn.execute(
                    text("SELECT (SELECT revision FROM topics), (SELECT revision FROM entries)")
                )
            ).one()
            assert tuple(revisions) == (1, 1)
        async with get_sessionmaker()() as db:
            page = await list_changes(db)
        assert [i.kind for i in page.items] == ["topic", "version", "entry"]
        assert (page.next, page.head, page.has_more) == (3, 3, False)
        first = (page.epoch, page.server_id)

        # A downgrade + upgrade rebuilds the log from seq 1: a new epoch, the same server.
        await _alembic(command.downgrade, before_feed)
        await _alembic(command.upgrade, "head")
        async with get_sessionmaker()() as db:
            page = await list_changes(db)
        assert page.epoch != first[0]
        assert page.server_id == first[1]
    finally:
        await _alembic(command.upgrade, "head")


async def _insert_run(conn: AsyncConnection, n: int, status: str) -> None:
    await conn.execute(
        text(
            "INSERT INTO runs (id, topic_id, topic_version_id, version, status, started_at, state, source,"
            f" channel) VALUES ('{T}{n:x}', '{T}1', '{T}2', 1, '{status}', '2026-01-01T08:00:00Z', '{{}}',"
            " 'phone', 'ios')"
        )
    )


async def test_timed_topics_round_trip(clean_db: None) -> None:
    """Upgrade a seeded database to the timed-topics schema, use it, and downgrade it again."""
    from sqlalchemy.exc import IntegrityError

    before = "b8f9a0b1c2d3"
    await _alembic(command.downgrade, before)
    try:
        async with get_engine().begin() as conn:
            await _insert_v1_data_at_head(conn, channel="ios")
        await _alembic(command.upgrade, "head")
        async with get_engine().begin() as conn:
            row = (await conn.execute(text("SELECT timer FROM topic_versions"))).one()
            assert tuple(row) == (None,)
            assert (await conn.scalar(text("SELECT timing FROM entries"))) is None
            await conn.execute(text("""UPDATE topic_versions SET timer = '{"steps": []}'"""))
            await _insert_run(conn, 5, "stopped")
            await _insert_run(conn, 6, "running")
            await conn.execute(
                text(
                    "INSERT INTO run_events (id, run_id, type, at, source)"
                    f" VALUES ('{T}7', '{T}6', 'start', '2026-01-01T08:00:00Z', 'phone'),"
                    f" ('{T}8', '{T}6', 'lap', '2026-01-01T08:01:00Z', 'phone')"
                )
            )
            await conn.execute(text(f"INSERT INTO run_aliases (id, run_id) VALUES ('{T}9', '{T}6')"))
            await conn.execute(
                text(
                    "INSERT INTO live_activity_tokens (token, kind, device_token, environment, topic_id,"
                    f" run_id) VALUES ('ab', 'update', 'cd', 'sandbox', '{T}1', '{T}6')"
                )
            )
            await conn.execute(
                text(
                    f"INSERT INTO change_log (kind, op, entity_id, topic_id)"
                    f" VALUES ('entry', 'upsert', '{T}3', '{T}1'), ('run', 'upsert', '{T}6', '{T}1')"
                )
            )
            await conn.execute(
                text(f"INSERT INTO deleted_ids (kind, id, topic_id) VALUES ('run', '{T}5', '{T}1')")
            )
            arrivals = (
                (await conn.execute(text("SELECT arrival FROM run_events ORDER BY id"))).scalars().all()
            )
            assert arrivals[0] < arrivals[1]
            assert (await conn.scalar(text("SELECT payload FROM run_events LIMIT 1"))) == {}
        # One open (running or paused) run per topic.
        with pytest.raises(IntegrityError):
            async with get_engine().begin() as conn:
                await _insert_run(conn, 10, "paused")
        async with get_engine().begin() as conn:
            await _insert_run(conn, 10, "finishing")
        with pytest.raises(IntegrityError):
            async with get_engine().begin() as conn:
                await conn.execute(
                    text(
                        "INSERT INTO live_activity_tokens (token, kind, device_token, environment)"
                        " VALUES ('ef', 'other', 'cd', 'sandbox')"
                    )
                )
        # Deleting a topic takes its runs, their events and aliases with it.
        async with get_engine().begin() as conn:
            for sql in (
                "INSERT INTO topics (id, slug, name, description, status, current_version)"
                f" VALUES ('{T}b', 'gone', 'Gone', '', 'active', 1)",
                "INSERT INTO topic_versions (id, topic_id, version, questions, change_note)"
                f" VALUES ('{T}c', '{T}b', 1, '[]', '')",
                "INSERT INTO runs (id, topic_id, topic_version_id, version, status, started_at, state,"
                f" source, channel) VALUES ('{T}d', '{T}b', '{T}c', 1, 'running', '2026-01-01T08:00:00Z',"
                " '{}', 'phone', 'ui')",
                f"INSERT INTO run_events (id, run_id, type, at, source) VALUES ('{T}e', '{T}d', 'start',"
                " '2026-01-01T08:00:00Z', 'phone')",
                f"INSERT INTO run_aliases (id, run_id) VALUES ('{T}f', '{T}d')",
            ):
                await conn.execute(text(sql))
            await conn.execute(text(f"DELETE FROM topics WHERE id = '{T}b'"))
            for table, key in (("runs", "d"), ("run_events", "e"), ("run_aliases", "f")):
                assert await conn.scalar(text(f"SELECT count(*) FROM {table} WHERE id = '{T}{key}'")) == 0
            assert await conn.scalar(text("SELECT count(*) FROM runs")) == 3  # the other topic's

        await _alembic(command.downgrade, before)
        async with get_engine().connect() as conn:
            tables = set(
                (
                    await conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))
                ).scalars()
            )
            assert not tables & {"runs", "run_events", "run_aliases", "live_activity_tokens"}
            types = set((await conn.execute(text("SELECT typname FROM pg_type"))).scalars())
            assert not types & {"run_status", "run_event_type", "feed_kind_old"}
            labels = (await conn.execute(text("SELECT unnest(enum_range(NULL::feed_kind))::text"))).scalars()
            assert list(labels) == ["entry", "topic", "version"]
            assert (await conn.scalar(text("SELECT count(*) FROM change_log WHERE kind = 'entry'"))) == 1
            assert (await conn.scalar(text("SELECT count(*) FROM deleted_ids"))) == 0
            entry = (await conn.execute(text("SELECT id::text, channel::text FROM entries"))).one()
            assert tuple(entry) == (f"{T}3", "ios")
        await _alembic(command.upgrade, "head")
        async with get_engine().connect() as conn:
            assert (await conn.scalar(text("SELECT timer FROM topic_versions"))) is None
            assert (await conn.scalar(text("SELECT count(*) FROM runs"))) == 0
    finally:
        await _alembic(command.upgrade, "head")
