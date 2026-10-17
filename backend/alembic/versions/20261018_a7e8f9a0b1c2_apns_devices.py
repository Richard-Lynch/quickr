"""apns devices

Revision ID: a7e8f9a0b1c2
Revises: f6d7e8f9a0b1
Create Date: 2026-10-18 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a7e8f9a0b1c2"
down_revision: str | Sequence[str] | None = "f6d7e8f9a0b1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "apns_devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("environment", sa.String(length=16), nullable=False),
        sa.Column("bundle_id", sa.String(length=155), nullable=True),
        sa.Column("app_version", sa.String(length=64), nullable=True),
        sa.Column("device_name", sa.String(length=200), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("last_success_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("failure_count", sa.Integer(), server_default="0", nullable=False),
        sa.CheckConstraint("environment IN ('sandbox', 'production')", name="ck_apns_devices_environment"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token"),
    )


def downgrade() -> None:
    op.drop_table("apns_devices")
