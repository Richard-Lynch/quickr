"""Live Activity payload vectors: ``shared/fixtures/live-activity-vectors.json``.

Generated from ``app/services/push/live_activity.py`` (docs/specs/timers.md §10.3, §10.4): each
case is a run's events, folded as the server folds them, and the exact APNs body the server
sends for it. The iOS app's ``LiveActivityVectorTests`` decodes each ``content-state`` into
``RunActivityState`` and each start's ``attributes`` into ``RunActivityAttributes``.

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

from app.services import run_fold
from app.services.push import live_activity as la
from app.services.push.apns import MAX_PAYLOAD_BYTES
from app.services.run_fold import Event, Step
from tests.vectors import FIXTURES_DIR, check_or_write, dump_json

PATH = FIXTURES_DIR / "live-activity-vectors.json"
GENERATOR_VERSION = 1

SERVER_ID = "11111111-1111-4111-8111-111111111111"
TOPIC_ID = "33333333-3333-4333-8333-333333333333"
RUN = "0a000000-0000-4000-8000-000000000000"
T0 = run_fold.parse_instant("2026-10-23T08:00:00Z")
TIMESTAMP = (T0 + 600_000) // 1000  # when the push goes out: ten minutes in

STEP_SETS: dict[str, list[Step]] = {
    "none": [],
    "three": [Step("shower", "Shower"), Step("breakfast", "Breakfast"), Step("dress", "Get dressed")],
    # The longest labels a topic can have (MAX_LABEL_LENGTH 200): the payload carries 64.
    "long": [Step(f"s{i}", f"{i:02d}" + "é" * 198) for i in range(30)],
}


def eid(n: int) -> str:
    return f"0e000000-0000-4000-8000-{n:012d}"


def ev(n: int, type_: str, seconds: float, **fields: Any) -> Event:
    return Event(id=RUN if n == 0 else eid(n), type=type_, at=T0 + round(seconds * 1000), **fields)  # type: ignore[arg-type]


def state_of(steps: list[Step], events: list[Event], status: str | None = None) -> dict[str, Any]:
    """The run's stored state (``RunOut.state``), as the server keeps it."""
    state = run_fold.state_json(run_fold.fold(RUN, steps, events))
    if status is not None:  # the server's own statuses: finishing (§3.5)
        state["status"] = status
    return state


def case(
    name: str,
    event: la.Event,
    steps: str,
    events: list[Event],
    *,
    revision: int,
    status: str | None = None,
    topic_name: str = "Morning routine",
) -> dict[str, Any]:
    state = la.content_state(RUN, revision, state_of(STEP_SETS[steps], events, status), STEP_SETS[steps])
    attrs = la.attributes(SERVER_ID, TOPIC_ID, topic_name) if event == "start" else None
    body = la.payload(event, state, timestamp=TIMESTAMP, attrs=attrs)
    size = len(la.encode(body))
    assert size <= MAX_PAYLOAD_BYTES
    return {"name": name, "event": event, "steps": steps, "payload": body, "bytes": size}


START = ev(0, "start", 0)


def build() -> dict[str, Any]:
    cases = [
        case("start", "start", "three", [START], revision=1),
        case(
            "start_longest_labels",
            "start",
            "long",
            [START],
            revision=1,
            topic_name="T" * 200,
        ),
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
            "source": "backend/app/services/push/live_activity.py; docs/specs/timers.md §10.3, §10.4",
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
        },
        "step_sets": {
            name: [{"key": s.key, "label": s.label} for s in steps] for name, steps in STEP_SETS.items()
        },
        "cases": cases,
    }


def test_live_activity_vectors() -> None:
    check_or_write(PATH, dump_json(build()))


def test_vector_shapes() -> None:
    """Each event carries exactly Apple's keys for it, and the content state its fields."""
    doc = json.loads(PATH.read_text())
    state_keys = {
        "v", "run_id", "revision", "status", "started_at", "seg", "seg_started_at", "label", "step_index",
        "step_count", "next_label", "paused_at", "paused_ms_before_seg", "paused_ms_in_seg", "ended_at",
        "active_ms",
    }  # fmt: skip
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
        assert set(aps["content-state"]) == state_keys
        assert c["bytes"] <= MAX_PAYLOAD_BYTES
        for label in (aps["content-state"]["label"], aps["content-state"]["next_label"] or ""):
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

    straddle = by_name["update_next_while_paused"]["content-state"]
    assert straddle["paused_at"] == t0 + 100
    assert straddle["seg_started_at"] == t0 + 120

    last = by_name["update_last_step"]["content-state"]
    assert last["label"] == "Get dressed"
    assert last["step_index"] == 2
    assert last["next_label"] is None

    laps = by_name["update_no_steps"]["content-state"]
    assert laps["label"] == "Lap 2"
    assert laps["step_index"] is None
    assert laps["step_count"] == 0

    stopped = by_name["end_stopped"]
    assert stopped["content-state"]["status"] == "stopped"
    assert stopped["content-state"]["active_ms"] == 462_000 - 30_000  # "Saved · 7:12"
    assert stopped["content-state"]["ended_at"] == t0 + 462
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
