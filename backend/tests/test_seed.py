"""The demo seed script produces valid data and is idempotent."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Entry, Topic
from app.schemas.api import EntryFilters
from app.services import stats as stats_svc
from scripts.seed import DEMOS, seed

NOW = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)


async def test_seed_creates_topics_and_is_idempotent(db: AsyncSession) -> None:
    created = await seed(db, days=30, now=NOW)
    assert created == [d.slug for d in DEMOS]
    entries = (await db.execute(select(func.count(Entry.id)))).scalar_one()
    assert entries > 60

    for slug in created:
        stats = await stats_svc.topic_stats(db, slug, EntryFilters())
        assert stats.entry_count > 0
        assert stats.last_captured_at is not None
        assert stats.last_captured_at <= NOW
        assert stats.sources[0].value == "seed"

    assert await seed(db, days=30, now=NOW) == []
    assert (await db.execute(select(func.count(Entry.id)))).scalar_one() == entries
    assert (await db.execute(select(func.count(Topic.id)))).scalar_one() == len(DEMOS)
