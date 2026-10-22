"""Actionable notifications: the quick-log descriptor, actions, category ids, and what the
scheduler builds from real entries (docs/ios/specs/notifications.md §2.3, §4)."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import httpx
import pytest
from sqlalchemy import update

from app.db import get_sessionmaker
from app.models import Topic
from app.schemas.api import QuickLogEnum, QuickLogNumber, QuickLogOption
from app.schemas.questions import DoubleQuestion, EnumOption, EnumQuestion, IntQuestion
from app.services import notification, scheduler
from app.services import push as push_svc
from app.services.notification import Action
from app.services.push import web as web_push
from tests.helpers import make_topic, record

SERVER_ID = "0b9e0000-0000-4000-8000-0000000000aa"
TOPIC_ID = "6f1c0000-0000-4000-8000-000000000001"
INTERVAL = {"kind": "interval", "every_minutes": 60, "timezone": "UTC"}


def enum(n: int, *, archived: tuple[int, ...] = ()) -> EnumQuestion:
    options = [EnumOption(value=f"o{i}", label=f"Option {i}", archived=i in archived) for i in range(n)]
    return EnumQuestion(key="mood", label="Mood", type="enum", options=options)


def values(quick_log: Any) -> list[str]:
    assert isinstance(quick_log, QuickLogEnum)
    return [o.value for o in quick_log.options]


# --- the descriptor -------------------------------------------------------------------------


def test_up_to_4_options_are_all_shown_in_question_order() -> None:
    for n in (1, 4):
        quick_log = notification.descriptor([enum(n)], counts={f"o{n - 1}": 10}, last=None)
        assert values(quick_log) == [f"o{i}" for i in range(n)]
        assert isinstance(quick_log, QuickLogEnum)
        assert quick_log.total_options == n


def test_5_or_6_options_show_the_3_most_used_ties_in_question_order() -> None:
    assert values(notification.descriptor([enum(6)], counts={}, last=None)) == ["o0", "o1", "o2"]
    counts = {"o5": 3, "o2": 3, "o4": 7, "o0": 1}
    assert values(notification.descriptor([enum(6)], counts=counts, last=None)) == ["o4", "o2", "o5"]
    assert values(notification.descriptor([enum(5)], counts={"o4": 1}, last=None)) == ["o4", "o0", "o1"]


def test_archived_options_are_never_offered_or_counted() -> None:
    # 7 options, one archived: 6 active. The archived one is the most used, and skipped.
    quick_log = notification.descriptor([enum(7, archived=(1,))], counts={"o1": 50, "o6": 2}, last=None)
    assert values(quick_log) == ["o6", "o0", "o2"]
    assert isinstance(quick_log, QuickLogEnum)
    assert quick_log.total_options == 6
    # 5 options, one archived: 4 active, all shown.
    quick_log = notification.descriptor([enum(5, archived=(0,))], counts={}, last=None)
    assert values(quick_log) == ["o1", "o2", "o3", "o4"]


def test_labels_and_units_are_truncated_to_64_scalars() -> None:
    long = "é" * 200
    q = EnumQuestion(key="mood", label=long, type="enum", options=[EnumOption(value="a", label=long)])
    quick_log = notification.descriptor([q], counts={}, last=None)
    assert isinstance(quick_log, QuickLogEnum)
    assert quick_log.label == quick_log.options[0].label == "é" * 63 + "…"
    n = DoubleQuestion(key="n", label="N", type="double", unit="u" * 32)
    number = notification.descriptor([n], counts={}, last=None)
    assert isinstance(number, QuickLogNumber)
    assert number.unit == "u" * 32
    assert notification.truncate("x" * 64, 64) == "x" * 64


@pytest.mark.parametrize(
    ("question", "last", "expected"),
    [
        (IntQuestion(key="n", label="N", type="int", min=0, max=10), 7, 7),
        (IntQuestion(key="n", label="N", type="int", min=0, max=10), 7.0, 7),  # stored as a double once
        (IntQuestion(key="n", label="N", type="int", min=0, max=10), 11, None),  # out of bounds now
        (IntQuestion(key="n", label="N", type="int"), 7.5, None),
        (IntQuestion(key="n", label="N", type="int"), True, None),
        (IntQuestion(key="n", label="N", type="int"), "7", None),
        (IntQuestion(key="n", label="N", type="int"), None, None),
        (DoubleQuestion(key="n", label="N", type="double", decimals=1), 7.5, 7.5),
        (DoubleQuestion(key="n", label="N", type="double", decimals=1), 7, 7.0),
        # decimals is a display hint, not a rule: the exact value is kept.
        (DoubleQuestion(key="n", label="N", type="double", decimals=1), 7.25, 7.25),
        (DoubleQuestion(key="n", label="N", type="double", decimals=0), 100.0, 100.0),
        (DoubleQuestion(key="n", label="N", type="double"), 7.25, 7.25),
        (DoubleQuestion(key="n", label="N", type="double", max=5), 7.25, None),
    ],
)
def test_last_value_is_kept_only_while_the_question_accepts_it(
    question: IntQuestion | DoubleQuestion, last: object, expected: float | None
) -> None:
    quick_log = notification.descriptor([question], counts={}, last=last)
    assert isinstance(quick_log, QuickLogNumber)
    assert quick_log.last_value == expected
    assert type(quick_log.last_value) is type(expected)


# --- formatting, actions and category ids -----------------------------------------------------


@pytest.mark.parametrize(
    ("kind", "x", "expected"),
    [
        ("int", 7, "7"),
        ("int", -12345678, "-12345678"),
        ("int", 2**63 - 1, "9223372036854775807"),
        ("double", 7.5, "7.5"),
        ("double", 7, "7"),
        ("double", 7.0, "7"),
        ("double", 7.25, "7.25"),  # never rounded to the question's decimals
        ("double", 2.675, "2.675"),  # binary 2.67499…; the shortest round-trip decimal
        ("double", -0.0, "0"),
        ("double", 0.1 + 0.2, "0.30000000000000004"),
        ("double", 1.5e-7, "0.00000015"),
        ("double", 1e21, "1000000000000000000000"),
        ("double", 1e23, "100000000000000000000000"),  # shortest, not the exact 99999999999999991611392
        ("double", 5e-324, "0." + "0" * 323 + "5"),
    ],
)
def test_fmt(kind: Any, x: float, expected: str) -> None:
    assert notification.fmt(kind, x) == expected


def number(last: float | None, unit: str | None = "h") -> QuickLogNumber:
    return QuickLogNumber(
        type="double", key="hours", label="Sleep", unit=unit, min=0, max=24, decimals=1, last_value=last
    )


def test_actions() -> None:
    ident = f"q1|{SERVER_ID}|{TOPIC_ID}|3"
    assert notification.actions(SERVER_ID, TOPIC_ID, 3, number(7.5)) == [
        Action("log", f"{ident}|hours|n|7.5", "Log 7.5 h"),
        Action("input", f"{ident}|hours|i|", "Other value…", "Log", "Value in h"),
    ]
    assert notification.actions(SERVER_ID, TOPIC_ID, 3, number(None, unit=None)) == [
        Action("input", f"{ident}|hours|i|", "Other value…", "Log", "Value"),
    ]
    six = notification.descriptor([enum(6)], counts={}, last=None)
    assert six is not None
    assert notification.actions(SERVER_ID, TOPIC_ID, 3, six) == [
        Action("log", f"{ident}|mood|o|o0", "Option 0"),
        Action("log", f"{ident}|mood|o|o1", "Option 1"),
        Action("log", f"{ident}|mood|o|o2", "Option 2"),
        Action("open", f"{ident}|mood|m|", "More…"),
    ]


def category(quick_log: Any, version: int = 3, server_id: str = SERVER_ID) -> str:
    return notification.category_id(TOPIC_ID, notification.actions(server_id, TOPIC_ID, version, quick_log))


def test_category_id_changes_with_any_part_of_the_actions() -> None:
    base = number(7.5)
    cid = category(base)
    assert cid.startswith(f"quickr.t.{TOPIC_ID}.")
    assert len(cid.rsplit(".", 1)[1]) == 16
    assert category(number(7.5)) == cid  # deterministic
    others = [
        category(base, version=4),
        category(base, server_id="0b9e0000-0000-4000-8000-0000000000bb"),
        category(number(7.0)),
        category(number(None)),
        category(number(7.5, unit="hours")),
    ]
    assert len({cid, *others}) == len(others) + 1
    assert category(base.model_copy(update={"decimals": 2})) == cid  # decimals: display only

    def chips(*labels: str) -> QuickLogEnum:
        options = [QuickLogOption(value=f"o{i}", label=label) for i, label in enumerate(labels)]
        return QuickLogEnum(key="mood", label="Mood", options=options, total_options=len(options))

    ab = category(chips("A", "B"))
    assert category(chips("A", "C")) != ab
    reordered = chips("A", "B").model_copy(update={"options": chips("A", "B").options[::-1]})
    assert category(reordered) != ab
    # 4 -> 5 options: "More…" appears, so a new category even for the same 3 shown.
    three = chips("A", "B", "C")
    assert category(three) != category(three.model_copy(update={"total_options": 5}))


def test_category_hash_input_is_nfc() -> None:
    def chips(label: str) -> QuickLogEnum:
        return QuickLogEnum(
            key="mood", label="Mood", options=[QuickLogOption(value="o0", label=label)], total_options=1
        )

    composed, decomposed = "Café", "Café"
    assert category(chips(composed)) == category(chips(decomposed))
    actions = notification.actions(SERVER_ID, TOPIC_ID, 3, chips(decomposed))
    assert notification.category_hash_input(actions) == (
        f"quickr-cat-v1\u001elog\u001fq1|{SERVER_ID}|{TOPIC_ID}|3|mood|o|o0\u001fCafé"
    )


def test_more_suffix() -> None:
    six = notification.descriptor([enum(6)], counts={}, last=None)
    assert notification.more_suffix(six) == " · 3 of 6 shown, More for all"
    assert notification.more_suffix(notification.descriptor([enum(4)], counts={}, last=None)) == ""
    assert notification.more_suffix(number(1.0)) == ""
    assert notification.more_suffix(None) == ""


def test_canonical_instant() -> None:
    at = datetime(2026, 10, 17, 8, 0, 0, 999999, tzinfo=UTC)
    assert notification.canonical_instant(at) == "2026-10-17T08:00:00Z"
    assert notification.canonical_instant(at.astimezone()) == "2026-10-17T08:00:00Z"


# --- Web Push -----------------------------------------------------------------------------


def test_web_payload_keeps_its_original_fields_byte_for_byte() -> None:
    quick_log = notification.descriptor([enum(6)], counts={}, last=None)
    n = push_svc.Notification(
        kind="due",
        title="Water",
        body="Time to log",
        url="/t/water/record",
        tag=f"due-{TOPIC_ID}",
        topic_slug="water",
        server_id=SERVER_ID,
        topic_id=UUID(TOPIC_ID),
        version=3,
        due_since=datetime(2026, 10, 17, 8, 0, 0, 250000, tzinfo=UTC),
        quick_log=quick_log,
    )
    raw = web_push.render(n).model_dump_json()
    # What every service worker so far received, in the same order and encoding.
    before = (
        '{"title":"Water","body":"Time to log","url":"/t/water/record","tag":"due-%s","topic_slug":"water",'
    )
    assert raw.startswith(before % TOPIC_ID)
    payload = json.loads(raw)
    assert payload["body"] == "Time to log"  # no "More" suffix: that is the APNs actions' text
    assert {k: payload[k] for k in ("v", "kind", "server_id", "topic_id", "version", "due_since")} == {
        "v": 1,
        "kind": "due",
        "server_id": SERVER_ID,
        "topic_id": TOPIC_ID,
        "version": 3,
        "due_since": "2026-10-17T08:00:00Z",
    }
    assert payload["quick_log"]["total_options"] == 6


# --- the scheduler, from real entries -------------------------------------------------------


@pytest.fixture
def sent(monkeypatch: pytest.MonkeyPatch) -> list[push_svc.Notification]:
    """Every notification the scheduler delivers (no targets needed)."""
    notifications: list[push_svc.Notification] = []

    async def fake_deliver(db: Any, pairs: Any, n: push_svc.Notification, ttl: int, **_: Any) -> Any:
        notifications.append(n)
        return push_svc.Delivery(sent=0, failed=0, complete=True)

    monkeypatch.setattr(push_svc, "deliver", fake_deliver)
    return notifications


async def _tick() -> None:
    async with get_sessionmaker()() as db:
        await scheduler.tick(db, now=datetime.now(UTC) + timedelta(days=1))


async def _forget_notified() -> None:
    """Let the scheduler notify the same slot again."""
    async with get_sessionmaker()() as db:
        await db.execute(update(Topic).values(last_notified_due_since=None))
        await db.commit()


def options(n: int) -> list[dict[str, Any]]:
    return [{"value": f"o{i}", "label": f"Option {i}"} for i in range(n)]


async def test_scheduler_ranks_options_by_use_over_every_version(
    client: httpx.AsyncClient, sent: list[push_svc.Notification]
) -> None:
    mood = {"key": "mood", "label": "Mood", "type": "enum", "options": options(4)}
    topic = await make_topic(client, "Mood", [mood], schedule=INTERVAL)
    for value in ["o3", "o3", "o1", "o2", "o1"]:  # o1 and o3 tie at 2
        await record(client, "mood", {"mood": value})
    await _tick()
    (n,) = sent
    assert n.server_id == (await client.get("/changes")).headers["x-quickr-server-id"]
    assert (n.topic_id, n.version) == (UUID(topic["id"]), 1)
    assert values(n.quick_log) == ["o0", "o1", "o2", "o3"]  # 4 options: all, in order

    # Version 2 has 6 options: the counts include version 1's entries.
    six = {**mood, "options": options(6)}
    r = await client.post("/topics/mood/versions", json={"questions": [six], "base_version": 1})
    assert r.status_code == 201, r.text
    await record(client, "mood", {"mood": "o5"})
    await record(client, "mood", {"mood": "o5"})
    await record(client, "mood", {"mood": "o5"})
    sent.clear()
    await _tick()
    (n,) = sent
    assert n.version == 2
    assert values(n.quick_log) == ["o5", "o1", "o3"]
    assert isinstance(n.quick_log, QuickLogEnum)
    assert n.quick_log.total_options == 6


async def test_scheduler_uses_the_latest_value_by_captured_at(
    client: httpx.AsyncClient, sent: list[push_svc.Notification]
) -> None:
    hours = {
        "key": "hours",
        "label": "Sleep",
        "type": "double",
        "min": 0,
        "max": 24,
        "decimals": 1,
        "unit": "h",
    }
    await make_topic(client, "Sleep", [hours], schedule=INTERVAL)
    now = datetime.now(UTC)
    await record(client, "sleep", {"hours": 6.5}, captured_at=(now - timedelta(hours=1)).isoformat())
    await record(client, "sleep", {"hours": 8}, captured_at=(now - timedelta(hours=3)).isoformat())  # older
    await _tick()
    (n,) = sent
    assert isinstance(n.quick_log, QuickLogNumber)
    assert (n.quick_log.type, n.quick_log.last_value, n.quick_log.unit) == ("double", 6.5, "h")

    # A newer version caps it at 6: 6.5 isn't a valid answer any more.
    r = await client.post(
        "/topics/sleep/versions", json={"questions": [{**hours, "max": 6}], "base_version": 1}
    )
    assert r.status_code == 201, r.text
    await _forget_notified()
    sent.clear()
    await _tick()
    (n,) = sent
    assert isinstance(n.quick_log, QuickLogNumber)
    assert (n.version, n.quick_log.last_value) == (2, None)


async def test_scheduler_without_entries_or_quick_log(
    client: httpx.AsyncClient, sent: list[push_svc.Notification]
) -> None:
    await make_topic(client, "Count", [{"key": "n", "label": "N", "type": "int"}], schedule=INTERVAL)
    note = {"key": "note", "label": "Note", "type": "str"}
    await make_topic(client, "Diary", [note], schedule=INTERVAL)
    await _tick()
    by_slug = {n.topic_slug: n for n in sent}
    count = by_slug["count"].quick_log
    assert isinstance(count, QuickLogNumber)
    assert count.last_value is None
    assert by_slug["diary"].quick_log is None
    assert by_slug["diary"].due_since is not None
