"""Due-logic vectors for the Swift port: ``shared/fixtures/due-vectors.json``.

The real ``schedule.py`` (``daily_slots``, ``compute_due``, ``due_message``) is
evaluated over a fixed grid -- DST transitions in London, New York and Lord Howe
(30-minute shift), half/quarter-hour offsets without DST (Kolkata, Kathmandu)
and UTC -- with ``now`` swept +-3 h around each transition in 15-minute steps.
No wall clock, no randomness: the output only changes when the logic does.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match. ``meta.tzdata`` is informational only (CI and macOS
ship different tzdata releases; the 2026 rules are the same in all of them) and
is not part of the comparison.
"""

from __future__ import annotations

import importlib
import json
import zoneinfo
from datetime import UTC, date, datetime, time, timedelta
from itertools import pairwise
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from pydantic import TypeAdapter

from app.schemas.api import DailySchedule, IntervalSchedule, Schedule
from app.services.schedule import (
    _LOOKAHEAD_DAYS,
    _LOOKBACK_DAYS,
    EARLY_WINDOW_MAX,
    compute_due,
    daily_slots,
    due_message,
)
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases, updating

PATH = FIXTURES_DIR / "due-vectors.json"
GENERATOR_VERSION = 1
STEP = timedelta(minutes=15)
SWEEP = 12  # steps either side of the centre: +-3 h
SINCE = datetime(2026, 1, 1, tzinfo=UTC)  # default: schedule set long ago
LOGGED_AGO = timedelta(minutes=10)  # the "logged" sweep: last entry 10 min before now

schedule_adapter: TypeAdapter[DailySchedule | IntervalSchedule] = TypeAdapter(Schedule)

# Each zone is swept around these local dates: the DST transitions, or (no DST)
# an ordinary Sunday, centred on local 01:00.
WINDOWS: list[tuple[str, date]] = [
    ("Europe/London", date(2026, 3, 29)),  # 01:00 GMT -> 02:00 BST (gap 01:00-01:59)
    ("Europe/London", date(2026, 10, 25)),  # 02:00 BST -> 01:00 GMT (01:00-01:59 twice)
    ("America/New_York", date(2026, 3, 8)),  # 02:00 EST -> 03:00 EDT (gap 02:00-02:59)
    ("America/New_York", date(2026, 11, 1)),  # 02:00 EDT -> 01:00 EST (01:00-01:59 twice)
    ("Australia/Lord_Howe", date(2026, 4, 5)),  # 02:00 +11 -> 01:30 +10:30 (01:30-01:59 twice)
    ("Australia/Lord_Howe", date(2026, 10, 4)),  # 02:00 +10:30 -> 02:30 +11 (gap 02:00-02:29)
    ("Asia/Kolkata", date(2026, 3, 29)),  # +05:30
    ("Asia/Kathmandu", date(2026, 3, 29)),  # +05:45
    ("UTC", date(2026, 3, 29)),
]

# Daily schedules evaluated in every zone. "multi" mixes times that land in gaps
# and folds with near neighbours (half-gap early windows of 30 s to 7.5 min).
DAILY: dict[str, dict[str, Any]] = {
    "multi": {"times": ["00:00", "01:30", "02:15", "02:30", "23:59"]},
    "t0130": {"times": ["01:30"]},
    "t0230": {"times": ["02:30"]},
    "sun0130": {"times": ["01:30"], "days": [7]},  # weekly, on the transition day
    "wed2359": {"times": ["23:59"], "days": [3]},  # weekly, needs the long lookback
}
INTERVALS = (15, 129_600)
INTERVAL_ZONES = ("UTC", "Europe/London")

SEMANTICS = [
    "Daily slots: every configured local time on every allowed ISO weekday (1 = Monday) of the "
    "schedule's timezone, as UTC instants, ascending; equal instants are de-duplicated.",
    "Nonexistent local times (spring-forward gap) use the UTC offset in effect before the gap "
    "(PEP 495 fold=0), i.e. they land after the gap, shifted forward by its length: "
    "London 01:30 on 2026-03-29 -> 01:30Z (02:30 BST).",
    "Ambiguous local times (fall-back fold) use their first occurrence (the pre-transition offset).",
    "Slot s (the latest slot <= now and >= schedule_since) is satisfied by last_entry_at >= "
    "s - min(early_window_max, (s - p) / 2), p being the slot before s (no p: early_window_max).",
    "Daily: not satisfied -> is_due, due_since = s. No slot in [schedule_since, now] -> not due.",
    "next_due_at (daily) is the first slot > now not already satisfied by last_entry_at "
    "(slots before schedule_since still count as p for the half-gap window).",
    "Interval: due_at = max(last_entry_at, schedule_since) + every_minutes (schedule_since when "
    "never logged); is_due = now >= due_at; due_since = due_at when due; next_due_at = due_at.",
    "Archived: never due; due_since and next_due_at are null.",
    "Slots are searched in [now - lookback_days, now + lookahead_days].",
    "due_message: now - due_since < 30 min -> 'Time to log'; else in the schedule's timezone: "
    "same local date -> 'Overdue since HH:MM'; fewer than 7 local calendar days -> "
    "'Overdue since Ddd HH:MM'; else 'Overdue since DD Mmm'. Ddd/Mmm are C-locale English "
    "abbreviations, DD zero-padded, 24-hour clock.",
]


def iso(dt: datetime | None) -> str | None:
    return None if dt is None else dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def zone_key(tz: str) -> str:
    return tz.rsplit("/", maxsplit=1)[-1].lower()


def tzdata_version() -> str:
    try:
        return str(importlib.import_module("tzdata").IANA_VERSION)
    except ImportError:
        pass
    for root in zoneinfo.TZPATH:
        zi = Path(root) / "tzdata.zi"
        if zi.exists():
            return zi.read_text().splitlines()[0].removeprefix("# version ").strip()
        version = Path(root) / "+VERSION"
        if version.exists():
            return version.read_text().strip()
    return "unknown"


def centre(tz: str, day: date) -> datetime:
    """The UTC offset change on ``day`` (local), else local 01:00 on it."""
    zone = ZoneInfo(tz)
    start = datetime.combine(day, time(), tzinfo=zone).astimezone(UTC) - timedelta(hours=2)
    instants = [start + i * STEP for i in range(4 * 30)]
    for a, b in pairwise(instants):
        if a.astimezone(zone).utcoffset() != b.astimezone(zone).utcoffset():
            return b
    return datetime.combine(day, time(1), tzinfo=zone).astimezone(UTC)


class Builder:
    def __init__(self) -> None:
        self.schedules: dict[str, dict[str, Any]] = {}
        self.models: dict[str, DailySchedule | IntervalSchedule] = {}
        self.slots: list[dict[str, Any]] = []
        self.due: list[dict[str, Any]] = []
        self.messages: list[dict[str, Any]] = []
        self._names: set[str] = set()

    def schedule(self, sid: str, raw: dict[str, Any]) -> DailySchedule | IntervalSchedule:
        if sid not in self.models:
            model = schedule_adapter.validate_python(raw)
            self.models[sid] = model
            self.schedules[sid] = model.model_dump(mode="json")
        return self.models[sid]

    def _name(self, name: str) -> str:
        assert name not in self._names, name
        self._names.add(name)
        return name

    def add_slots(self, name: str, sid: str, start: datetime, end: datetime) -> None:
        s = self.models[sid]
        assert isinstance(s, DailySchedule)
        self.slots.append(
            {
                "name": self._name(name),
                "schedule": sid,
                "start": iso(start),
                "end": iso(end),
                "expected": [iso(x) for x in daily_slots(s, start, end)],
            }
        )

    def add_due(
        self,
        name: str,
        sid: str,
        *,
        now: datetime,
        last: datetime | None,
        since: datetime = SINCE,
        archived: bool = False,
    ) -> None:
        r = compute_due(
            self.models[sid], now=now, last_entry_at=last, schedule_since=since, archived=archived
        )
        self.due.append(
            {
                "name": self._name(name),
                "schedule": sid,
                "now": iso(now),
                "last_entry_at": iso(last),
                "schedule_since": iso(since),
                "archived": archived,
                "expected": {
                    "is_due": r.is_due,
                    "due_since": iso(r.due_since),
                    "next_due_at": iso(r.next_due_at),
                    "last_entry_at": iso(r.last_entry_at),
                },
            }
        )

    def add_message(self, name: str, tz: str, due_since: datetime, now: datetime) -> None:
        s = self.schedule(f"{zone_key(tz)}/msg", {"kind": "daily", "times": ["08:00"], "timezone": tz})
        self.messages.append(
            {
                "name": self._name(name),
                "timezone": tz,
                "due_since": iso(due_since),
                "now": iso(now),
                "expected": due_message(s, due_since, now),
            }
        )


def offset_label(delta: timedelta) -> str:
    secs = int(delta.total_seconds())
    sign = "-" if secs < 0 else "+"
    secs = abs(secs)
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    out = sign + (f"{d}d" if d else "") + (f"{h}h" if h else "") + (f"{m}m" if m else "")
    return out + (f"{s}s" if s or out == sign else "")


def previous_slot(s: DailySchedule, slot: datetime) -> datetime | None:
    before = daily_slots(s, slot - timedelta(days=_LOOKBACK_DAYS), slot)
    return before[-2] if len(before) >= 2 else None


def daily_cases(b: Builder) -> None:
    for tz, day in WINDOWS:
        c = centre(tz, day)
        w = f"{zone_key(tz)}/{day.isoformat()}"
        for key, raw in DAILY.items():
            sid = f"{zone_key(tz)}/{key}"
            s = b.schedule(sid, {"kind": "daily", "timezone": tz, **raw})
            assert isinstance(s, DailySchedule)
            b.add_slots(f"{w}/{key}", sid, c - timedelta(days=1), c + timedelta(days=1))
            if key.startswith(("sun", "wed")):
                b.add_slots(f"{w}/{key}/long", sid, c - timedelta(days=15), c + timedelta(days=8))

            # The sweep: never logged, then (multi only) logged shortly before now.
            for i in range(-SWEEP, SWEEP + 1):
                now = c + i * STEP
                b.add_due(f"{w}/{key}/sweep{offset_label(i * STEP)}", sid, now=now, last=None)
                if key == "multi":
                    b.add_due(
                        f"{w}/{key}/sweep{offset_label(i * STEP)}/logged", sid, now=now, last=now - LOGGED_AGO
                    )

            # Early-window edges for every slot near the centre.
            for slot in daily_slots(s, c - SWEEP * STEP, c + SWEEP * STEP):
                prev = previous_slot(s, slot)
                window = EARLY_WINDOW_MAX if prev is None else min(EARLY_WINDOW_MAX, (slot - prev) / 2)
                edge = slot - window
                tag = f"{w}/{key}/{iso(slot)}"
                after = slot + timedelta(seconds=1)
                before = slot - timedelta(seconds=1)
                b.add_due(f"{tag}/early-1s", sid, now=after, last=edge - timedelta(seconds=1))
                b.add_due(f"{tag}/early", sid, now=after, last=edge)
                b.add_due(f"{tag}/on-time", sid, now=after, last=slot)
                b.add_due(f"{tag}/upcoming", sid, now=before, last=edge - timedelta(seconds=1))
                b.add_due(f"{tag}/upcoming-early", sid, now=before, last=edge)

        # schedule_since cut-off around the first multi slot after the centre.
        sid = f"{zone_key(tz)}/multi"
        s = b.models[sid]
        assert isinstance(s, DailySchedule)
        slot = daily_slots(s, c, c + timedelta(days=1))[0]
        for d in (-1, 0, 1):
            since = slot + timedelta(seconds=d)
            b.add_due(
                f"{w}/multi/since{offset_label(timedelta(seconds=d))}",
                sid,
                now=slot + timedelta(seconds=30),
                last=None,
                since=since,
            )
        b.add_due(f"{w}/multi/since-future", sid, now=c, last=None, since=c + timedelta(hours=1))
        b.add_due(f"{w}/multi/archived", sid, now=c, last=None, archived=True)
        b.add_due(f"{w}/multi/archived-logged", sid, now=c, last=c - timedelta(hours=1), archived=True)


def interval_cases(b: Builder) -> None:
    for tz in INTERVAL_ZONES:
        c = centre(tz, date(2026, 3, 29))
        for every in INTERVALS:
            sid = f"{zone_key(tz)}/every{every}"
            b.schedule(sid, {"kind": "interval", "every_minutes": every, "timezone": tz})
            period = timedelta(minutes=every)
            w = f"{sid}"
            scenarios: list[tuple[str, datetime | None, datetime, datetime]] = [
                # name, last_entry_at, schedule_since, the instant due_at counts from
                ("never", None, c, c),
                ("before-since", c - timedelta(hours=1), c, c),
                ("after-since", c, c - timedelta(hours=1), c),
                ("at-since", c, c, c),
            ]
            for label, last, since, base in scenarios:
                due_at = base + period
                for d in (-1, 0, 1):
                    b.add_due(
                        f"{w}/{label}/due{offset_label(timedelta(seconds=d))}",
                        sid,
                        now=due_at + timedelta(seconds=d),
                        last=last,
                        since=since,
                    )
                b.add_due(f"{w}/{label}/now", sid, now=base, last=last, since=since)
            b.add_due(f"{w}/since-future", sid, now=c, last=None, since=c + timedelta(hours=1))
            b.add_due(f"{w}/archived", sid, now=c + 2 * period, last=None, since=c, archived=True)


MESSAGE_DELTAS = [
    timedelta(0),
    timedelta(minutes=29, seconds=59),
    timedelta(minutes=30),
    timedelta(hours=1),
    timedelta(hours=3),
    timedelta(hours=23),
    timedelta(days=1),
    timedelta(days=6, hours=23, minutes=59),
    timedelta(days=7),
    timedelta(days=40),
]


def message_cases(b: Builder) -> None:
    for tz, day in WINDOWS:
        c = centre(tz, day)
        zone = ZoneInfo(tz)
        late_evening = datetime.combine(day - timedelta(days=1), time(23, 30), tzinfo=zone).astimezone(UTC)
        anchors = {
            "centre-1h": c - timedelta(hours=1),
            "centre": c,
            "centre+1h": c + timedelta(hours=1),
            "eve2330": late_evening,
        }
        for label, due_since in anchors.items():
            for delta in MESSAGE_DELTAS:
                b.add_message(
                    f"{zone_key(tz)}/{day.isoformat()}/{label}/{offset_label(delta)}",
                    tz,
                    due_since,
                    due_since + delta,
                )


def build() -> dict[str, Any]:
    b = Builder()
    daily_cases(b)
    interval_cases(b)
    message_cases(b)
    return {
        "meta": {
            "generator": "backend/tests/test_due_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "tzdata": tzdata_version(),
            "early_window_max_seconds": int(EARLY_WINDOW_MAX.total_seconds()),
            "lookback_days": _LOOKBACK_DAYS,
            "lookahead_days": _LOOKAHEAD_DAYS,
            "datetimes": "UTC ISO-8601, second precision, 'Z' suffix",
            "semantics": SEMANTICS,
            "counts": {"slots": len(b.slots), "due": len(b.due), "messages": len(b.messages)},
        },
        "schedules": b.schedules,
        "slots": b.slots,
        "due": b.due,
        "messages": b.messages,
    }


def test_due_vectors_match_committed() -> None:
    doc = build()
    if PATH.exists() and not updating():
        # tzdata release is informational: keep whatever the committed file recorded.
        doc["meta"]["tzdata"] = json.loads(PATH.read_text())["meta"]["tzdata"]
    content = dump_cases(doc)
    check_or_write(PATH, content)
    assert len(content.encode()) < 1_000_000


def test_grid_hits_the_known_hazards() -> None:
    """Spot-check the cases the Swift port is most likely to get wrong."""
    doc = build()
    due = {c["name"]: c for c in doc["due"]}
    slots = {c["name"]: c for c in doc["slots"]}
    # London 01:30 doesn't exist on 2026-03-29: it lands after the gap, at 01:30Z (02:30 BST),
    # where it coincides with the 02:30 slot and is de-duplicated.
    london = slots["london/2026-03-29/multi"]["expected"]
    assert "2026-03-29T01:30:00Z" in london
    assert "2026-03-29T00:30:00Z" not in london
    # Ambiguous New York 01:30 on 2026-11-01: first occurrence (EDT, 05:30Z).
    assert "2026-11-01T05:30:00Z" in slots["new_york/2026-11-01/t0130"]["expected"]
    assert "2026-11-01T06:30:00Z" not in slots["new_york/2026-11-01/t0130"]["expected"]
    # Every branch is represented.
    assert any(c["expected"]["is_due"] for c in due.values())
    assert any(not c["expected"]["is_due"] and c["expected"]["next_due_at"] for c in due.values())
    texts = [m["expected"] for m in doc["messages"]]
    assert "Time to log" in texts
    assert any(t.startswith("Overdue since ") and len(t) == len("Overdue since 08:00") for t in texts)
    assert any(len(t) == len("Overdue since Mon 08:00") for t in texts)
    assert any(len(t) == len("Overdue since 05 Apr") and t[-3:].isalpha() for t in texts)
