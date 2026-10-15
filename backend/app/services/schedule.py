"""Due-status computation for topic schedules. Pure functions: no DB, no clock.

Daily schedules
    A *slot* is each configured local time on each allowed ISO weekday, in the
    schedule's timezone (DST-correct: a time skipped by a spring-forward gap
    lands at the equivalent instant after the gap; an ambiguous time uses its
    first occurrence). Let ``s`` be the latest slot <= now (and >= the
    schedule's reference point, see below) and ``p`` the slot
    before it. ``s`` is satisfied by any entry captured at or after
    ``s - min(2h, (s - p) / 2)`` -- so logging a little early counts. If it is
    not satisfied the topic is due since ``s``.

Interval schedules
    Due ``every_minutes`` after the latest entry (``due_since`` = that
    instant); a topic that has never been logged becomes due one interval after
    the schedule was set.

The reference point ``schedule_since`` is when the schedule was last set (or
changed): daily slots before it are ignored, and an interval never counts from
an entry older than it. ``next_due_at`` (daily) is the first upcoming slot not
already satisfied by an early entry.

Archived topics are never due.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, date, datetime, time, timedelta
from itertools import pairwise
from zoneinfo import ZoneInfo

from pydantic import TypeAdapter

from app.schemas.api import DailySchedule, DueStatus, IntervalSchedule, Schedule

EARLY_WINDOW_MAX = timedelta(hours=2)
# Far enough back to find the slot before the latest one for a once-a-week schedule.
_LOOKBACK_DAYS = 16
_LOOKAHEAD_DAYS = 9

_schedule_adapter: TypeAdapter[DailySchedule | IntervalSchedule] = TypeAdapter(Schedule)


def parse_schedule(raw: object) -> DailySchedule | IntervalSchedule | None:
    return None if raw is None else _schedule_adapter.validate_python(raw)


def dump_schedule(schedule: DailySchedule | IntervalSchedule | None) -> dict[str, object] | None:
    return None if schedule is None else schedule.model_dump(mode="json")


def _parse_time(hhmm: str) -> time:
    h, m = hhmm.split(":")
    return time(int(h), int(m))


def daily_slots(schedule: DailySchedule, start: datetime, end: datetime) -> list[datetime]:
    """Every slot instant (UTC) in ``[start, end]``, ascending and de-duplicated."""
    tz = ZoneInfo(schedule.timezone)
    times = [_parse_time(t) for t in schedule.times]
    days = set(schedule.days)
    first = start.astimezone(tz).date() - timedelta(days=1)
    last = end.astimezone(tz).date() + timedelta(days=1)
    slots: set[datetime] = set()
    for day in _dates(first, last):
        if day.isoweekday() not in days:
            continue
        for t in times:
            # fold=0: ambiguous times use the first occurrence; nonexistent ones
            # normalise to the instant just after the gap.
            instant = datetime.combine(day, t, tzinfo=tz).astimezone(UTC)
            if start <= instant <= end:
                slots.add(instant)
    return sorted(slots)


def _dates(first: date, last: date) -> Iterator[date]:
    d = first
    while d <= last:
        yield d
        d += timedelta(days=1)


def _satisfied(slot: datetime, prev: datetime | None, last_entry_at: datetime | None) -> bool:
    """Whether an entry at ``last_entry_at`` (the latest one) satisfies ``slot``."""
    if last_entry_at is None:
        return False
    window = min(EARLY_WINDOW_MAX, (slot - prev) / 2) if prev is not None else EARLY_WINDOW_MAX
    return last_entry_at >= slot - window


def _daily(
    schedule: DailySchedule, now: datetime, last_entry_at: datetime | None, since: datetime
) -> DueStatus:
    slots = daily_slots(schedule, now - timedelta(days=_LOOKBACK_DAYS), now + timedelta(days=_LOOKAHEAD_DAYS))
    prev = {b: a for a, b in pairwise(slots)}
    # The first upcoming slot not already covered by an (early) entry.
    next_due = next((u for u in slots if u > now and not _satisfied(u, prev.get(u), last_entry_at)), None)
    # Slots before the schedule took effect never make the topic due.
    past = [s for s in slots if since <= s <= now]
    if not past:
        return DueStatus(is_due=False, due_since=None, next_due_at=next_due, last_entry_at=last_entry_at)
    s = past[-1]
    satisfied = _satisfied(s, prev.get(s), last_entry_at)
    return DueStatus(
        is_due=not satisfied,
        due_since=None if satisfied else s,
        next_due_at=next_due,
        last_entry_at=last_entry_at,
    )


def _interval(
    schedule: IntervalSchedule, now: datetime, last_entry_at: datetime | None, since: datetime
) -> DueStatus:
    # Counted from the latest entry, but never from before the schedule took effect.
    base = since if last_entry_at is None else max(last_entry_at, since)
    due_at = base + timedelta(minutes=schedule.every_minutes)
    is_due = now >= due_at
    return DueStatus(
        is_due=is_due,
        due_since=due_at if is_due else None,
        next_due_at=due_at,
        last_entry_at=last_entry_at,
    )


def compute_due(
    schedule: DailySchedule | IntervalSchedule,
    *,
    now: datetime,
    last_entry_at: datetime | None,
    schedule_since: datetime,
    archived: bool = False,
) -> DueStatus:
    """Due status of a scheduled topic at ``now`` (all datetimes timezone-aware).

    ``schedule_since`` is when the schedule was (last) set: nothing before it
    can make the topic due.
    """
    if archived:
        return DueStatus(is_due=False, due_since=None, next_due_at=None, last_entry_at=last_entry_at)
    if isinstance(schedule, DailySchedule):
        return _daily(schedule, now, last_entry_at, schedule_since)
    return _interval(schedule, now, last_entry_at, schedule_since)


def due_message(schedule: DailySchedule | IntervalSchedule, due_since: datetime, now: datetime) -> str:
    """Notification body: "Time to log" when fresh, else "Overdue since 08:00" (schedule-local)."""
    if now - due_since < timedelta(minutes=30):
        return "Time to log"
    local = due_since.astimezone(ZoneInfo(schedule.timezone))
    local_now = now.astimezone(ZoneInfo(schedule.timezone))
    if local.date() == local_now.date():
        return f"Overdue since {local:%H:%M}"
    if local_now.date() - local.date() < timedelta(days=7):
        return f"Overdue since {local:%a %H:%M}"
    return f"Overdue since {local:%d %b}"
