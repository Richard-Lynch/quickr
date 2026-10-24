"""live activity token indexes: the sender's lookups by run, topic and device
(docs/specs/timers.md §10.3)

Revision ID: c4a1e7d2f903
Revises: bb9d821fe436
Create Date: 2026-10-24 18:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c4a1e7d2f903"
down_revision: str | Sequence[str] | None = "bb9d821fe436"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index("ix_live_activity_tokens_run", "live_activity_tokens", ["run_id"])
    op.create_index("ix_live_activity_tokens_topic", "live_activity_tokens", ["topic_id"])
    op.create_index("ix_live_activity_tokens_device", "live_activity_tokens", ["device_token"])


def downgrade() -> None:
    op.drop_index("ix_live_activity_tokens_device", table_name="live_activity_tokens")
    op.drop_index("ix_live_activity_tokens_topic", table_name="live_activity_tokens")
    op.drop_index("ix_live_activity_tokens_run", table_name="live_activity_tokens")
