"""Schedule validation and due-status computation (pure, no DB)."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import pytest
from pydantic import TypeAdapter, ValidationError

from app.schemas.api import DailySchedule, IntervalSchedule, Schedule, TopicCreate
from app.schemas.base import issues_from
from app.services.schedule import compute_due, daily_slots, due_message, parse_schedule

schedule_adapter: TypeAdapter[DailySchedule | IntervalSchedule] = TypeAdapter(Schedule)

LONDON = ZoneInfo("Europe/London")
SINCE = datetime(2026, 1, 1, tzinfo=UTC)  # default: schedule set long ago


def daily(times: list[str], days: list[int] | None = None, tz: str = "UTC", **kw: Any) -> DailySchedule:
    raw: dict[str, Any] = {"kind": "daily", "times": times, "timezone": tz, **kw}
    if days is not None:
        raw["days"] = days
    s = schedule_adapter.validate_python(raw)
    assert isinstance(s, DailySchedule)
    return s


def interval(minutes: int) -> IntervalSchedule:
    s = schedule_adapter.validate_python({"kind": "interval", "every_minutes": minutes, "timezone": "UTC"})
    assert isinstance(s, IntervalSchedule)
    return s


def utc(*args: int) -> datetime:
    return datetime(*args, tzinfo=UTC)  # type: ignore[arg-type,misc]


def local(*args: int, tz: ZoneInfo = LONDON) -> datetime:
    return datetime(*args, tzinfo=tz)  # type: ignore[arg-type,misc]


def due(s: DailySchedule | IntervalSchedule, now: datetime, last: datetime | None, **kw: Any) -> Any:
    return compute_due(s, now=now, last_entry_at=last, schedule_since=kw.pop("since", SINCE), **kw)


# --- validation ----------------------------------------------------------------


def schedule_problems(raw: dict[str, Any]) -> list[tuple[list[str | int], str]]:
    with pytest.raises(ValidationError) as exc:
        TopicCreate.model_validate(
            {"name": "x", "questions": [{"type": "int", "key": "a", "label": "A"}], "schedule": raw}
        )
    return [(i.loc, i.message) for i in issues_from(exc.value)]


def test_daily_defaults_and_normalisation() -> None:
    s = daily(["21:00", "08:00"], tz="Europe/London")
    assert s.times == ["08:00", "21:00"]  # stored sorted
    assert s.days == [1, 2, 3, 4, 5, 6, 7]
    assert s.notify is True
    assert daily(["08:00"], days=[7, 1]).days == [1, 7]


@pytest.mark.parametrize(
    ("raw", "loc"),
    [
        ({"times": [], "timezone": "UTC"}, ["schedule", "times"]),
        ({"times": ["8:00"], "timezone": "UTC"}, ["schedule", "times", 0]),
        ({"times": ["24:00"], "timezone": "UTC"}, ["schedule", "times", 0]),
        ({"times": ["08:00", "09:60"], "timezone": "UTC"}, ["schedule", "times", 1]),
        ({"times": ["08:00", "08:00"], "timezone": "UTC"}, ["schedule", "times", 1]),
        ({"times": [f"{h:02}:00" for h in range(24)] + ["00:30"], "timezone": "UTC"}, ["schedule", "times"]),
        ({"times": ["08:00"], "days": [], "timezone": "UTC"}, ["schedule", "days"]),
        ({"times": ["08:00"], "days": [0], "timezone": "UTC"}, ["schedule", "days", 0]),
        ({"times": ["08:00"], "days": [1, 8], "timezone": "UTC"}, ["schedule", "days", 1]),
        ({"times": ["08:00"], "days": [2, 2], "timezone": "UTC"}, ["schedule", "days", 1]),
        ({"times": ["08:00"], "days": ["1"], "timezone": "UTC"}, ["schedule", "days", 0]),
        ({"times": ["08:00"], "timezone": "Mars/Olympus"}, ["schedule", "timezone"]),
        ({"times": ["08:00"], "timezone": ""}, ["schedule", "timezone"]),
        ({"times": ["08:00"]}, ["schedule", "timezone"]),
        ({"times": ["08:00"], "timezone": "UTC", "bogus": 1}, ["schedule", "bogus"]),
    ],
)
def test_daily_validation_locations(raw: dict[str, Any], loc: list[str | int]) -> None:
    found = schedule_problems({"kind": "daily", **raw})
    assert [f[0] for f in found] == [loc], found


def test_daily_validation_messages() -> None:
    assert schedule_problems({"kind": "daily", "times": ["8am"], "timezone": "UTC"})[0][1] == (
        "must be a 24-hour time HH:MM, e.g. '08:00'"
    )
    assert schedule_problems({"kind": "daily", "times": ["08:00", "08:00"], "timezone": "UTC"})[0][1] == (
        "duplicate time '08:00'"
    )
    assert schedule_problems({"kind": "daily", "times": ["08:00"], "timezone": "Nope"})[0][1].startswith(
        "unknown IANA timezone"
    )


@pytest.mark.parametrize(
    ("raw", "loc"),
    [
        ({"every_minutes": 14, "timezone": "UTC"}, ["schedule", "every_minutes"]),
        ({"every_minutes": 129_601, "timezone": "UTC"}, ["schedule", "every_minutes"]),
        ({"every_minutes": "60", "timezone": "UTC"}, ["schedule", "every_minutes"]),
        ({"every_minutes": 60.0, "timezone": "UTC"}, ["schedule", "every_minutes"]),
        ({"every_minutes": 60, "timezone": "UTC", "notify": "true"}, ["schedule", "notify"]),
        ({"every_minutes": 60, "timezone": "Bad/Zone"}, ["schedule", "timezone"]),
        ({"every_minutes": 60, "timezone": "UTC", "times": ["08:00"]}, ["schedule", "times"]),
    ],
)
def test_interval_validation_locations(raw: dict[str, Any], loc: list[str | int]) -> None:
    found = schedule_problems({"kind": "interval", **raw})
    assert [f[0] for f in found] == [loc], found


def test_interval_bounds_inclusive() -> None:
    assert interval(15).every_minutes == 15
    assert interval(129_600).every_minutes == 129_600


def test_unknown_kind() -> None:
    assert [f[0] for f in schedule_problems({"kind": "weekly", "timezone": "UTC"})] == [["schedule"]]


def test_parse_schedule_roundtrip() -> None:
    s = daily(["08:00"], days=[1, 3], tz="Europe/London", notify=False)
    assert parse_schedule(s.model_dump(mode="json")) == s
    assert parse_schedule(None) is None


# --- daily slots ----------------------------------------------------------------


def test_slots_respect_timezone_and_days() -> None:
    s = daily(["08:00", "21:00"], days=[1, 2], tz="Europe/London")  # Mon, Tue
    # Mon 2026-07-06 (BST, UTC+1) .. Thu 2026-07-09
    slots = daily_slots(s, utc(2026, 7, 6), utc(2026, 7, 9, 23, 59))
    assert slots == [utc(2026, 7, 6, 7), utc(2026, 7, 6, 20), utc(2026, 7, 7, 7), utc(2026, 7, 7, 20)]


def test_slots_across_spring_forward() -> None:
    # Europe/London: 2026-03-29 01:00 GMT -> 02:00 BST. 01:30 does not exist that day.
    s = daily(["01:30", "08:00"], tz="Europe/London")
    slots = daily_slots(s, utc(2026, 3, 28), utc(2026, 3, 30, 12))
    assert utc(2026, 3, 29, 8 - 1) in slots  # 08:00 BST = 07:00 UTC
    assert utc(2026, 3, 28, 8) in slots  # 08:00 GMT the day before
    # The skipped 01:30 normalises to the instant after the gap (02:30 BST = 01:30 UTC).
    assert utc(2026, 3, 29, 1, 30) in slots
    assert len(slots) == len(set(slots))


def test_slots_across_fall_back() -> None:
    # Europe/London: 2026-10-25 02:00 BST -> 01:00 GMT; 01:30 happens twice (first one used).
    s = daily(["01:30", "09:00"], tz="Europe/London")
    slots = daily_slots(s, utc(2026, 10, 24), utc(2026, 10, 26, 12))
    assert utc(2026, 10, 25, 0, 30) in slots  # first 01:30 (BST)
    assert utc(2026, 10, 25, 1, 30) not in slots
    assert utc(2026, 10, 25, 9) in slots  # 09:00 GMT
    assert utc(2026, 10, 24, 8) in slots  # 09:00 BST the day before


# --- daily due status --------------------------------------------------------------


def test_daily_due_when_latest_slot_unsatisfied() -> None:
    s = daily(["08:00"], tz="UTC")
    st = due(s, utc(2026, 5, 2, 9), last=utc(2026, 5, 1, 8, 5))
    assert st.is_due is True
    assert st.due_since == utc(2026, 5, 2, 8)
    assert st.next_due_at == utc(2026, 5, 3, 8)
    assert st.last_entry_at == utc(2026, 5, 1, 8, 5)


def test_daily_satisfied_after_slot() -> None:
    s = daily(["08:00"], tz="UTC")
    st = due(s, utc(2026, 5, 2, 9), last=utc(2026, 5, 2, 8, 30))
    assert (st.is_due, st.due_since, st.next_due_at) == (False, None, utc(2026, 5, 3, 8))


def test_daily_early_window_is_two_hours_for_daily_slots() -> None:
    s = daily(["08:00"], tz="UTC")
    now = utc(2026, 5, 2, 9)
    assert due(s, now, last=utc(2026, 5, 2, 6)).is_due is False  # exactly 2h early
    assert due(s, now, last=utc(2026, 5, 2, 5, 59)).is_due is True


def test_daily_early_window_is_half_the_gap_for_close_slots() -> None:
    s = daily(["08:00", "09:00"], tz="UTC")  # 1h apart -> 30 min window
    now = utc(2026, 5, 2, 9, 10)
    assert due(s, now, last=utc(2026, 5, 2, 8, 30)).is_due is False
    st = due(s, now, last=utc(2026, 5, 2, 8, 29))
    assert (st.is_due, st.due_since) == (True, utc(2026, 5, 2, 9))


def test_daily_multiple_times_track_latest_slot() -> None:
    s = daily(["08:00", "21:00"], tz="UTC")
    morning = utc(2026, 5, 2, 8, 15)
    # Logged in the morning: not due during the day ...
    assert due(s, utc(2026, 5, 2, 20), last=morning).is_due is False
    st = due(s, utc(2026, 5, 2, 20), last=morning)
    assert st.next_due_at == utc(2026, 5, 2, 21)
    # ... but due again at 21:00.
    st = due(s, utc(2026, 5, 2, 21, 1), last=morning)
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 2, 21), utc(2026, 5, 3, 8))
    # Logging at 19:30 counts early for the 21:00 slot.
    assert due(s, utc(2026, 5, 2, 21, 1), last=utc(2026, 5, 2, 19, 30)).is_due is False


def test_daily_day_filter() -> None:
    s = daily(["08:00"], days=[1, 3, 5], tz="UTC")  # Mon, Wed, Fri
    # Sun 2026-05-03 12:00: latest slot is Fri 2026-05-01 08:00, next Mon 2026-05-04.
    st = due(s, utc(2026, 5, 3, 12), last=None)
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 1, 8), utc(2026, 5, 4, 8))
    assert due(s, utc(2026, 5, 3, 12), last=utc(2026, 5, 1, 9)).is_due is False


def test_daily_weekly_slot_window() -> None:
    s = daily(["08:00"], days=[1], tz="UTC")  # Mondays only: gap 7 days -> window 2h
    now = utc(2026, 5, 4, 9)  # Monday
    assert due(s, now, last=utc(2026, 5, 4, 6)).is_due is False
    assert due(s, now, last=utc(2026, 5, 3, 9)).is_due is True


def test_daily_dst_spring_forward_due_since() -> None:
    s = daily(["08:00"], tz="Europe/London")
    now = local(2026, 3, 29, 9)  # first BST morning
    st = due(s, now, last=local(2026, 3, 28, 8))
    assert st.due_since == local(2026, 3, 29, 8)
    assert st.due_since == utc(2026, 3, 29, 7)
    assert st.next_due_at == utc(2026, 3, 30, 7)
    # 23h between the slots across the change; logging at 06:30 local still counts early.
    assert due(s, now, last=local(2026, 3, 29, 6, 30)).is_due is False


def test_daily_dst_fall_back_due_since() -> None:
    s = daily(["08:00"], tz="Europe/London")
    now = local(2026, 10, 25, 8, 30)  # first GMT morning
    st = due(s, now, last=local(2026, 10, 24, 8))
    assert (st.is_due, st.due_since) == (True, utc(2026, 10, 25, 8))
    assert st.next_due_at == utc(2026, 10, 26, 8)


def test_daily_new_york_timezone() -> None:
    s = daily(["20:00"], tz="America/New_York")
    st = due(s, utc(2026, 7, 1, 23, 59), last=None)  # 19:59 EDT
    assert st.due_since == utc(2026, 7, 1, 0)  # previous evening 20:00 EDT
    assert st.next_due_at == utc(2026, 7, 2, 0)


def test_daily_no_entries_is_due() -> None:
    st = due(daily(["08:00"]), utc(2026, 5, 2, 9), last=None)
    assert (st.is_due, st.due_since, st.last_entry_at) == (True, utc(2026, 5, 2, 8), None)


def test_slot_exactly_now_is_current() -> None:
    st = due(daily(["08:00"]), utc(2026, 5, 2, 8), last=utc(2026, 5, 1, 8))
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 2, 8), utc(2026, 5, 3, 8))


# --- interval ------------------------------------------------------------------------


def test_interval_never_logged_is_due_one_interval_after_schedule_set() -> None:
    since = utc(2026, 5, 2, 8)
    st = due(interval(60), utc(2026, 5, 2, 8, 59), last=None, since=since)
    assert (st.is_due, st.due_since, st.next_due_at, st.last_entry_at) == (
        False,
        None,
        utc(2026, 5, 2, 9),
        None,
    )
    st = due(interval(60), utc(2026, 5, 2, 9), last=None, since=since)
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 2, 9), utc(2026, 5, 2, 9))


def test_interval_counts_from_schedule_change_not_older_entries() -> None:
    since = utc(2026, 5, 2, 8)
    old_entry = utc(2026, 4, 1)
    st = due(interval(60), utc(2026, 5, 2, 8, 30), last=old_entry, since=since)
    assert (st.is_due, st.next_due_at, st.last_entry_at) == (False, utc(2026, 5, 2, 9), old_entry)
    # Entries after the change count as usual.
    st = due(interval(60), utc(2026, 5, 2, 10), last=utc(2026, 5, 2, 8, 30), since=since)
    assert (st.is_due, st.due_since) == (True, utc(2026, 5, 2, 9, 30))


def test_interval_due_after_every_minutes() -> None:
    last = utc(2026, 5, 2, 8)
    st = due(interval(90), utc(2026, 5, 2, 9), last=last)
    assert (st.is_due, st.due_since, st.next_due_at) == (False, None, utc(2026, 5, 2, 9, 30))
    st = due(interval(90), utc(2026, 5, 2, 9, 30), last=last)
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 2, 9, 30), utc(2026, 5, 2, 9, 30))


def test_interval_future_entry_not_due() -> None:
    now = utc(2026, 5, 2, 9)
    assert due(interval(15), now, last=now + timedelta(hours=1)).is_due is False


# --- archived & messages -------------------------------------------------------------


@pytest.mark.parametrize("schedule", [daily(["08:00"]), interval(15)])
def test_archived_never_due(schedule: DailySchedule | IntervalSchedule) -> None:
    st = due(schedule, utc(2026, 5, 2, 9), last=None, archived=True)
    assert (st.is_due, st.due_since, st.next_due_at) == (False, None, None)


def test_due_message() -> None:
    s = daily(["08:00"], tz="Europe/London")
    since = local(2026, 7, 6, 8)  # Monday
    assert due_message(s, since, since + timedelta(minutes=5)) == "Time to log"
    assert due_message(s, since, since + timedelta(hours=3)) == "Overdue since 08:00"
    assert due_message(s, since, since + timedelta(days=1)) == "Overdue since Mon 08:00"
    assert due_message(s, since, since + timedelta(days=9)) == "Overdue since 06 Jul"


# --- reference point & next_due_at ------------------------------------------------


def test_daily_slots_before_schedule_set_are_ignored() -> None:
    s = daily(["08:00", "21:00"])
    since = utc(2026, 5, 2, 9)  # schedule set after this morning's slot
    st = due(s, utc(2026, 5, 2, 10), last=None, since=since)
    assert (st.is_due, st.due_since, st.next_due_at) == (False, None, utc(2026, 5, 2, 21))
    # The first slot after the change counts.
    st = due(s, utc(2026, 5, 2, 21, 5), last=None, since=since)
    assert (st.is_due, st.due_since) == (True, utc(2026, 5, 2, 21))


def test_daily_slot_exactly_at_schedule_set_counts() -> None:
    st = due(daily(["08:00"]), utc(2026, 5, 2, 8, 30), last=None, since=utc(2026, 5, 2, 8))
    assert (st.is_due, st.due_since) == (True, utc(2026, 5, 2, 8))


def test_daily_weekly_slot_before_change_ignored() -> None:
    s = daily(["08:00"], days=[1])  # Mondays
    # Changed on Tuesday: last Monday's slot does not count until next Monday.
    st = due(s, utc(2026, 5, 7, 12), last=None, since=utc(2026, 5, 5, 12))
    assert (st.is_due, st.next_due_at) == (False, utc(2026, 5, 11, 8))


def test_next_due_skips_slot_already_satisfied_early() -> None:
    s = daily(["08:00", "21:00"])
    # Logged 07:30 for the 08:00 slot: at 07:45 the next due slot is 21:00, not 08:00.
    st = due(s, utc(2026, 5, 2, 7, 45), last=utc(2026, 5, 2, 7, 30))
    assert (st.is_due, st.next_due_at) == (False, utc(2026, 5, 2, 21))
    # Without the early entry, 08:00 is next (and last night's 21:00 slot is overdue).
    st = due(s, utc(2026, 5, 2, 7, 45), last=None)
    assert (st.is_due, st.due_since, st.next_due_at) == (True, utc(2026, 5, 1, 21), utc(2026, 5, 2, 8))


def test_next_due_with_single_daily_time() -> None:
    s = daily(["08:00"])
    st = due(s, utc(2026, 5, 2, 7, 0), last=utc(2026, 5, 2, 6, 30))  # 1.5h early: within 2h
    assert st.next_due_at == utc(2026, 5, 3, 8)
    st = due(s, utc(2026, 5, 2, 5, 0), last=utc(2026, 5, 2, 4, 0))  # 4h early: too early
    assert st.next_due_at == utc(2026, 5, 2, 8)
