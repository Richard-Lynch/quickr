"""Home-list vectors for the Swift port: ``shared/fixtures/home-vectors.json``.

The iOS app orders, filters and searches its topic list locally (offline), so it
must reproduce ``list_topics`` (``app/services/topics.py``): the ``due`` sort and
its groups, the SQL sorts with their id tie-break, the status filter and the
ILIKE search over name, slug, description and the current version's question
keys, labels and help texts.

A fixed set of topics (fixed ids and timestamps, inserted straight into the test
database) is listed by the real ``list_topics`` for every case, at a fixed
``NOW``. ``topics`` holds each topic as ``GET /topics/{id}`` returns it, with
``due`` computed at ``NOW``. No wall clock, no randomness.

Names are single words without punctuation, so the ``name`` orders are the same
under the "C" and "en_US.utf8" collations (``meta.collation`` is informational).

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, tzinfo
from typing import Any, Self, get_args
from uuid import UUID

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Channel, Entry, Topic, TopicStatus, TopicVersion
from app.schemas.api import StatusFilter, TopicSort
from app.services.topics import list_topics, topic_details
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "home-vectors.json"
GENERATOR_VERSION = 1
NOW = datetime(2026, 3, 4, 12, 0, tzinfo=UTC)  # a Wednesday
SINCE = datetime(2026, 1, 1, tzinfo=UTC)  # schedules set long ago
UI_SORTS: list[TopicSort] = ["due", "-activity", "-updated", "name", "-name", "-created", "created"]


def at(day: int, hour: int = 0, minute: int = 0, month: int = 3) -> datetime:
    return datetime(2026, month, day, hour, minute, tzinfo=UTC)


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def topic_id(n: int) -> UUID:
    return UUID(f"70b1c000-0000-4000-8000-{n:012x}")


def daily(times: list[str], days: list[int] | None = None) -> dict[str, Any]:
    return {
        "kind": "daily",
        "times": times,
        "days": days or [1, 2, 3, 4, 5, 6, 7],
        "timezone": "UTC",
        "notify": True,
    }


def interval(minutes: int) -> dict[str, Any]:
    return {"kind": "interval", "every_minutes": minutes, "timezone": "UTC", "notify": True}


def q(key: str, label: str, help_text: str | None = None) -> dict[str, Any]:
    return {"key": key, "label": label, "type": "int", "help_text": help_text}


@dataclass
class Spec:
    n: int  # id number; deliberately not in name or insertion order, so tie-breaks show
    name: str
    slug: str
    created: datetime
    updated: datetime
    questions: list[dict[str, Any]]
    description: str = ""
    schedule: dict[str, Any] | None = None
    schedule_since: datetime | None = SINCE  # schedule_updated_at (None: falls back to created_at)
    entries: list[datetime] = field(default_factory=list)
    archived_at: datetime | None = None
    old_questions: list[dict[str, Any]] | None = None  # an earlier version (current is v2)


SPECS: list[Spec] = [
    # --- scheduled, active ---
    Spec(  # due right now (slot == NOW)
        0x31,
        "Water",
        "hydration",
        at(1, month=1),
        at(1, month=1),
        [q("glasses", "Glasses drunk")],
        schedule=daily(["12:00"]),
    ),
    Spec(  # due since 08:00 today; same due_since as Mood (the lower id wins)
        0x12,
        "Sleep",
        "sleep",
        at(2, month=1),
        at(10, month=2),
        [q("hours", "Hours asleep")],
        schedule=daily(["08:00"]),
        entries=[at(3, 7, 30)],
    ),
    Spec(  # due since 08:00 today; v1 had an "anxiety" question, which must not match
        0x23,
        "Mood",
        "mood",
        at(3, month=1),
        at(12, month=2),
        [q("mood", "Mood score")],
        schedule=daily(["08:00"]),
        old_questions=[q("mood", "Mood score"), q("anxiety", "Anxiety level")],
    ),
    Spec(  # weekly (Mondays): due since Monday 09:00; schedule_updated_at null -> created_at
        0x44,
        "Vitamins",
        "vitamins",
        at(10, month=1),
        at(10, month=1),
        [q("count", "Taken", "Count every tablet")],
        schedule=daily(["09:00"], [1]),
        schedule_since=None,
    ),
    Spec(  # interval, due: last entry 09:00 + 2 h -> due since 11:00
        0x05,
        "Stretch",
        "stretch",
        at(5, month=1),
        at(5, month=1),
        [q("bpm", "Heart beats")],
        schedule=interval(120),
        entries=[at(4, 9)],
    ),
    Spec(  # yesterday's 21:00 slot satisfied by a 21:05 entry -> next due later today
        0x56,
        "Journal",
        "journal",
        at(6, month=1),
        at(6, month=1),
        [q("words", "Words written")],
        description="Evening reflections",
        schedule=daily(["21:00"]),
        entries=[at(2, 21), at(3, 21, 5)],
    ),
    Spec(  # Thursdays, set on Sunday: no slot since -> not due, next due tomorrow
        0x67,
        "Run",
        "running-club",
        at(7, month=1),
        at(1),
        [q("km", "Distance")],
        schedule=daily(["07:00"], [4]),
        schedule_since=at(1),
    ),
    Spec(  # Wednesdays, logged today -> next due next week
        0x08,
        "Review",
        "review",
        at(8, month=1),
        at(8, month=1),
        [q("score", "Week score")],
        schedule=daily(["10:00"], [3]),
        entries=[at(4, 10, 30)],
    ),
    Spec(  # interval, not due: last entry 06:00 + 24 h
        0x79,
        "Medication",
        "meds",
        at(9, month=1),
        at(9, month=1),
        [q("dose_mg", "Dose")],
        description="100% adherence",
        schedule=interval(1440),
        entries=[at(4, 6)],
    ),
    Spec(  # never logged, schedule_updated_at null: created 11:00 + 2 h -> not due, next 13:00
        0x8C,  # (a fallback other than created_at, e.g. the distant past, would make it overdue)
        "Walk",
        "walk",
        at(4, 11),
        at(4, 11),
        [q("steps", "Steps")],
        schedule=interval(120),
        schedule_since=None,
    ),
    Spec(  # never logged, schedule set 10:30 + 2 h -> not due, next 12:30
        0x4A,  # (from created_at, long ago, it would be overdue)
        "Yoga",
        "yoga",
        at(2, month=1),
        at(4, 10, 30),
        [q("poses", "Poses")],
        schedule=interval(120),
        schedule_since=at(4, 10, 30),
    ),
    # --- unscheduled, active ---
    Spec(  # activity = last entry (03-03 18:00), equal to cherry's updated_at; cherry's id is lower
        0x9A,
        "apple",
        "apple",
        at(11, month=1),
        at(1, month=2),
        [q("n", "Count")],
        entries=[at(1, 9), at(3, 18)],
    ),
    Spec(  # no entries: activity = updated_at; created together with cherry
        0x2B,
        "Banana",
        "banana",
        at(15, month=1),
        at(20, month=2),
        [q("n", "Count")],
    ),
    Spec(
        0x1C,
        "cherry",
        "cherry",
        at(15, month=1),
        at(3, 18),
        [q("n", "Count")],
    ),
    Spec(  # accented name; the slug doesn't contain "cafe"
        0x4D,
        "Café",
        "espresso",
        at(16, month=1),
        at(16, month=1),
        [q("cups", "Cups")],
    ),
    Spec(  # digits: Step10 before Step9 (character by character, in both collations)
        0x6E,
        "Step10",
        "step10",
        at(17, month=1),
        at(17, month=1),
        [q("n", "Count")],
    ),
    Spec(
        0x3F,
        "Step9",
        "step9",
        at(18, month=1),
        at(18, month=1),
        [q("n", "Count")],
    ),
    # --- archived ---
    Spec(  # scheduled: never due, no next_due_at (due group 1, at the far future)
        0x0A,
        "Habit",
        "habit",
        at(19, month=1),
        at(1, month=2),
        [q("n", "Count")],
        schedule=daily(["08:00"]),
        archived_at=at(1, month=2),
    ),
    Spec(  # unscheduled, with an entry; "water" in its description (status filter)
        0x5B,
        "Retired",
        "retired",
        at(20, month=1),
        at(5, month=2),
        [q("n", "Count")],
        description="Old water tracker",
        entries=[at(1, 10, month=2)],
        archived_at=at(5, month=2),
    ),
]

# name -> (status, sort, q)
CASES: dict[str, tuple[StatusFilter, TopicSort, str | None]] = {
    **{f"active-{s.replace('-', 'desc-')}": ("active", s, None) for s in UI_SORTS},
    "archived-due": ("archived", "due", None),
    "all-due": ("all", "due", None),
    "q-name": ("active", "due", "medic"),
    "q-name-case-insensitive": ("active", "due", "BANANA"),
    "q-slug": ("active", "due", "club"),
    "q-description-whitespace": ("active", "due", "  reflect  "),
    "q-question-key": ("active", "due", "bpm"),
    "q-question-label": ("active", "due", "asleep"),
    "q-question-help-text": ("active", "due", "tablet"),
    "q-old-version-question": ("active", "due", "anxiety"),
    "q-percent-literal": ("active", "due", "%"),
    "q-underscore-literal": ("active", "due", "_"),
    "q-cafe-no-accent-folding": ("active", "due", "cafe"),
    "q-cafe-upper-accented": ("active", "due", "CAFÉ"),
    "q-no-match": ("active", "due", "zzz"),
    "q-whitespace-only": ("active", "due", "   "),  # strips to "": matches every topic
    "q-count-name-sort": ("active", "name", "count"),
    "q-water-all-activity": ("all", "-activity", "water"),
    "q-step-created": ("active", "-created", "step"),
}


class FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz: tzinfo | None = None) -> Self:
        return cls.fromtimestamp(NOW.timestamp(), tz)


async def insert(db: AsyncSession) -> None:
    for spec in SPECS:
        tid = topic_id(spec.n)
        archived = spec.archived_at is not None
        versions = [spec.old_questions, spec.questions] if spec.old_questions else [spec.questions]
        topic = Topic(
            id=tid,
            slug=spec.slug,
            name=spec.name,
            description=spec.description,
            status=TopicStatus.archived if archived else TopicStatus.active,
            current_version=len(versions),
            created_at=spec.created,
            updated_at=spec.updated,
            archived_at=spec.archived_at,
            schedule=spec.schedule,
            schedule_updated_at=spec.schedule_since if spec.schedule is not None else None,
        )
        db.add(topic)
        await db.flush()  # no ORM relationships here: flush parents first
        current: TopicVersion | None = None
        for i, questions in enumerate(versions, start=1):
            current = TopicVersion(
                id=UUID(f"70b1c000-0000-4000-8001-{spec.n:08x}{i:04x}"),
                topic_id=tid,
                version=i,
                questions=questions,
                created_at=spec.created,
            )
            db.add(current)
        await db.flush()
        assert current is not None
        for i, captured in enumerate(spec.entries, start=1):
            db.add(
                Entry(
                    id=UUID(f"70b1c000-0000-4000-8002-{spec.n:08x}{i:04x}"),
                    topic_id=tid,
                    topic_version_id=current.id,
                    version=current.version,
                    source="vectors",
                    channel=Channel.ui,
                    captured_at=captured,
                    created_at=captured,
                    updated_at=captured,
                )
            )
        await db.flush()
    await db.commit()


def check_coverage(topics: dict[str, dict[str, Any]], cases: list[dict[str, Any]]) -> None:
    """The fixture exercises what it claims to (fails if a logic change hollows it out)."""
    dues = [t["due"] for t in topics.values() if t["due"] is not None]
    due_since = [d["due_since"] for d in dues if d["is_due"]]
    assert any(s == iso(NOW) for s in due_since), "a topic due right now"
    assert len(due_since) != len(set(due_since)), "two due topics share due_since"
    assert any(not d["is_due"] and d["next_due_at"] is None for d in dues), "archived scheduled"
    nexts = {d["next_due_at"][:10] for d in dues if not d["is_due"] and d["next_due_at"]}
    assert {"2026-03-04", "2026-03-05", "2026-03-11"} <= nexts, nexts
    activity = [t["last_captured_at"] or t["updated_at"] for t in topics.values() if t["schedule"] is None]
    assert len(activity) != len(set(activity)), "two unscheduled topics with equal activity"
    by_name = {c["name"]: c["expected"] for c in cases}
    for name in ("q-old-version-question", "q-cafe-no-accent-folding", "q-no-match"):
        assert by_name[name] == [], name
    for name in ("q-percent-literal", "q-underscore-literal"):
        assert len(by_name[name]) == 1, name
    assert set(by_name["all-due"]) == set(topics)
    # Never-logged intervals: due state comes from schedule_updated_at, else created_at.
    for n, next_due in ((0x8C, at(4, 13)), (0x4A, at(4, 12, 30))):
        t = topics[str(topic_id(n))]
        assert t["entry_count"] == 0, t["name"]
        assert t["schedule"]["kind"] == "interval", t["name"]
        assert t["due"]["is_due"] is False, t["name"]
        assert t["due"]["next_due_at"] == iso(next_due), t["name"]


async def test_home_vectors_match_committed(db: AsyncSession, monkeypatch: pytest.MonkeyPatch) -> None:
    assert set(UI_SORTS) <= set(get_args(TopicSort))
    monkeypatch.setattr("app.services.topics.datetime", FrozenDatetime)
    await insert(db)
    collation = (
        await db.execute(text("SELECT datcollate FROM pg_database WHERE datname = current_database()"))
    ).scalar_one()

    details = await topic_details(db, [topic_id(s.n) for s in SPECS])
    topics = {str(tid): details[tid].model_dump(mode="json") for tid in sorted(details, key=str)}
    assert len(topics) == len(SPECS)

    cases: list[dict[str, Any]] = []
    for name, (status, sort, query) in CASES.items():
        page = await list_topics(db, q=query, status=status, sort=sort, now=NOW, limit=1000)
        assert page.total == len(page.items), name
        for item in page.items:  # list rows carry the same due state as the details
            assert item.model_dump(mode="json")["due"] == topics[str(item.id)]["due"], name
        expected = [str(item.id) for item in page.items]
        cases.append({"name": name, "status": status, "sort": sort, "q": query, "expected": expected})

    check_coverage(topics, cases)
    doc = {
        "meta": {
            "generator": "backend/tests/test_home_vectors.py",
            "version": GENERATOR_VERSION,
            "now": iso(NOW),
            "collation": collation,
        },
        "topics": list(topics.values()),
        "cases": cases,
    }
    check_or_write(PATH, dump_cases(doc))
