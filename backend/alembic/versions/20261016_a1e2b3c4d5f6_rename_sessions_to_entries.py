"""rename sessions to entries

Pure renames: every row, constraint and enum value is preserved.

Revision ID: a1e2b3c4d5f6
Revises: c05f3d88ef9b
Create Date: 2026-10-16 09:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "a1e2b3c4d5f6"
down_revision: str | Sequence[str] | None = "c05f3d88ef9b"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# (old, new) pairs, applied in order on upgrade and reversed on downgrade.
_TABLE_CONSTRAINTS = [
    ("entries", "sessions_pkey", "entries_pkey"),
    ("entries", "sessions_topic_id_fkey", "entries_topic_id_fkey"),
    ("entries", "sessions_topic_version_id_fkey", "entries_topic_version_id_fkey"),
    ("answers", "answers_session_id_fkey", "answers_entry_id_fkey"),
    ("answers", "uq_answer_session_key", "uq_answer_entry_key"),
]


def _rename_not_null(old: str, new: str) -> None:
    """Postgres 18+ names NOT NULL constraints (``<table>_<column>_not_null``); rename those too."""
    op.execute(
        f"""
        DO $$
        DECLARE r record;
        BEGIN
            FOR r IN
                SELECT conname, conrelid::regclass::text AS tbl FROM pg_constraint
                WHERE contype = 'n' AND conrelid IN ('entries'::regclass, 'answers'::regclass)
                  AND conname LIKE '%{old}%'
            LOOP
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                               r.tbl, r.conname, replace(r.conname, '{old}', '{new}'));
            END LOOP;
        END $$;
        """
    )


def upgrade() -> None:
    op.rename_table("sessions", "entries")
    op.alter_column("answers", "session_id", new_column_name="entry_id")
    for table, old, new in _TABLE_CONSTRAINTS:
        op.execute(f'ALTER TABLE "{table}" RENAME CONSTRAINT "{old}" TO "{new}"')
    _rename_not_null("sessions_", "entries_")
    _rename_not_null("session_id", "entry_id")
    op.execute("ALTER INDEX ix_sessions_topic_captured RENAME TO ix_entries_topic_captured")
    op.execute("ALTER TYPE session_channel RENAME TO entry_channel")


def downgrade() -> None:
    op.execute("ALTER TYPE entry_channel RENAME TO session_channel")
    op.execute("ALTER INDEX ix_entries_topic_captured RENAME TO ix_sessions_topic_captured")
    _rename_not_null("entry_id", "session_id")
    _rename_not_null("entries_", "sessions_")
    for table, old, new in reversed(_TABLE_CONSTRAINTS):
        op.execute(f'ALTER TABLE "{table}" RENAME CONSTRAINT "{new}" TO "{old}"')
    op.alter_column("answers", "entry_id", new_column_name="session_id")
    op.rename_table("entries", "sessions")
