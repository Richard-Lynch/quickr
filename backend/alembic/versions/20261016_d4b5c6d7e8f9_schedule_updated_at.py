"""topics.schedule_updated_at: reference point for due status

Revision ID: d4b5c6d7e8f9
Revises: c3a4b5c6d7e8
Create Date: 2026-10-16 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d4b5c6d7e8f9"
down_revision: str | Sequence[str] | None = "c3a4b5c6d7e8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("topics", sa.Column("schedule_updated_at", sa.DateTime(timezone=True), nullable=True))
    op.execute("UPDATE topics SET schedule_updated_at = created_at WHERE schedule IS NOT NULL")


def downgrade() -> None:
    op.drop_column("topics", "schedule_updated_at")
