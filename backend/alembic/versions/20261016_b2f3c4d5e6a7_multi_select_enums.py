"""multi-select enum answers: answers.value_list

Revision ID: b2f3c4d5e6a7
Revises: a1e2b3c4d5f6
Create Date: 2026-10-16 09:10:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b2f3c4d5e6a7"
down_revision: str | Sequence[str] | None = "a1e2b3c4d5f6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

OLD_CHECK = (
    "(question_type = 'int' AND value_int IS NOT NULL AND value_double IS NULL AND value_str IS NULL)"
    " OR (question_type = 'double' AND value_double IS NOT NULL"
    " AND value_int IS NULL AND value_str IS NULL)"
    " OR (question_type IN ('str', 'enum') AND value_str IS NOT NULL"
    " AND value_int IS NULL AND value_double IS NULL)"
)
NEW_CHECK = (
    "(question_type = 'int' AND value_int IS NOT NULL"
    " AND value_double IS NULL AND value_str IS NULL AND value_list IS NULL)"
    " OR (question_type = 'double' AND value_double IS NOT NULL"
    " AND value_int IS NULL AND value_str IS NULL AND value_list IS NULL)"
    " OR (question_type = 'str' AND value_str IS NOT NULL"
    " AND value_int IS NULL AND value_double IS NULL AND value_list IS NULL)"
    " OR (question_type = 'enum' AND value_int IS NULL AND value_double IS NULL AND ("
    "(value_str IS NOT NULL AND value_list IS NULL)"
    " OR (value_str IS NULL AND value_list IS NOT NULL AND cardinality(value_list) > 0)))"
)


def upgrade() -> None:
    op.add_column("answers", sa.Column("value_list", postgresql.ARRAY(sa.Text()), nullable=True))
    op.drop_constraint("ck_answer_typed_value", "answers", type_="check")
    op.create_check_constraint("ck_answer_typed_value", "answers", NEW_CHECK)


def downgrade() -> None:
    # Multi-select answers cannot be represented in v1; drop them rather than fail.
    op.execute("DELETE FROM answers WHERE value_list IS NOT NULL")
    op.drop_constraint("ck_answer_typed_value", "answers", type_="check")
    op.drop_column("answers", "value_list")
    op.create_check_constraint("ck_answer_typed_value", "answers", OLD_CHECK)
