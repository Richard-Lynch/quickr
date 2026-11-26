"""topic appearance: ``topics.color``, ``topics.icon`` and ``topics.tags``
(docs/specs/appearance.md §1.2)

Revision ID: f7a4b0c5d326
Revises: e6f3a9b4c215
Create Date: 2026-11-27 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f7a4b0c5d326"
down_revision: str | Sequence[str] | None = "e6f3a9b4c215"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # No index: topic counts are small and list_topics sorts in Python; `?tag=` scans.
    op.add_column("topics", sa.Column("color", sa.String(length=16), nullable=True))
    op.add_column("topics", sa.Column("icon", sa.String(length=16), nullable=True))  # <= 16 code points, NFC
    op.add_column(
        "topics",
        sa.Column(
            "tags",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'[]'::jsonb"),
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column("topics", "tags")
    op.drop_column("topics", "icon")
    op.drop_column("topics", "color")
