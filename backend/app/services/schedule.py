"""Due-status computation for topic schedules. Pure functions: no DB, no clock.

Daily schedules
    A *slot* is each configured local time on each allowed ISO weekday, in the
    schedule's timezone (DST-correct: a time skipped by a spring-forward gap
    lands at the equivalent instant after the gap; an ambiguous time uses its
    first occurrence). Let ``s`` be the latest slot <= now and ``p`` the slot
    before it. ``s`` is satisfied by any entry captured at or after
    ``s - min(2h, (s - p) / 2)`` -- so logging a little early counts. If it is
    not satisfied the topic is due since ``s``. ``next_due_at`` is the first
    slot after now.

Interval schedules
    Due ``every_minutes`` after the latest entry (``due_since`` = that
    instant); a topic that has never been logged is due since its creation.

Archived topics are never due.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, date, datetime, time, timedelta
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


def _daily(schedule: DailySchedule, now: datetime, last_entry_at: datetime | None) -> DueStatus:
    slots = daily_slots(schedule, now - timedelta(days=_LOOKBACK_DAYS), now + timedelta(days=_LOOKAHEAD_DAYS))
    past = [s for s in slots if s <= now]
    upcoming = [s for s in slots if s > now]
    next_due = upcoming[0] if upcoming else None
    if not past:  # unreachable with >= 1 day and time, kept for safety
        return DueStatus(is_due=False, due_since=None, next_due_at=next_due, last_entry_at=last_entry_at)
    s = past[-1]
    window = min(EARLY_WINDOW_MAX, (s - past[-2]) / 2) if len(past) > 1 else EARLY_WINDOW_MAX
    satisfied = last_entry_at is not None and last_entry_at >= s - window
    return DueStatus(
        is_due=not satisfied,
        due_since=None if satisfied else s,
        next_due_at=next_due,
        last_entry_at=last_entry_at,
    )


def _interval(
    schedule: IntervalSchedule, now: datetime, last_entry_at: datetime | None, created_at: datetime
) -> DueStatus:
    if last_entry_at is None:
        return DueStatus(is_due=True, due_since=created_at, next_due_at=now, last_entry_at=None)
    due_at = last_entry_at + timedelta(minutes=schedule.every_minutes)
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
    created_at: datetime,
    archived: bool = False,
) -> DueStatus:
    """Due status of a scheduled topic at ``now`` (all datetimes timezone-aware)."""
    if archived:
        return DueStatus(is_due=False, due_since=None, next_due_at=None, last_entry_at=last_entry_at)
    if isinstance(schedule, DailySchedule):
        return _daily(schedule, now, last_entry_at)
    return _interval(schedule, now, last_entry_at, created_at)


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
