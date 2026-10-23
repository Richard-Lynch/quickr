"""timed topics: topic_versions.timer, entries.timing, runs, run events and aliases, the
``run`` feed kind and Live Activity tokens (docs/specs/timers.md §2, §10.3)

Revision ID: bb9d821fe436
Revises: b8f9a0b1c2d3
Create Date: 2026-10-24 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "bb9d821fe436"
down_revision: str | Sequence[str] | None = "b8f9a0b1c2d3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

run_status = postgresql.ENUM(
    "running", "paused", "finishing", "stopped", "discarded", name="run_status", create_type=False
)
run_event_type = postgresql.ENUM(
    "start", "next", "lap", "skip", "pause", "resume", "stop", "finish", "discard",
    name="run_event_type",
    create_type=False,
)  # fmt: skip
entry_channel = postgresql.ENUM(name="entry_channel", create_type=False)


def upgrade() -> None:
    # A value added inside a transaction can't be used until it commits, and env.py runs every
    # migration in one transaction: commit it on its own.
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE feed_kind ADD VALUE IF NOT EXISTS 'run'")

    op.add_column(
        "topic_versions", sa.Column("timer", postgresql.JSONB(astext_type=sa.Text()), nullable=True)
    )
    op.add_column("entries", sa.Column("timing", postgresql.JSONB(astext_type=sa.Text()), nullable=True))

    run_status.create(op.get_bind())
    run_event_type.create(op.get_bind())
    op.create_table(
        "runs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("topic_id", sa.Uuid(), nullable=False),
        sa.Column("topic_version_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("status", run_status, nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("edited", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("entry_id", sa.Uuid(), nullable=True),
        sa.Column("state", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("source", sa.String(length=100), nullable=False),
        sa.Column("channel", entry_channel, nullable=False),
        sa.Column("revision", sa.Integer(), server_default="1", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["topic_id"], ["topics.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["topic_version_id"], ["topic_versions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ux_runs_one_open",
        "runs",
        ["topic_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('running', 'paused')"),
    )
    op.create_table(
        "run_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("run_id", sa.Uuid(), nullable=False),
        sa.Column("arrival", sa.BigInteger(), sa.Identity(always=False), nullable=False),
        sa.Column("type", run_event_type, nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("seg", sa.Integer(), nullable=True),
        sa.Column("step", sa.String(length=64), nullable=True),
        sa.Column("pause_id", sa.Uuid(), nullable=True),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), server_default="{}", nullable=False),
        sa.Column("source", sa.String(length=100), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["run_id"], ["runs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_run_events_run", "run_events", ["run_id", "arrival"])
    op.create_table(
        "run_aliases",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("run_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(["run_id"], ["runs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "live_activity_tokens",
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("device_token", sa.Text(), nullable=False),
        sa.Column("environment", sa.Text(), nullable=False),
        sa.Column("topic_id", sa.Uuid(), nullable=True),
        sa.Column("run_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("kind IN ('start', 'update')", name="ck_live_activity_tokens_kind"),
        sa.CheckConstraint(
            "environment IN ('sandbox', 'production')", name="ck_live_activity_tokens_environment"
        ),
        sa.PrimaryKeyConstraint("token"),
    )


def downgrade() -> None:
    op.drop_table("live_activity_tokens")
    op.drop_table("run_aliases")
    op.drop_index("ix_run_events_run", table_name="run_events")
    op.drop_table("run_events")
    op.drop_index("ux_runs_one_open", table_name="runs")
    op.drop_table("runs")
    run_event_type.drop(op.get_bind())
    run_status.drop(op.get_bind())

    # Lossy: timed entries become untimed, timed versions untimed.
    op.drop_column("entries", "timing")
    op.drop_column("topic_versions", "timer")

    # Postgres can't drop an enum value: rebuild the type without 'run', dropping run rows from
    # the log and the tombstones first (the runs are gone; their entries stay as entries).
    op.execute("DELETE FROM change_log WHERE kind = 'run'")
    op.execute("DELETE FROM deleted_ids WHERE kind = 'run'")
    op.execute("ALTER TYPE feed_kind RENAME TO feed_kind_old")
    op.execute("CREATE TYPE feed_kind AS ENUM ('entry', 'topic', 'version')")
    for table in ("change_log", "deleted_ids"):
        op.execute(f"ALTER TABLE {table} ALTER COLUMN kind TYPE feed_kind USING kind::text::feed_kind")
    op.execute("DROP TYPE feed_kind_old")
