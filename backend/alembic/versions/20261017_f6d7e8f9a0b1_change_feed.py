"""change feed: change_log, deleted_ids, revisions, feed epoch and server id

Backfills one upsert row per existing topic, version and entry, so a fresh client
bootstraps from ``GET /changes?after=0``.

Revision ID: f6d7e8f9a0b1
Revises: e5c6d7e8f9a0
Create Date: 2026-10-17 09:30:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f6d7e8f9a0b1"
down_revision: str | Sequence[str] | None = "e5c6d7e8f9a0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

feed_kind = postgresql.ENUM("entry", "topic", "version", name="feed_kind", create_type=False)
feed_op = postgresql.ENUM("upsert", "delete", name="feed_op", create_type=False)


def upgrade() -> None:
    feed_kind.create(op.get_bind())
    feed_op.create(op.get_bind())
    op.create_table(
        "change_log",
        sa.Column("seq", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("kind", feed_kind, nullable=False),
        sa.Column("op", feed_op, nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("topic_id", sa.Uuid(), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("seq"),
    )
    op.create_table(
        "deleted_ids",
        sa.Column("kind", feed_kind, nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("topic_id", sa.Uuid(), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("kind", "id"),
    )
    for table in ("topics", "entries"):
        op.add_column(table, sa.Column("revision", sa.Integer(), server_default="1", nullable=False))

    # Parents first, so a client applying the bootstrap in seq order never sees an orphan.
    op.execute(
        "INSERT INTO change_log (kind, op, entity_id, topic_id)"
        " SELECT 'topic', 'upsert', id, id FROM topics ORDER BY created_at, id"
    )
    op.execute(
        "INSERT INTO change_log (kind, op, entity_id, topic_id)"
        " SELECT 'version', 'upsert', id, topic_id FROM topic_versions ORDER BY created_at, id"
    )
    op.execute(
        "INSERT INTO change_log (kind, op, entity_id, topic_id)"
        " SELECT 'entry', 'upsert', id, topic_id FROM entries ORDER BY created_at, id"
    )
    op.execute(
        "INSERT INTO app_settings (key, value) VALUES"
        " ('feed_epoch', gen_random_uuid()::text), ('server_id', gen_random_uuid()::text)"
        " ON CONFLICT (key) DO NOTHING"
    )


def downgrade() -> None:
    # The log restarts from seq 1 on the next upgrade, so that needs a new epoch. The server
    # id stays: it is still the same server.
    op.execute("DELETE FROM app_settings WHERE key = 'feed_epoch'")
    for table in ("topics", "entries"):
        op.drop_column(table, "revision")
    op.drop_table("deleted_ids")
    op.drop_table("change_log")
    feed_op.drop(op.get_bind())
    feed_kind.drop(op.get_bind())
