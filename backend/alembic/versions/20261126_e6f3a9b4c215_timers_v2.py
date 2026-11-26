"""timers v2: the ``reopen`` and ``remove`` run events, ``run_events.target_id``, and no
tombstones for stopped runs (docs/specs/timers2.md §4.3)

Revision ID: e6f3a9b4c215
Revises: d5e2f8a3c104
Create Date: 2026-11-26 09:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e6f3a9b4c215"
down_revision: str | Sequence[str] | None = "d5e2f8a3c104"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # A value added inside a transaction can't be used until it commits, and env.py runs every
    # migration in one transaction: commit them on their own (the bb9d821fe436 pattern).
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE run_event_type ADD VALUE IF NOT EXISTS 'reopen'")
        op.execute("ALTER TYPE run_event_type ADD VALUE IF NOT EXISTS 'remove'")

    # reopen: the stop it reopens; remove: the pause, lap boundary or reopen it voids.
    op.add_column("run_events", sa.Column("target_id", sa.Uuid(), nullable=True))

    # A stop no longer tombstones its run (a reopen may bring it back); only a discard and a
    # topic delete do. The rows of discarded runs, and of ids with no run row, stay.
    op.execute(
        "DELETE FROM deleted_ids WHERE kind = 'run' AND id IN (SELECT id FROM runs WHERE status = 'stopped')"
    )


def downgrade() -> None:
    # Postgres can't drop enum values, so 'reopen' and 'remove' stay in run_event_type; the
    # deleted tombstones of stopped runs are not restored.
    op.drop_column("run_events", "target_id")
