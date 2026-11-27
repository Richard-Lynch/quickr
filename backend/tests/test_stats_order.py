from sqlalchemy import column, func
from sqlalchemy.dialects import postgresql

from app.services.stats import _ordered


def test_float_aggregates_add_their_rows_in_a_fixed_order() -> None:
    # A float avg/sum/stddev depends on the order rows are added in (#199): pin it to the value.
    sql = str(_ordered(func.avg, column("v")).compile(dialect=postgresql.dialect()))  # type: ignore[no-untyped-call]
    assert sql == "avg(v ORDER BY v)"
