"""Live Activity payload vectors: ``shared/fixtures/live-activity-vectors.json``.

Generated from ``app/services/push/live_activity.py`` (docs/specs/timers.md §10.3, §10.4;
timers2.md §8): each case is a run's events, folded as the server folds them, and the exact APNs
body the server sends for it at ``meta.timestamp``. The iOS app's ``LiveActivityVectorTests``
decodes each ``content-state`` into ``RunActivityState`` and each start's ``attributes`` into
``RunActivityAttributes``, and builds each case's ``run`` (its events, in the run-fold vectors'
shape, folded over the case's ``timer`` set; the server's status when it isn't the fold's; the
revision) into the same content state, at the same instant.

``timer_sets`` are the run-fold vectors' timers (timers2.md §3.1) plus ``long``, ``budget`` and
``escapes``, each the normalised ``Timer`` v2 a version serves. The fold reads only their steps
and lap types; the alerts and variables here are what ``alert_at`` and ``alert_label`` read
(timers2.md §8.1), so the §3.1 sets carry some on top.

**Byte budget (timers2.md §8.2).** ``encode`` fits the body to a limit by truncating
``alert_label``, ``next_label``, ``label`` and ``attributes.topic_name`` to 32 characters in that
order, then the terminal step. With the 64-character caps the largest M1 body is about 3.2 KB
(every character a six-byte ``\\u001f`` escape; asserted below), so nothing M1 can send reaches
4 096 bytes; the margin is M3's ``attributes.appearance``. The two budget cases therefore pin the
algorithm at a ``budget.limit`` below 4 096, chosen so the expected steps fire: the encoder is the
same, only the limit is lowered.

Every ``aps`` key is Apple's, checked against "Starting and updating Live Activities with
ActivityKit push notifications" (developer.apple.com/documentation/activitykit/
starting-and-updating-live-activities-with-activitykit-push-notifications, read 2026-10-24):
``timestamp`` (seconds since 1970), ``event`` (``start`` / ``update`` / ``end``),
``content-state``, ``stale-date``, ``dismissal-date`` (within four hours; a past date dismisses
at once), and for ``start`` the required ``attributes-type``, ``attributes`` and ``alert``, plus
iOS 18's ``input-push-token: 1``. The same page gives the headers in ``meta.headers``.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the committed file
must match.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from app.schemas.questions import Timer as TimerV2
from app.services import run_fold
from app.services.entries import fold_timer
from app.services.notification import truncate
from app.services.push import live_activity as la
from app.services.push.apns import MAX_PAYLOAD_BYTES
from app.services.push.base import PushFailed
from app.services.run_fold import Event
from tests.vectors import FIXTURES_DIR, check_or_write, dump_json

PATH = FIXTURES_DIR / "live-activity-vectors.json"
GENERATOR_VERSION = 3

SERVER_ID = "11111111-1111-4111-8111-111111111111"
TOPIC_ID = "33333333-3333-4333-8333-333333333333"
RUN = "0a000000-0000-4000-8000-000000000000"
T0 = run_fold.parse_instant("2026-10-23T08:00:00Z")
TIMESTAMP = (T0 + 600_000) // 1000  # when the push goes out: ten minutes in
NOW_MS = TIMESTAMP * 1000

# Characters for the budget cases: a four-byte code point, and three that JSON escapes ("\"",
# "\\" take two bytes; U+001F takes six, "\u001f").
FOUR = "\U0001d11e"  # 𝄞
ESC = "\u001f"
MIXED = (FOUR + '"' + "\\" + ESC) * 50  # 200 characters, about 3.75 bytes each encoded


def _alert(key: str, label: str, at: str) -> dict[str, str]:
    return {"key": key, "label": label, "at": at}


# timers2.md §3.1's sets (their steps and lap types as the run-fold vectors), with alerts and
# variables on top, plus the long-label sets.
TIMERS_IN: dict[str, dict[str, Any]] = {
    "none": {"steps": [], "laps": []},
    "two": {
        "steps": [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}],
        "laps": [],
    },
    "three": {
        "steps": [
            {"key": "shower", "label": "Shower"},
            {"key": "breakfast", "label": "Breakfast", "alerts": [_alert("eat", "Eat up", "10m")]},
            {"key": "dress", "label": "Get dressed"},
        ],
        "laps": [],
    },
    "renamed": {"steps": [], "laps": [{"key": "cig", "label": "Cig"}]},
    "tiktok": {
        "steps": [],
        "laps": [
            # Listed out of order: the next alert is by at_ms, then position.
            {
                "key": "run",
                "label": "Run",
                "alerts": [_alert("time", "Time", "t"), _alert("half", "Half way", "t/2")],
            },
            {"key": "rest", "label": "Rest", "alerts": [_alert("go", "Go", "rest")]},
        ],
        "variables": [{"name": "t", "ms": 900_000}, {"name": "rest", "ms": 600_000}],
    },
    "three_types": {
        "steps": [{"key": "warmup", "label": "Warmup"}],
        "laps": [
            {"key": "run", "label": "Run"},
            {"key": "rest", "label": "Rest"},
            {"key": "walk", "label": "Walk"},
        ],
    },
    # The longest labels a topic can have (steps 200, lap types and alerts 64), all four-byte code
    # points: the payload carries 64 of each.
    "long": {
        "steps": [
            {
                "key": f"s{i}",
                "label": chr(0x1F600 + i) * 200,
                "alerts": [_alert("a", chr(0x1F550 + i % 12) * 64, "1h")] if i == 0 else [],
            }
            for i in range(30)
        ],
        "laps": [],
    },
    # Four-byte code points mixed with JSON-escaped characters.
    "budget": {
        "steps": [
            {"key": "first", "label": MIXED, "alerts": [_alert("a", MIXED[:64], "1h")]},
            {"key": "second", "label": MIXED[1:] + FOUR},
        ],
        "laps": [],
    },
    # Every character a six-byte escape: the largest body M1 can send.
    "escapes": {
        "steps": [
            {"key": "first", "label": ESC * 200, "alerts": [_alert("a", ESC * 64, "1h")]},
            {"key": "second", "label": ESC * 200},
        ],
        "laps": [],
    },
}

TIMERS: dict[str, TimerV2] = {name: TimerV2.model_validate(t) for name, t in TIMERS_IN.items()}


def eid(n: int) -> str:
    return f"0e000000-0000-4000-8000-{n:012d}"


def ev(n: int, type_: str, seconds: float, *, target: int | None = None, **fields: Any) -> Event:
    return Event(
        id=RUN if n == 0 else eid(n),
        type=type_,  # type: ignore[arg-type]
        at=T0 + round(seconds * 1000),
        target=None if target is None else eid(target),
        **fields,
    )


def state_of(timer: TimerV2, events: list[Event], status: str | None = None) -> dict[str, Any]:
    """The run's stored state (``RunOut.state``), as the server keeps it."""
    state = run_fold.state_json(run_fold.fold(RUN, fold_timer(timer), events))
    if status is not None:  # the server's own statuses: finishing (§3.5)
        state["status"] = status
    return state


def case(
    name: str,
    event: la.Event,
    timer: str,
    events: list[Event],
    *,
    revision: int,
    status: str | None = None,
    topic_name: str = "Morning routine",
    limit: int = MAX_PAYLOAD_BYTES,
) -> dict[str, Any]:
    state = la.content_state(
        RUN, revision, state_of(TIMERS[timer], events, status), TIMERS[timer], now=NOW_MS
    )
    attrs = la.attributes(SERVER_ID, TOPIC_ID, topic_name) if event == "start" else None
    body = la.payload(event, state, timestamp=TIMESTAMP, attrs=attrs)
    data, steps = la.fit(body, limit=limit)
    assert len(data) <= limit <= MAX_PAYLOAD_BYTES
    run = {"events": [wire(e) for e in events], "status": status, "revision": revision}
    out: dict[str, Any] = {
        "name": name,
        "event": event,
        "timer": timer,
        "topic_name": topic_name,
        "run": run,
        "payload": json.loads(data),
        "bytes": len(data),
    }
    if limit != MAX_PAYLOAD_BYTES or steps:
        out["budget"] = {"limit": limit, "steps": list(steps)}
    return out


def wire(e: Event) -> dict[str, Any]:
    """An event as the run-fold vectors write it (``at`` in the server's instant form)."""
    return {
        "id": e.id,
        "type": e.type,
        "at": run_fold.format_instant(e.at),
        "seg": e.seg,
        "step": e.step,
        "pause_id": e.pause_id,
        "target": e.target,
    }


START = ev(0, "start", 0)


def start_body(timer: str, topic_name: str) -> dict[str, Any]:
    state = la.content_state(RUN, 1, state_of(TIMERS[timer], [START]), TIMERS[timer], now=NOW_MS)
    return la.payload(
        "start", state, timestamp=TIMESTAMP, attrs=la.attributes(SERVER_ID, TOPIC_ID, topic_name)
    )


def sizes(body: dict[str, Any]) -> list[int]:
    """The encoded size before any step, then after each step of the budget order in turn."""
    out = [len(la.dump(body))]
    for step in la.BUDGET_STEPS:
        body = la.shrink(body, step)
        out.append(len(la.dump(body)))
    return out


def fixed_bound() -> int:
    """timers2.md §8.2's bound after the terminal step, computed: a ``start`` with every
    non-label field at its widest (each integer at 10 digits, each Double at 17 characters,
    ``status`` at 10, ``lap_type`` at 63), ``label`` (and the alert body, its copy) at 32
    six-byte escapes truncated, ``next_label`` and ``alert_label`` null, ``topic_name`` empty."""
    wide_int, wide_double = 9_999_999_999, 1234567890.1234567
    label = truncate(ESC * 64, la.BUDGET_LABEL_LENGTH)
    state = {
        "v": wide_int,
        "run_id": RUN,
        "revision": wide_int,
        "status": "x" * 10,
        "started_at": wide_double,
        "seg": wide_int,
        "seg_started_at": wide_double,
        "label": label,
        "step_index": wide_int,
        "step_count": wide_int,
        "next_label": None,
        "paused_at": wide_double,
        "paused_ms_before_seg": wide_int,
        "paused_ms_in_seg": wide_int,
        "ended_at": wide_double,
        "active_ms": wide_int,
        "lap_type": "a" * 63,
        "lap_count": wide_int,
        "alert_at": wide_double,
        "alert_label": None,
    }
    assert set(state) == STATE_KEYS
    attrs = {"server_id": SERVER_ID, "topic_id": TOPIC_ID, "topic_name": ""}
    body = la.payload("start", state, timestamp=wide_int, attrs=attrs)
    return len(la.dump(body))


def budget_cases() -> list[dict[str, Any]]:
    # payload_budget_truncation: the limit is the size after all four truncations, so each of
    # the four fires and the terminal step doesn't.
    mixed = sizes(start_body("budget", MIXED))
    assert mixed[0] <= MAX_PAYLOAD_BYTES  # untruncated it fits 4 096 (module docstring)
    assert mixed[0] > mixed[1] > mixed[2] > mixed[3] > mixed[4]
    # payload_budget_terminal: the limit is the size after the terminal step.
    escapes = sizes(start_body("escapes", ESC * 200))
    assert escapes[4] > escapes[5]
    assert escapes[5] <= fixed_bound()
    return [
        case(
            "payload_budget_truncation",
            "start",
            "budget",
            [START],
            revision=1,
            topic_name=MIXED,
            limit=mixed[4],
        ),
        case(
            "payload_budget_terminal",
            "start",
            "escapes",
            [START],
            revision=1,
            topic_name=ESC * 200,
            limit=escapes[5],
        ),
    ]


def build() -> dict[str, Any]:
    cases = [
        case("start", "start", "three", [START], revision=1),
        case("start_longest_labels", "start", "long", [START], revision=1, topic_name="\U0001d11e" * 200),
        case("start_renamed_laps", "start", "renamed", [START], revision=1, topic_name="Smoking"),
        case("update_running", "update", "three", [START, ev(1, "next", 120, seg=0)], revision=2),
        case(
            "update_paused",
            "update",
            "three",
            [
                START,
                ev(1, "pause", 30),
                ev(2, "resume", 60, pause_id=eid(1)),
                ev(3, "next", 120, seg=0),
                ev(4, "pause", 200),
            ],
            revision=5,
        ),
        case(
            "update_next_while_paused",
            "update",
            "three",
            [START, ev(1, "pause", 100), ev(2, "next", 120, seg=0)],
            revision=3,
        ),
        case(
            "update_last_step",
            "update",
            "three",
            [START, ev(1, "next", 120, seg=0), ev(2, "skip", 130, seg=1, step="breakfast")],
            revision=3,
        ),
        case("update_no_steps", "update", "none", [START, ev(1, "lap", 90, seg=0)], revision=2),
        # Run 2 is open: the next lap is a Rest, and no step is (timers2.md §8.2).
        case(
            "update_tiktok_lap",
            "update",
            "tiktok",
            [START, ev(1, "lap", 60, seg=0), ev(2, "lap", 120, seg=1)],
            revision=3,
        ),
        # A 300 s pause inside Run 1 moves its alerts 300 s later.
        case(
            "update_alert_pending",
            "update",
            "tiktok",
            [START, ev(1, "pause", 100), ev(2, "resume", 400, pause_id=eid(1))],
            revision=3,
        ),
        case(
            "update_alert_paused",
            "update",
            "tiktok",
            [START, ev(1, "pause", 100), ev(2, "resume", 400, pause_id=eid(1)), ev(3, "pause", 500)],
            revision=4,
        ),
        # Stopped at 200 s and reopened at 300 s: the gap is a pause of Rest 1.
        case(
            "update_reopened",
            "update",
            "tiktok",
            [START, ev(1, "lap", 60, seg=0), ev(2, "stop", 200), ev(3, "reopen", 300, target=2)],
            revision=4,
        ),
        *budget_cases(),
        case(
            "end_stopped",
            "end",
            "three",
            [
                START,
                ev(1, "pause", 30),
                ev(2, "resume", 60, pause_id=eid(1)),
                ev(3, "next", 120, seg=0),
                ev(4, "stop", 462),
            ],
            revision=5,
        ),
        case(
            "end_finishing",
            "end",
            "none",
            [START, ev(1, "lap", 90, seg=0), ev(2, "stop", 300)],
            revision=3,
            status="finishing",
        ),
        case("end_discarded", "end", "three", [START, ev(1, "discard", 40)], revision=2),
        # A finishing run discarded (§3.7): its stop's ended_at is not what was saved.
        case(
            "end_discarded_finishing",
            "end",
            "none",
            [START, ev(1, "stop", 60)],
            revision=3,
            status="discarded",
        ),
    ]
    return {
        "meta": {
            "generator": "backend/tests/test_live_activity_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "source": "backend/app/services/push/live_activity.py; docs/specs/timers.md §10.3, §10.4; "
            "docs/specs/timers2.md §8",
            "apple": "https://developer.apple.com/documentation/activitykit/"
            "starting-and-updating-live-activities-with-activitykit-push-notifications",
            "headers": {
                "apns-push-type": "liveactivity",
                "apns-topic": "<bundle id>.push-type.liveactivity",
                "apns-priority": "10",
            },
            "attributes_type": la.ATTRIBUTES_TYPE,
            "max_label_length": la.MAX_LABEL_LENGTH,
            "max_bytes": MAX_PAYLOAD_BYTES,
            "stale_seconds": la.STALE_SECONDS,
            "dismiss_seconds": la.DISMISS_SECONDS,
            "timestamp": TIMESTAMP,
            "budget": {
                "label_length": la.BUDGET_LABEL_LENGTH,
                "steps": list(la.BUDGET_STEPS),
                "fixed_bound": fixed_bound(),
            },
        },
        "timer_sets": {name: t.model_dump(mode="json") for name, t in TIMERS.items()},
        "cases": cases,
    }


STATE_KEYS = {
    "v", "run_id", "revision", "status", "started_at", "seg", "seg_started_at", "label", "step_index",
    "step_count", "next_label", "paused_at", "paused_ms_before_seg", "paused_ms_in_seg", "ended_at",
    "active_ms", "lap_type", "lap_count", "alert_at", "alert_label",
}  # fmt: skip

CASE_NAMES = {
    # v1
    "start", "start_longest_labels", "update_running", "update_paused", "update_next_while_paused",
    "update_last_step", "update_no_steps", "end_stopped", "end_finishing", "end_discarded",
    "end_discarded_finishing",
    # timers2.md §8.2
    "update_tiktok_lap", "update_alert_pending", "update_alert_paused", "start_renamed_laps",
    "update_reopened",
    "payload_budget_truncation", "payload_budget_terminal",
}  # fmt: skip


def test_live_activity_vectors() -> None:
    check_or_write(PATH, dump_json(build()))


def test_case_list() -> None:
    """Every case timers2.md §8.2 names, and each name once."""
    names = [c["name"] for c in json.loads(PATH.read_text())["cases"]]
    assert len(names) == len(set(names))
    assert set(names) == CASE_NAMES
    assert json.loads(PATH.read_text())["meta"]["generator_version"] == 3


def test_vector_shapes() -> None:
    """Each event carries exactly Apple's keys for it, and the content state its fields."""
    doc = json.loads(PATH.read_text())
    common = {"timestamp", "event", "content-state"}
    keys = {
        "start": common | {"stale-date", "attributes-type", "attributes", "alert", "input-push-token"},
        "update": common | {"stale-date"},
        "end": common | {"dismissal-date"},
    }
    events = {c["event"] for c in doc["cases"]}
    assert events == {"start", "update", "end"}
    for c in doc["cases"]:
        aps = c["payload"]["aps"]
        assert set(c["payload"]) == {"aps"}
        assert set(aps) == keys[c["event"]], c["name"]
        assert aps["event"] == c["event"]
        assert set(aps["content-state"]) == STATE_KEYS
        assert "terminal_id" not in aps["content-state"]  # timers2.md §8.1
        assert aps["content-state"]["v"] == la.CONTENT_STATE_VERSION == 1
        assert c["bytes"] <= MAX_PAYLOAD_BYTES
        assert c["bytes"] == len(la.dump(c["payload"]))
        state = aps["content-state"]
        for label in (state["label"], state["next_label"] or "", state["alert_label"] or ""):
            assert len(label) <= la.MAX_LABEL_LENGTH
        if c["event"] == "start":
            assert "steps" not in aps["attributes"]
            assert set(aps["attributes"]) == {"server_id", "topic_id", "topic_name"}
            assert len(aps["attributes"]["topic_name"]) <= la.MAX_LABEL_LENGTH


def test_content_state_values() -> None:
    by_name = {c["name"]: c["payload"]["aps"] for c in json.loads(PATH.read_text())["cases"]}
    t0 = T0 / 1000

    paused = by_name["update_paused"]["content-state"]
    assert paused["status"] == "paused"
    assert paused["seg"] == 1
    assert paused["label"] == "Breakfast"
    assert paused["step_index"] == 1
    assert paused["step_count"] == 3
    assert paused["next_label"] == "Get dressed"
    assert paused["seg_started_at"] == t0 + 120
    assert paused["paused_at"] == t0 + 200
    assert paused["paused_ms_before_seg"] == 30_000
    assert paused["paused_ms_in_seg"] == 0
    assert (paused["alert_at"], paused["alert_label"]) == (None, None)  # Breakfast's, but paused

    running = by_name["update_running"]["content-state"]
    assert (running["alert_at"], running["alert_label"]) == (t0 + 120 + 600, "Eat up")  # a step's alert
    assert (running["lap_type"], running["lap_count"]) == (None, 0)

    straddle = by_name["update_next_while_paused"]["content-state"]
    assert straddle["paused_at"] == t0 + 100
    assert straddle["seg_started_at"] == t0 + 120

    last = by_name["update_last_step"]["content-state"]
    assert last["label"] == "Get dressed"
    assert last["step_index"] == 2
    assert last["next_label"] is None
    assert last["alert_at"] is None  # no alerts

    laps = by_name["update_no_steps"]["content-state"]
    assert laps["label"] == "Lap 2"
    assert laps["step_index"] is None
    assert laps["step_count"] == 0
    assert (laps["lap_type"], laps["lap_count"], laps["next_label"]) == (None, 1, None)  # untyped

    tiktok = by_name["update_tiktok_lap"]["content-state"]
    assert (tiktok["label"], tiktok["lap_type"], tiktok["lap_count"]) == ("Run 2", "run", 2)
    assert tiktok["next_label"] == "Rest"
    assert tiktok["step_index"] is None
    # Half way (450 s) has passed 480 s into Run 2; Time (900 s) is next.
    assert (tiktok["alert_at"], tiktok["alert_label"]) == (t0 + 120 + 900, "Time")

    pending = by_name["update_alert_pending"]["content-state"]
    assert pending["paused_ms_in_seg"] == 300_000
    assert (pending["alert_at"], pending["alert_label"]) == (t0 + 300 + 450, "Half way")

    alert_paused = by_name["update_alert_paused"]["content-state"]
    assert alert_paused["paused_at"] == t0 + 500
    assert (alert_paused["alert_at"], alert_paused["alert_label"]) == (None, None)
    assert (alert_paused["lap_type"], alert_paused["next_label"]) == ("run", "Rest")

    renamed = by_name["start_renamed_laps"]
    state = renamed["content-state"]
    assert (state["label"], state["lap_type"], state["lap_count"], state["next_label"]) == (
        "Cig 1",
        "cig",
        0,
        "Cig",
    )
    assert (state["alert_at"], state["alert_label"]) == (None, None)
    assert renamed["alert"] == {"title": "Smoking", "body": "Cig 1"}

    reopened = by_name["update_reopened"]["content-state"]
    assert reopened["status"] == "running"
    assert (reopened["label"], reopened["lap_type"], reopened["lap_count"]) == ("Rest 1", "rest", 1)
    assert reopened["paused_ms_in_seg"] == 100_000  # the gap, 200 s to 300 s
    assert (reopened["ended_at"], reopened["active_ms"]) == (None, None)
    assert (reopened["alert_at"], reopened["alert_label"]) == (t0 + 60 + 100 + 600, "Go")

    stopped = by_name["end_stopped"]
    assert stopped["content-state"]["status"] == "stopped"
    assert stopped["content-state"]["active_ms"] == 462_000 - 30_000  # "Saved · 7:12"
    assert stopped["content-state"]["ended_at"] == t0 + 462
    assert stopped["content-state"]["alert_at"] is None  # closed
    assert stopped["dismissal-date"] == TIMESTAMP + la.DISMISS_SECONDS

    discarded = by_name["end_discarded"]
    assert discarded["content-state"]["status"] == "discarded"
    assert discarded["content-state"]["ended_at"] is None
    assert discarded["content-state"]["active_ms"] is None
    assert discarded["dismissal-date"] < TIMESTAMP  # dismissed at once
    late = by_name["end_discarded_finishing"]["content-state"]
    assert late["ended_at"] is None
    assert late["active_ms"] is None

    assert by_name["end_finishing"]["content-state"]["status"] == "finishing"
    assert by_name["start"]["stale-date"] == TIMESTAMP + la.STALE_SECONDS
    assert by_name["start"]["alert"] == {"title": "Morning routine", "body": "Shower"}


def test_budget_cases() -> None:
    doc = json.loads(PATH.read_text())
    by_name = {c["name"]: c for c in doc["cases"]}

    longest = by_name["start_longest_labels"]
    assert "budget" not in longest  # fits untruncated
    aps = longest["payload"]["aps"]
    state = aps["content-state"]
    for text in (state["label"], state["next_label"], state["alert_label"], aps["attributes"]["topic_name"]):
        assert len(text) == la.MAX_LABEL_LENGTH
        assert len(text.encode()) > 4 * (la.MAX_LABEL_LENGTH - 1)  # four-byte code points

    truncation = by_name["payload_budget_truncation"]
    assert truncation["budget"]["steps"] == ["alert_label", "next_label", "label", "topic_name"]
    assert truncation["bytes"] <= truncation["budget"]["limit"]
    aps = truncation["payload"]["aps"]
    state = aps["content-state"]
    for text in (state["label"], state["next_label"], state["alert_label"], aps["attributes"]["topic_name"]):
        assert len(text) == la.BUDGET_LABEL_LENGTH
        assert text.endswith("…")
    assert aps["alert"] == {"title": aps["attributes"]["topic_name"], "body": state["label"]}

    terminal = by_name["payload_budget_terminal"]
    assert terminal["budget"]["steps"] == [*la.BUDGET_STEPS]
    aps = terminal["payload"]["aps"]
    state = aps["content-state"]
    assert (state["next_label"], state["alert_label"], aps["attributes"]["topic_name"]) == (None, None, "")
    assert len(state["label"]) == la.BUDGET_LABEL_LENGTH
    assert aps["alert"] == {"title": "", "body": state["label"]}
    assert terminal["bytes"] <= doc["meta"]["budget"]["fixed_bound"] < 1800  # timers2.md §8.2


# --- alert_at (timers2.md §8.1, §9.1) -------------------------------------------------------


def tiktok_state(events: list[Event], now_s: float) -> dict[str, Any]:
    return la.content_state(
        RUN, 1, state_of(TIMERS["tiktok"], events), TIMERS["tiktok"], now=T0 + round(now_s * 1000)
    )


def test_alert_at_counts_only_the_pause_inside_the_segment() -> None:
    """A pause straddling the lap boundary: only its part after the segment start delays the
    segment's alerts (``paused_ms_in_seg``)."""
    events = [START, ev(1, "pause", 50), ev(2, "lap", 60, seg=0), ev(3, "resume", 80, pause_id=eid(1))]
    state = tiktok_state(events, 100)
    assert (state["label"], state["seg_started_at"]) == ("Rest 1", (T0 + 60_000) / 1000)
    assert (state["paused_ms_before_seg"], state["paused_ms_in_seg"]) == (10_000, 20_000)
    assert (state["alert_at"], state["alert_label"]) == ((T0 + 60_000 + 20_000 + 600_000) / 1000, "Go")


def test_alert_at_is_null_while_paused_and_moves_by_the_pause_on_resume() -> None:
    before = tiktok_state([START], 10)
    assert (before["alert_at"], before["alert_label"]) == ((T0 + 450_000) / 1000, "Half way")
    paused = tiktok_state([START, ev(1, "pause", 100)], 200)
    assert (paused["alert_at"], paused["alert_label"]) == (None, None)
    resumed = tiktok_state([START, ev(1, "pause", 100), ev(2, "resume", 220, pause_id=eid(1))], 230)
    assert resumed["alert_at"] == before["alert_at"] + 120  # the pause's length
    assert resumed["alert_label"] == "Half way"


def test_alert_at_skips_passed_alerts_and_nulls_when_none_remain() -> None:
    assert tiktok_state([START], 450)["alert_label"] == "Time"  # at_ms > active: 450 s has passed
    assert tiktok_state([START], 449.999)["alert_label"] == "Half way"
    done = tiktok_state([START], 900)
    assert (done["alert_at"], done["alert_label"]) == (None, None)


def test_alert_at_ties_go_by_position() -> None:
    timer = TimerV2.model_validate(
        {
            "steps": [],
            "laps": [{"key": "x", "label": "X", "alerts": [_alert("b", "B", "1m"), _alert("a", "A", "60s")]}],
        }
    )
    state = la.content_state(RUN, 1, state_of(timer, [START]), timer, now=T0)
    assert (state["alert_at"], state["alert_label"]) == ((T0 + 60_000) / 1000, "B")


def test_no_timer_has_no_alert() -> None:
    state = la.content_state(
        RUN, 1, state_of(TimerV2(steps=[], laps=[], variables=[]), [START]), None, now=T0
    )
    assert (state["alert_at"], state["alert_label"], state["lap_type"], state["next_label"]) == (None,) * 4
    assert (state["step_count"], state["lap_count"]) == (0, 0)


# --- the byte budget (timers2.md §8.2), one test per step -------------------------------------


@pytest.mark.parametrize("k", range(1, len(la.BUDGET_STEPS) + 1))
def test_budget_stops_after_step(k: int) -> None:
    """With the limit at the size after step ``k``, exactly the first ``k`` steps fire, in order."""
    body = start_body("escapes", ESC * 200)
    limit = sizes(body)[k]
    data, steps = la.fit(body, limit=limit)
    assert steps == la.BUDGET_STEPS[:k]
    assert len(data) <= limit
    aps = json.loads(data)["aps"]
    state, attrs = aps["content-state"], aps["attributes"]
    fields = {
        "alert_label": state["alert_label"],
        "next_label": state["next_label"],
        "label": state["label"],
        "topic_name": attrs["topic_name"],
    }
    sent = body["aps"]
    untruncated = (
        *(sent["content-state"][f] for f in ("alert_label", "next_label", "label")),
        sent["attributes"]["topic_name"],
    )
    assert all(len(text) == la.MAX_LABEL_LENGTH for text in untruncated)  # the payload's caps
    for i, name in enumerate(la.BUDGET_STEPS[:4]):
        if k == 5 and name != "label":
            assert fields[name] in (None, "")  # the terminal step
        elif i < k:
            assert fields[name] == truncate(ESC * 64, la.BUDGET_LABEL_LENGTH), name
        else:
            assert len(fields[name]) == la.MAX_LABEL_LENGTH, name
    # The start's alert follows the fitted label and topic name.
    assert aps["alert"] == {"title": attrs["topic_name"], "body": state["label"] or attrs["topic_name"]}


def test_budget_largest_m1_body_fits_untruncated() -> None:
    """Every label at 64 six-byte escapes: about 3.2 KB, so nothing M1 sends is truncated."""
    data, steps = la.fit(start_body("escapes", ESC * 200))
    assert steps == ()
    assert len(data) <= MAX_PAYLOAD_BYTES
    assert data == la.encode(start_body("escapes", ESC * 200))


def test_budget_raises_when_nothing_fits() -> None:
    with pytest.raises(PushFailed):
        la.fit(start_body("escapes", ESC * 200), limit=100)
    with pytest.raises(PushFailed):  # not a Live Activity body: nothing to truncate
        la.encode({"aps": {"alert": "x" * MAX_PAYLOAD_BYTES}})


def test_budget_skips_missing_fields_on_an_update() -> None:
    """An update carries no attributes: its topic-name step changes nothing."""
    state = la.content_state(RUN, 1, state_of(TIMERS["escapes"], [START]), TIMERS["escapes"], now=NOW_MS)
    body = la.payload("update", state, timestamp=TIMESTAMP)
    assert la.shrink(body, "topic_name") == body
    assert "attributes" not in la.shrink(body, "terminal")["aps"]
