"""push slot deliveries: per-target progress of a due slot's fan-out

Revision ID: b8f9a0b1c2d3
Revises: a7e8f9a0b1c2
Create Date: 2026-10-18 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b8f9a0b1c2d3"
down_revision: str | Sequence[str] | None = "a7e8f9a0b1c2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "push_slot_deliveries",
        sa.Column("topic_id", sa.Uuid(), nullable=False),
        sa.Column("due_since", sa.DateTime(timezone=True), nullable=False),
        sa.Column("target_kind", sa.String(length=8), nullable=False),
        sa.Column("target_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("target_kind IN ('web', 'apns')", name="ck_push_slot_deliveries_target_kind"),
        sa.ForeignKeyConstraint(["topic_id"], ["topics.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("topic_id", "due_since", "target_kind", "target_id"),
    )


def downgrade() -> None:
    op.drop_table("push_slot_deliveries")
