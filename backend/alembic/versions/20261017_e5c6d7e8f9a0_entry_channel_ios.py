"""entry_channel gains 'ios' (the native iOS client)

Revision ID: e5c6d7e8f9a0
Revises: d4b5c6d7e8f9
Create Date: 2026-10-17 09:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e5c6d7e8f9a0"
down_revision: str | Sequence[str] | None = "d4b5c6d7e8f9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # A value added inside a transaction can't be used until it commits, and env.py
    # runs every migration in one transaction: commit it on its own.
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE entry_channel ADD VALUE IF NOT EXISTS 'ios'")


def downgrade() -> None:
    # Postgres can't drop an enum value: rebuild the type. iOS entries become 'api' (lossy).
    op.execute("UPDATE entries SET channel = 'api' WHERE channel = 'ios'")
    op.execute("ALTER TYPE entry_channel RENAME TO entry_channel_old")
    op.execute("CREATE TYPE entry_channel AS ENUM ('ui', 'api', 'mcp')")
    op.execute(
        "ALTER TABLE entries ALTER COLUMN channel TYPE entry_channel USING channel::text::entry_channel"
    )
    op.execute("DROP TYPE entry_channel_old")
