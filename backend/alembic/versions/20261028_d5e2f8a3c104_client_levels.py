"""client levels: the app's API level on APNs devices and Live Activity tokens
(docs/specs/client-versions.md §3.4)

Revision ID: d5e2f8a3c104
Revises: c4a1e7d2f903
Create Date: 2026-10-28 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d5e2f8a3c104"
down_revision: str | Sequence[str] | None = "c4a1e7d2f903"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Existing rows came from builds before the mechanism: level 0.
    op.add_column("apns_devices", sa.Column("client_level", sa.Integer(), server_default="0", nullable=False))
    op.add_column(
        "live_activity_tokens", sa.Column("client_level", sa.Integer(), server_default="0", nullable=False)
    )


def downgrade() -> None:
    op.drop_column("live_activity_tokens", "client_level")
    op.drop_column("apns_devices", "client_level")
