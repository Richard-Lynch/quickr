"""Seed demo topics with ~30 days of entries, via the service layer.

Idempotent: topics whose slug already exists are skipped untouched.

    PYTHONPATH=. uv run python scripts/seed.py [--days 30]
"""

from __future__ import annotations

import argparse
import asyncio
import random
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from pydantic import TypeAdapter
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_engine, get_sessionmaker
from app.models import Channel, Topic
from app.schemas.api import EntryCreate, TopicCreate
from app.schemas.questions import AnswerValue, Question
from app.services import entries as entry_svc
from app.services import topics as topic_svc

_questions: TypeAdapter[list[Question]] = TypeAdapter(list[Question])

Answers = dict[str, AnswerValue | None]


@dataclass(frozen=True)
class Demo:
    slug: str
    name: str
    description: str
    questions: list[dict[str, Any]]
    # (rng, day) -> list of (hour offset within the day, answers, notes)
    entries: Callable[[random.Random, datetime], list[tuple[float, Answers, str]]]


def _sleep(rng: random.Random, _day: datetime) -> list[tuple[float, Answers, str]]:
    hours = round(min(max(rng.gauss(7.2, 0.9), 3.5), 10.5), 1)
    wakeups = max(0, int(rng.gauss(1.2, 1.0)))
    quality = "great" if hours >= 8 and wakeups == 0 else "poor" if hours < 6 or wakeups >= 3 else "ok"
    dream = rng.choice([None, None, None, "Flying over the city", "Late for an exam", "Back at school"])
    return [(7.5, {"hours": hours, "wakeups": wakeups, "quality": quality, "dream": dream}, "")]


def _workout(rng: random.Random, day: datetime) -> list[tuple[float, Answers, str]]:
    if day.weekday() in (2, 6) or rng.random() < 0.25:
        return []  # rest day
    kind = rng.choice(["run", "run", "strength", "yoga"])
    duration = {"run": rng.randint(25, 60), "strength": rng.randint(40, 75), "yoga": rng.randint(20, 45)}[
        kind
    ]
    distance = round(duration / rng.uniform(5.2, 6.5), 2) if kind == "run" else None
    rpe = {"run": rng.randint(5, 9), "strength": rng.randint(6, 9), "yoga": rng.randint(2, 5)}[kind]
    notes = rng.choice(["", "", "Felt strong", "Legs heavy", "New PB!"])
    answers: Answers = {"kind": kind, "duration_min": duration, "distance_km": distance, "rpe": rpe}
    return [(18.0, answers, notes)]


def _mood(rng: random.Random, _day: datetime) -> list[tuple[float, Answers, str]]:
    out: list[tuple[float, Answers, str]] = []
    for hour in (9.0, 21.0) if rng.random() < 0.6 else (13.0,):
        mood = min(5, max(1, round(rng.gauss(3.6, 0.9))))
        energy = "high" if mood >= 4 and rng.random() < 0.6 else "low" if mood <= 2 else "medium"
        note = rng.choice([None, None, "Busy day at work", "Coffee with a friend", "Tired"])
        out.append((hour, {"mood": mood, "energy": energy, "note": note}, ""))
    return out


DEMOS = [
    Demo(
        slug="sleep-log",
        name="Sleep log",
        description="How long and how well I slept last night.",
        questions=[
            {
                "key": "hours",
                "label": "Hours slept",
                "type": "double",
                "min": 0,
                "max": 24,
                "decimals": 1,
                "unit": "h",
            },
            {"key": "wakeups", "label": "Times woken up", "type": "int", "min": 0, "max": 20},
            {
                "key": "quality",
                "label": "Sleep quality",
                "type": "enum",
                "options": [
                    {"value": "poor", "label": "Poor"},
                    {"value": "ok", "label": "OK"},
                    {"value": "great", "label": "Great"},
                ],
            },
            {"key": "dream", "label": "Dreams", "type": "str", "required": False, "multiline": True},
        ],
        entries=_sleep,
    ),
    Demo(
        slug="workout",
        name="Workout",
        description="Training entries: type, duration and effort.",
        questions=[
            {
                "key": "kind",
                "label": "Workout type",
                "type": "enum",
                "options": [
                    {"value": "run", "label": "Run"},
                    {"value": "strength", "label": "Strength"},
                    {"value": "yoga", "label": "Yoga"},
                ],
            },
            {"key": "duration_min", "label": "Duration", "type": "int", "min": 1, "max": 600, "unit": "min"},
            {
                "key": "distance_km",
                "label": "Distance",
                "type": "double",
                "min": 0,
                "decimals": 2,
                "unit": "km",
                "required": False,
            },
            {
                "key": "rpe",
                "label": "Perceived effort (RPE)",
                "help_text": "1 = very easy, 10 = maximal effort",
                "type": "int",
                "min": 1,
                "max": 10,
            },
        ],
        entries=_workout,
    ),
    Demo(
        slug="mood-check-in",
        name="Mood check-in",
        description="Quick mood and energy check, once or twice a day.",
        questions=[
            {"key": "mood", "label": "Mood (1-5)", "type": "int", "min": 1, "max": 5},
            {
                "key": "energy",
                "label": "Energy",
                "type": "enum",
                "options": [
                    {"value": "low", "label": "Low"},
                    {"value": "medium", "label": "Medium"},
                    {"value": "high", "label": "High"},
                ],
            },
            {"key": "note", "label": "What's going on?", "type": "str", "required": False, "max_length": 280},
        ],
        entries=_mood,
    ),
]


async def seed(db: AsyncSession, *, days: int = 30, now: datetime | None = None) -> list[str]:
    """Create the demo topics that don't exist yet. Returns the slugs created."""
    now = now or datetime.now(UTC)
    start = (now - timedelta(days=days)).replace(hour=0, minute=0, second=0, microsecond=0)
    existing = set((await db.execute(select(Topic.slug))).scalars())
    created: list[str] = []
    for demo in DEMOS:
        if demo.slug in existing:
            continue
        await topic_svc.create_topic(
            db,
            TopicCreate(
                name=demo.name,
                slug=demo.slug,
                description=demo.description,
                questions=_questions.validate_python(demo.questions),
            ),
        )
        rng = random.Random(demo.slug)
        for d in range(days):
            day = start + timedelta(days=d + 1)
            for hour, answers, notes in demo.entries(rng, day):
                captured = day + timedelta(hours=hour, minutes=rng.randint(-20, 20))
                if captured > now:
                    continue
                body = EntryCreate(answers=answers, source="seed", captured_at=captured, notes=notes)
                await entry_svc.create_entry(db, demo.slug, body, Channel.api)
        created.append(demo.slug)
    return created


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()
    async with get_sessionmaker()() as db:
        created = await seed(db, days=args.days)
    await get_engine().dispose()
    skipped = [d.slug for d in DEMOS if d.slug not in created]
    print(f"created: {', '.join(created) or '-'}; skipped (already exist): {', '.join(skipped) or '-'}")


if __name__ == "__main__":
    asyncio.run(main())
