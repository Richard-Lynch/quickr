"""Topic entry-list vectors for the Swift port: ``shared/fixtures/entries-vectors.json``.

The iOS app lists a topic's entries offline, from its local store, so it must
reproduce ``list_entries`` (``app/services/entries.py``): ``apply_filters``
(``captured_at >= captured_from``, inclusive; exact ``version`` and ``source``)
and ``ORDER BY captured_at DESC, id ASC``. It also shows the ``sources`` of
``topic_stats`` (``app/services/stats.py``): ``GROUP BY source ORDER BY count
DESC``.

One topic with three versions and fixed entries (fixed ids and timestamps,
inserted straight into the test database) is listed by the real
``list_entries`` for every case. No wall clock, no randomness.

Several entries share a ``captured_at``; their ids are neither in insertion
order nor in descending order, so only the ``id ASC`` tie-break gives the
expected order. Source counts are all distinct: the server breaks no ties
between equal counts (the SQL order is undefined there), so the data has none.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Answer, Channel, Entry, Topic, TopicStatus, TopicVersion
from app.schemas.api import EntryFilters
from app.services.entries import list_entries
from app.services.stats import topic_stats
from app.services.topics import topic_details
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "entries-vectors.json"
GENERATOR_VERSION = 1
TOPIC_ID = UUID("e0710000-0000-4000-8000-000000000001")
SLUG = "energy"
CREATED = datetime(2000, 6, 1, tzinfo=UTC)
LIMIT = 500


def at(
    day: int, hour: int = 0, minute: int = 0, second: int = 0, month: int = 3, year: int = 2026
) -> datetime:
    return datetime(year, month, day, hour, minute, second, tzinfo=UTC)


def entry_id(n: int) -> UUID:
    return UUID(f"e0710000-0000-4000-8002-{n:012x}")


def version_id(v: int) -> UUID:
    return UUID(f"e0710000-0000-4000-8001-{v:012x}")


# Boundaries the captured_from cases sit on (an entry exactly at each, one 1 s before).
BOUNDARY = at(10, 8)  # 2026-03-10T08:00:00Z = 10:00+02:00 = 03:00-05:00
DAY_BOUNDARY = at(6)  # 2026-03-06T00:00:00Z = 2026-03-05T19:00-05:00
TIE = at(8, 12)  # five entries share this instant

QUESTIONS: dict[int, list[dict[str, Any]]] = {
    1: [{"key": "level", "label": "Energy level", "type": "int"}],
    2: [
        {"key": "level", "label": "Energy level", "type": "int"},
        {"key": "slept", "label": "Slept", "type": "int"},
    ],
    3: [{"key": "level", "label": "Energy", "type": "int"}],
}


@dataclass
class Spec:
    n: int  # id number; deliberately not in time or insertion order, so the tie-break shows
    captured: datetime
    version: int
    source: str
    notes: str = ""


# Insertion order. Sources: ui 9, shortcut 6, mcp 3, import 2 (distinct counts).
SPECS: list[Spec] = [
    # --- version 1 ---
    Spec(0x14, at(1, month=1, year=2001), 1, "import", "backfilled"),  # far in the past
    Spec(0x02, at(1, 9), 1, "ui"),
    Spec(0x13, at(2, 9), 1, "import"),
    Spec(0x09, at(5, 23, 59, 59), 1, "shortcut"),  # 1 s before DAY_BOUNDARY
    Spec(0x0E, DAY_BOUNDARY, 1, "ui"),  # exactly at DAY_BOUNDARY
    # --- version 2 ---
    Spec(0x05, at(7, 10), 2, "mcp"),
    Spec(0x0B, TIE, 2, "ui"),  # tie group: inserted 0b, 03, 11, 07, 0f; id ASC 03, 07, 0b, 0f, 11
    Spec(0x03, TIE, 2, "ui"),
    Spec(0x11, TIE, 2, "shortcut"),
    Spec(0x07, TIE, 2, "ui"),
    Spec(0x0F, TIE, 2, "mcp"),
    Spec(0x0A, at(10, 7, 59, 59), 2, "shortcut"),  # 1 s before BOUNDARY
    Spec(0x01, BOUNDARY, 2, "ui"),  # exactly at BOUNDARY (with 0x12)
    # --- version 3 ---
    Spec(0x12, BOUNDARY, 3, "shortcut"),
    Spec(0x06, at(11, 8), 3, "ui"),
    Spec(0x10, at(12, 8), 3, "shortcut"),  # tie with 0x04
    Spec(0x04, at(12, 8), 3, "ui"),
    Spec(0x0C, at(13, 8), 3, "mcp"),
    Spec(0x08, at(14, 8), 3, "ui"),
    Spec(0x0D, at(15, 8), 3, "shortcut"),
]

# name -> (captured_from as the client sends it, version, source)
CASES: dict[str, tuple[str | None, int | None, str | None]] = {
    "no-filters": (None, None, None),
    "from-boundary-utc": ("2026-03-10T08:00:00Z", None, None),
    "from-boundary-plus-0200": ("2026-03-10T10:00:00+02:00", None, None),
    "from-boundary-minus-0500": ("2026-03-10T03:00:00-05:00", None, None),
    "from-boundary-minus-1s": ("2026-03-10T07:59:59Z", None, None),
    "from-boundary-fraction-before": ("2026-03-10T07:59:59.500000Z", None, None),
    "from-day-boundary-minus-0500": ("2026-03-05T19:00:00-05:00", None, None),
    "from-tie-instant-plus-0530": ("2026-03-08T17:30:00+05:30", None, None),
    "from-before-far-past": ("2000-01-01T00:00:00Z", None, None),
    "from-after-far-past": ("2001-01-01T00:00:01Z", None, None),
    "version-1": (None, 1, None),
    "version-2": (None, 2, None),
    "version-3": (None, 3, None),
    "source-ui": (None, None, "ui"),
    "source-mcp": (None, None, "mcp"),
    "source-import": (None, None, "import"),
    "version-2-source-ui": (None, 2, "ui"),
    "version-3-source-shortcut": (None, 3, "shortcut"),
    "from-version-source": ("2026-03-10T03:00:00-05:00", 3, "shortcut"),
    "from-version-source-plus-0200": ("2026-03-08T14:00:00+02:00", 2, "ui"),
    "none-version": (None, 9, None),
    "none-source-case-sensitive": (None, None, "UI"),
    "none-from-future": ("2030-01-01T00:00:00+02:00", None, None),
    "none-version-source": (None, 1, "mcp"),
}


async def insert(db: AsyncSession) -> None:
    db.add(
        Topic(
            id=TOPIC_ID,
            slug=SLUG,
            name="Energy",
            description="How energetic I feel",
            status=TopicStatus.active,
            current_version=len(QUESTIONS),
            created_at=CREATED,
            updated_at=at(1),
        )
    )
    await db.flush()  # no ORM relationships here: flush parents first
    for v, questions in QUESTIONS.items():
        db.add(
            TopicVersion(
                id=version_id(v), topic_id=TOPIC_ID, version=v, questions=questions, created_at=CREATED
            )
        )
    await db.flush()
    for i, spec in enumerate(SPECS, start=1):
        db.add(
            Entry(
                id=entry_id(spec.n),
                topic_id=TOPIC_ID,
                topic_version_id=version_id(spec.version),
                version=spec.version,
                source=spec.source,
                channel=Channel.mcp if spec.source == "mcp" else Channel.ui,
                captured_at=spec.captured,
                created_at=spec.captured,
                updated_at=spec.captured,
                notes=spec.notes,
                answers=[
                    Answer(
                        topic_id=TOPIC_ID,
                        question_key="level",
                        question_type="int",
                        position=0,
                        value_int=i % 5,
                    )
                ],
            )
        )
        await db.flush()
    await db.commit()


def check_coverage(
    entries: list[dict[str, Any]], cases: list[dict[str, Any]], sources: list[dict[str, Any]]
) -> None:
    """The fixture exercises what it claims to (fails if a data or logic change hollows it out)."""
    by_name = {c["name"]: c["expected"] for c in cases}
    by_id = {e["id"]: e for e in entries}
    assert len(entries) == len(SPECS) == len(by_name["no-filters"])

    # Identical captured_at: id ASC differs from insertion order and from id DESC.
    tie = [str(entry_id(s.n)) for s in SPECS if s.captured == TIE]
    listed = [i for i in by_name["no-filters"] if i in tie]
    assert len(tie) >= 3
    assert listed == sorted(tie) != tie, "tie broken by id ASC, not insertion order"
    assert listed != sorted(tie, reverse=True)

    # Every version has entries; source counts are distinct and in descending order.
    assert {e["version"] for e in entries} == set(QUESTIONS)
    counts = [s["count"] for s in sources]
    assert counts == sorted(counts, reverse=True), sources
    assert len(set(counts)) == len(counts) >= 3, sources
    assert sum(counts) == len(entries)

    # captured_from is inclusive: the entry at the boundary is in, the one 1 s before is out.
    def captured(i: str) -> datetime:
        return datetime.fromisoformat(by_id[i]["captured_at"])

    for name, boundary in (
        ("from-boundary-utc", BOUNDARY),
        ("from-boundary-plus-0200", BOUNDARY),
        ("from-boundary-minus-0500", BOUNDARY),
        ("from-day-boundary-minus-0500", DAY_BOUNDARY),
    ):
        got = by_name[name]
        assert any(captured(i) == boundary for i in got), name
        assert all(captured(i) >= boundary for i in got), name
        missing = [e["id"] for e in entries if e["id"] not in got]
        assert any(boundary - captured(i) == timedelta(seconds=1) for i in missing), name
    assert (
        by_name["from-boundary-plus-0200"]
        == by_name["from-boundary-minus-0500"]
        == by_name["from-boundary-utc"]
    )
    assert len(by_name["from-boundary-minus-1s"]) == len(by_name["from-boundary-utc"]) + 1
    assert by_name["from-boundary-fraction-before"] == by_name["from-boundary-utc"]
    assert len(by_name["from-before-far-past"]) == len(entries) == len(by_name["from-after-far-past"]) + 1

    # Combined filters narrow, and keep the tie-break.
    tie_ui = [i for i in by_name["version-2-source-ui"] if i in tie]
    assert len(tie_ui) >= 2
    assert tie_ui == sorted(tie_ui)
    for name, expected in by_name.items():
        if name.startswith("none-"):
            assert expected == [], name
        else:
            assert expected, name


async def test_entries_vectors_match_committed(db: AsyncSession) -> None:
    await insert(db)
    details = await topic_details(db, [TOPIC_ID])
    topic = details[TOPIC_ID].model_dump(mode="json")

    full = await list_entries(db, SLUG, EntryFilters(), order="-captured_at", limit=LIMIT)
    by_id = {str(e.id): e.model_dump(mode="json") for e in full.items}
    entries = [by_id[str(entry_id(s.n))] for s in SPECS]  # insertion order: not sorted by anything

    cases: list[dict[str, Any]] = []
    for name, (captured_from, version, source) in CASES.items():
        filters = {"captured_from": captured_from, "version": version, "source": source}
        page = await list_entries(
            db, SLUG, EntryFilters.model_validate(filters), order="-captured_at", limit=LIMIT
        )
        assert page.total == len(page.items), name
        cases.append({"name": name, "filters": filters, "expected": [str(e.id) for e in page.items]})

    stats = await topic_stats(db, SLUG, EntryFilters())
    sources = [s.model_dump(mode="json") for s in stats.sources]

    check_coverage(entries, cases, sources)
    doc = {
        "meta": {"generator": "backend/tests/test_entries_vectors.py", "version": GENERATOR_VERSION},
        "topic": topic,
        "entries": entries,
        "cases": cases,
        "sources": sources,
    }
    check_or_write(PATH, dump_cases(doc))
