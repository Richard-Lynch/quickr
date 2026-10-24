"""API response fixtures for the Swift client: ``shared/fixtures/api/*.json``.

One scenario drives the real app (ASGI client, test database) through every
response shape the iOS client decodes, and each recorded call becomes one file:
``{operation_id, request: {method, path, body}, status, body}``, named
``<operationId>[.<variant>].json``. Adding an endpoint is one ``rec(...)`` line.

Only the Python clock is frozen: ``app.services.topics.datetime`` (due
computation) reads ``FROZEN_NOW``. Schedules are backdated to
``SCHEDULE_SET_AT``, so due state is a real, deterministic value. Every recorded
entry carries an explicit ``captured_at``: a defaulted one would be the
database clock, which is never stable. The database clock (Postgres ``now()``:
``created_at``, ``updated_at``, ``archived_at``, ``deleted_at``, the feed's
``server_time``) can't be frozen, so it is normalised, only at known response
paths and only after checking the original is a timezone-aware ISO-8601
datetime:

- ``DB_CLOCK_KEYS`` on topics, entries, versions, push subscriptions and APNs devices become
  ``SERVER_TIME`` unless they hold one of the pinned instants;
- server-generated UUIDs become ``00000000-0000-4000-8000-<n>`` in order of first
  appearance (client-supplied ids are kept);
- the generated VAPID public key becomes ``FIXED_PUBLIC_KEY``.

APNs is on, against a fake (``fake_apns``), so ``getPushConfig`` says ``apns_enabled: true``.

Every other ``*_at`` value in a response body is format-checked too.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the directory (removing
files no longer produced); otherwise the committed files must match.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime, tzinfo
from typing import Any, Self

import httpx
import pytest

from tests.fake_apns import FakeApns
from tests.helpers import backdate_schedule, make_topic, record
from tests.vectors import FIXTURES_DIR, check_or_write, dump_json, stale_message, updating

API_DIR = FIXTURES_DIR / "api"
PREFIX = "/api/v1"
SERVER_TIME = "2026-06-01T12:00:00.123456Z"
# Half a second, so frozen timestamps carry a fraction and captured_at values don't.
FROZEN_NOW = datetime(2026, 3, 4, 12, 0, 0, 500_000, tzinfo=UTC)
SCHEDULE_SET_AT = datetime(2026, 1, 1, tzinfo=UTC)
PINNED = frozenset({FROZEN_NOW, SCHEDULE_SET_AT})
DB_CLOCK_KEYS = frozenset(
    {"created_at", "updated_at", "schedule_updated_at", "archived_at", "deleted_at", "server_time"}
)
# Where topics, entries and versions sit in a response body ("*" = any list index).
RECORD_PATHS = frozenset(
    {
        ("body",),
        ("body", "items", "*"),
        ("body", "*"),
        # /changes: items wrap the record under its kind; deletions sit in "deleted".
        ("body", "items", "*", "topic"),
        ("body", "items", "*", "entry"),
        ("body", "items", "*", "version"),
        ("body", "deleted", "*"),
        # recordRunEvent: the run's entry.
        ("body", "entry"),
    }
)
FIXED_PUBLIC_KEY = "B" + "A" * 86
PUBLIC_KEY_RE = re.compile(r"B[A-Za-z0-9_-]{86}")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
DATETIME_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})")
# Free-form maps whose keys are user data, never response fields.
USER_DATA_KEYS = frozenset({"meta", "option_counts"})

PUSH_SUBSCRIPTION = {
    "endpoint": "https://web.push.apple.com/QGuQyavXutnMlB5k",
    "keys": {"p256dh": "BOr8uW3hZ8t3Qn0dJ4Xq-key", "auth": "x5sQe1Zl0dAuth"},
    "user_agent": "Mozilla/5.0 (iPhone)",
}
APNS_DEVICE = {
    "token": "7c5d0e1fa2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d",
    "environment": "sandbox",
    "bundle_id": "com.bahumia.quickr",
    "app_version": "1.0 (1)",
    "device_name": "iPhone",
}
# Operations without a fixture. Each one says why.
UNCOVERED_OPERATIONS = {
    "exportEntriesCsv": "text/csv, not JSON: the client saves the bytes and never decodes them",
}

ENTRY_IDS = [f"0f1e2d3c-4b5a-4968-8778-{n:012d}" for n in range(1, 6)]
E1, E2, E3, E4, E5 = ENTRY_IDS
# Client-generated run and event ids (kept as they are, like the entry ids).
RUN_IDS = [f"0a000000-0000-4000-8000-{n:012d}" for n in range(1, 6)]
R1, R2, R3, R4, R5 = RUN_IDS
EVENT_IDS = [f"0e000000-0000-4000-8000-{n:012d}" for n in range(1, 13)]
CLIENT_IDS = [*ENTRY_IDS, *RUN_IDS, *EVENT_IDS]

EVERYTHING: list[dict[str, Any]] = [
    {"key": "glasses", "label": "Glasses of water", "type": "int", "min": 0, "max": 30, "unit": "glasses"},
    {
        "key": "hours",
        "label": "Hours slept",
        "type": "double",
        "min": 0,
        "max": 24,
        "decimals": 1,
        "unit": "h",
        "help_text": "Time actually asleep.",
    },
    {
        "key": "mood",
        "label": "Mood",
        "type": "enum",
        "options": [
            {"value": "great", "label": "Great"},
            {"value": "ok", "label": "OK"},
            {"value": "poor", "label": "Poor"},
        ],
    },
    {
        "key": "factors",
        "label": "Factors",
        "type": "enum",
        "required": False,
        "multiple": True,
        "min_selected": 1,
        "max_selected": 2,
        "options": [
            {"value": "caffeine", "label": "Caffeine"},
            {"value": "screens", "label": "Screens"},
            {"value": "exercise", "label": "Exercise"},
        ],
    },
    {"key": "note", "label": "Note", "type": "str", "required": False, "max_length": 280, "multiline": True},
]


def everything_v2() -> list[dict[str, Any]]:
    """v2: the 'poor' mood option is retired."""
    qs = [dict(q) for q in EVERYTHING]
    qs[2] = {
        **qs[2],
        "options": [*qs[2]["options"][:2], {"value": "poor", "label": "Poor", "archived": True}],
    }
    return qs


class FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz: tzinfo | None = None) -> Self:
        return cls.fromtimestamp(FROZEN_NOW.timestamp(), tz)


def aware_datetime(value: object, where: str) -> datetime:
    """The parsed value; fails the test unless it is a timezone-aware ISO-8601 datetime."""
    assert isinstance(value, str), f"{where}: not a string: {value!r}"
    assert DATETIME_RE.fullmatch(value), f"{where}: not an aware ISO-8601 datetime: {value!r}"
    return datetime.fromisoformat(value)


class Recorder:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self.client = client
        self.files: dict[str, str] = {}
        self.uuids: dict[str, str] = {i: i for i in CLIENT_IDS}

    async def __call__(
        self,
        operation_id: str,
        method: str,
        path: str,
        body: Any = None,
        *,
        status: int,
        variant: str | None = None,
        params: dict[str, str] | None = None,
    ) -> Any:
        r = await self.client.request(method, path, json=body, params=params)
        assert r.status_code == status, f"{operation_id}: {r.status_code} {r.text}"
        data = r.json() if r.content else None
        name = operation_id + (f".{variant}" if variant else "") + ".json"
        assert name not in self.files, name
        query = "?" + str(httpx.QueryParams(params)) if params else ""
        record: dict[str, Any] = {
            "operation_id": operation_id,
            "request": {"method": method, "path": PREFIX + path + query, "body": body},
            "status": status,
            "body": data,
        }
        record["body"] = self.normalise(data, ("body",), name)
        self.files[name] = dump_json(self.uuids_in(record))
        return data

    def normalise(self, value: Any, path: tuple[str, ...], name: str) -> Any:
        """Check and normalise timestamps and the VAPID key in a response body."""
        if isinstance(value, list):
            return [self.normalise(v, (*path, "*"), name) for v in value]
        if not isinstance(value, dict) or (path and path[-1] in USER_DATA_KEYS):
            return value
        out: dict[str, Any] = {}
        for key, original in value.items():
            where = f"{name}: {'.'.join((*path, key))}"
            v = original
            if v is not None and (key.endswith("_at") or key in {"due_since", "start", "server_time"}):
                instant = aware_datetime(v, where)
                if path in RECORD_PATHS and key in DB_CLOCK_KEYS and instant not in PINNED:
                    v = SERVER_TIME
            elif path == ("body",) and key == "public_key":
                assert isinstance(v, str), where
                assert PUBLIC_KEY_RE.fullmatch(v), f"{where}: {v!r}"
                v = FIXED_PUBLIC_KEY
            out[key] = self.normalise(v, (*path, key), name)
        return out

    def uuids_in(self, value: Any) -> Any:
        if isinstance(value, dict):  # keys too: a run's effects are keyed by event id
            return {self.uuids_in(k): self.uuids_in(v) for k, v in value.items()}
        if isinstance(value, list):
            return [self.uuids_in(v) for v in value]
        if isinstance(value, str):
            return UUID_RE.sub(lambda m: self._uuid(m.group()), value)
        return value

    def _uuid(self, real: str) -> str:
        if real not in self.uuids:
            self.uuids[real] = f"00000000-0000-4000-8000-{len(self.uuids) - len(CLIENT_IDS) + 1:012d}"
        return self.uuids[real]


async def scenario(client: httpx.AsyncClient) -> dict[str, str]:
    rec = Recorder(client)

    # --- meta -----------------------------------------------------------------
    await rec("health", "GET", "/health", status=200)
    await rec("getLimits", "GET", "/limits", status=200)
    await rec("listQuestionTypes", "GET", "/question-types", status=200)

    # --- topics -----------------------------------------------------------------
    await rec(
        "createTopic",
        "POST",
        "/topics",
        {
            "name": "Everything",
            "description": "One of each question type.",
            "questions": EVERYTHING,
            "schedule": {"kind": "daily", "times": ["08:00", "21:30"], "timezone": "Europe/London"},
        },
        status=201,
    )
    await make_topic(
        client,
        "Water",
        [{"key": "glasses", "label": "Glasses", "type": "int", "min": 0, "max": 20}],
        schedule={"kind": "interval", "every_minutes": 180, "timezone": "Europe/London", "notify": False},
    )
    await make_topic(client, "Old habit", [{"key": "done", "label": "Done", "type": "int"}])
    for slug in ("everything", "water"):
        await backdate_schedule(slug, SCHEDULE_SET_AT)

    # --- entries (on v1, then v2) -----------------------------------------------------
    await rec(
        "createEntry",
        "POST",
        "/topics/everything/entries",
        {
            "id": E1,
            "answers": {
                "glasses": 6,
                "hours": 7.5,
                "mood": "great",
                "factors": ["caffeine", "exercise"],
                "note": "Slept well.",
            },
            "captured_at": "2026-03-01T08:05:00Z",
            "source": "ios",
            "meta": {"device": "iphone"},
        },
        status=201,
    )
    await rec(
        "createEntry",
        "POST",
        "/topics/everything/entries",
        {
            "id": E2,
            "answers": {"glasses": 3, "hours": 6, "mood": "poor"},
            "captured_at": "2026-03-02T07:55:00Z",
        },
        status=201,
        variant="minimal",
    )
    await rec(
        "publishTopicVersion",
        "POST",
        "/topics/everything/versions",
        {
            "questions": everything_v2(),
            "base_version": 1,
            "change_note": "Retire 'poor'",
            "timer": {"steps": [{"key": "pour", "label": "Pour"}, {"key": "drink", "label": "Drink"}]},
        },
        status=201,
    )
    await record(
        client,
        "everything",
        {"glasses": 8, "hours": 8.25, "mood": "ok", "factors": ["screens"]},
        id=E3,
        captured_at="2026-03-03T08:00:00+01:00",
        notes="Weekend.",
    )
    await record(client, "water", {"glasses": 2}, id=E4, captured_at="2026-03-03T09:00:00Z")
    await rec(
        "updateEntry",
        "PATCH",
        f"/entries/{E2}",
        {"notes": "Edited later.", "answers": {"note": "Restless night."}},
        status=200,
    )

    # --- topic lifecycle -------------------------------------------------------------
    await rec("updateTopic", "PATCH", "/topics/old-habit", {"description": "Retired."}, status=200)
    await rec("archiveTopic", "POST", "/topics/old-habit/archive", status=200)

    # --- reads ------------------------------------------------------------------
    await rec("listTopics", "GET", "/topics", status=200)
    await rec("listTopics", "GET", "/topics", status=200, variant="all", params={"status": "all"})
    await rec("getTopic", "GET", "/topics/everything", status=200)
    await rec("getTopic", "GET", "/topics/water", status=200, variant="interval")
    await rec("listTopicVersions", "GET", "/topics/everything/versions", status=200)
    await rec(
        "checkTopicVersion",
        "POST",
        "/topics/everything/versions/check",
        {"questions": everything_v2()[:3], "base_version": 2},
        status=200,
    )
    await rec("listEntries", "GET", "/topics/everything/entries", status=200)
    await rec("getEntry", "GET", f"/entries/{E1}", status=200)
    await rec("getTopicStats", "GET", "/topics/everything/stats", status=200)
    await rec(
        "getQuestionSeries",
        "GET",
        "/topics/everything/questions/hours/series",
        status=200,
        params={"bucket": "day", "tz": "Europe/London"},
    )
    await rec(
        "getQuestionSeries",
        "GET",
        "/topics/everything/questions/mood/series",
        status=200,
        variant="enum",
        params={"bucket": "week", "tz": "Europe/London"},
    )
    await rec("getPushConfig", "GET", "/push/config", status=200)

    # --- problems ---------------------------------------------------------------
    await rec(
        "createEntry",
        "POST",
        "/topics/everything/entries",
        {"answers": {"glasses": 99, "mood": "poor", "factors": ["caffeine", "screens", "exercise"]}},
        status=422,
        variant="invalid_answers",
    )
    await rec(
        "createEntry",
        "POST",
        "/topics/everything/entries",
        {"answers": {"glasses": 1}, "captured_at": "2026-03-01T08:00:00"},
        status=422,
        variant="invalid_request",
    )
    await rec("getTopic", "GET", "/topics/nope", status=404, variant="not_found")
    await rec(
        "publishTopicVersion",
        "POST",
        "/topics/everything/versions",
        {"questions": everything_v2(), "base_version": 1, "timer": None},
        status=409,
        variant="conflict",
    )
    await rec(
        "createEntry",
        "POST",
        "/topics/old-habit/entries",
        {"answers": {"done": 1}},
        status=409,
        variant="topic_archived",
    )
    await rec(
        "createEntry",
        "POST",
        "/topics/water/entries",
        {"id": E1, "answers": {"glasses": 1}},
        status=409,
        variant="id_conflict",
    )

    # --- deletes ----------------------------------------------------------------
    await record(client, "water", {"glasses": 1}, id=E5, captured_at="2026-03-04T07:00:00Z")
    await rec("listChanges", "GET", "/changes?after=0&limit=500", status=200, variant="bootstrap")
    await rec("deleteEntry", "DELETE", f"/entries/{E5}", status=204)
    # The tail of the feed after the delete: one entry deletion.
    page = (await client.get("/changes?after=0&limit=500")).json()
    await rec("listChanges", "GET", f"/changes?after={page['head'] - 1}", status=200, variant="deletion")
    await rec(
        "createEntry",
        "POST",
        "/topics/water/entries",
        {"id": E5, "answers": {"glasses": 1}, "captured_at": "2026-03-04T07:00:00Z"},
        status=409,
        variant="entry_deleted",
    )
    await rec("deleteTopic", "DELETE", "/topics/water", status=409, variant="not_archived")
    await rec("unarchiveTopic", "POST", "/topics/old-habit/unarchive", status=200)
    await client.post("/topics/old-habit/archive")
    await rec("deleteTopic", "DELETE", "/topics/old-habit", status=204)
    # One topic deletion; clients cascade it to the topic's versions and entries.
    page = (await client.get("/changes?after=0&limit=500")).json()
    await rec(
        "listChanges", "GET", f"/changes?after={page['head'] - 1}", status=200, variant="topic_deletion"
    )

    # --- push (delivery is mocked: every send succeeds) --------------------------------
    await rec("createPushSubscription", "POST", "/push/subscriptions", PUSH_SUBSCRIPTION, status=201)
    await rec("registerApnsDevice", "POST", "/push/apns/devices", APNS_DEVICE, status=201)
    await rec("sendTestPush", "POST", "/push/test", status=200)
    await rec(
        "sendApnsTestPush", "POST", "/push/apns/devices/test", {"token": APNS_DEVICE["token"]}, status=200
    )
    await rec(
        "deleteApnsDevice", "POST", "/push/apns/devices/delete", {"token": APNS_DEVICE["token"]}, status=204
    )
    await rec(
        "deletePushSubscription",
        "POST",
        "/push/subscriptions/delete",
        {"endpoint": PUSH_SUBSCRIPTION["endpoint"]},
        status=204,
    )
    await runs(client, rec)
    await live_activities(client, rec)
    return rec.files


async def live_activities(client: httpx.AsyncClient, rec: Recorder) -> None:
    """Live Activity tokens (timers.md §10.3): the push-to-start token, and one activity's."""
    everything = (await client.get("/topics/everything")).json()["id"]
    device = {"device_token": APNS_DEVICE["token"], "environment": "sandbox"}
    start = {"token": "5a" * 80, "kind": "start", **device}
    update = {"token": "6b" * 80, "kind": "update", "topic_id": everything, "run_id": RUN_IDS[0], **device}
    await rec(
        "registerLiveActivity", "POST", "/push/apns/live-activities", start, status=201, variant="start"
    )
    await rec("registerLiveActivity", "POST", "/push/apns/live-activities", update, status=201)
    await rec(
        "deleteLiveActivity",
        "POST",
        "/push/apns/live-activities/delete",
        {"token": update["token"]},
        status=204,
    )


def run_event(event_id: str, kind: str, at: str, **fields: Any) -> dict[str, Any]:
    return {"id": event_id, "type": kind, "at": at, **fields}


async def runs(client: httpx.AsyncClient, rec: Recorder) -> None:
    """Runs (docs/specs/timers.md §3): 'everything' is timed from v2 and has required questions,
    so its runs finish; 'dishwasher' has neither steps nor questions, so its stop makes the entry."""
    ev1, ev2, ev3, ev4, ev5, ev6, ev7, ev8, ev9, ev10, ev11, ev12 = EVENT_IDS
    everything = (await client.get("/topics/everything")).json()["id"]
    dishwasher = (
        await client.post("/topics", json={"name": "Dishwasher", "questions": [], "timer": {"steps": []}})
    ).json()["id"]

    def start(run_id: str, topic_id: str, at: str) -> dict[str, Any]:
        return run_event(run_id, "start", at, topic_id=topic_id, version=2 if topic_id == everything else 1)

    def post(run_id: str) -> str:
        return f"/runs/{run_id}/events"

    runs_from = (await client.get("/changes?after=0&limit=500")).json()["head"]
    await rec("recordRunEvent", "POST", post(R1), start(R1, everything, "2026-03-04T11:00:00Z"), status=201)
    # A second device's start for the same topic: merged into R1, whose start time is kept.
    await rec(
        "recordRunEvent",
        "POST",
        post(R2),
        {**start(R2, everything, "2026-03-04T10:59:58.250Z"), "source": "widget"},
        status=201,
        variant="merged",
    )
    await rec(
        "recordRunEvent",
        "POST",
        post(R1),
        run_event(ev1, "next", "2026-03-04T11:02:30.125Z", seg=0),
        status=200,
        variant="next",
    )
    # The other device's Next for the same segment, sent to its alias: one advance, this one stale.
    await rec(
        "recordRunEvent",
        "POST",
        post(R2),
        run_event(ev2, "next", "2026-03-04T11:02:31Z", seg=0),
        status=200,
        variant="void",
    )
    await client.post(post(R1), json=run_event(ev3, "pause", "2026-03-04T11:03:00Z"))
    await client.post(post(R1), json=run_event(ev4, "resume", "2026-03-04T11:04:00Z", pause_id=ev3))
    await client.post(post(R1), json=run_event(ev5, "skip", "2026-03-04T11:05:00Z", seg=1, step="drink"))
    await rec(
        "recordRunEvent",
        "POST",
        post(R1),
        run_event(ev6, "stop", "2026-03-04T11:06:00Z", meta={"device": "iphone"}),
        status=200,
        variant="finishing",
    )
    # The feed since the first start: one run item, finishing (timers.md §7.1).
    await rec("listChanges", "GET", f"/changes?after={runs_from}", status=200, variant="run")
    await rec("getRun", "GET", f"/runs/{R2}", status=200)  # an alias resolves
    await rec("listRuns", "GET", "/runs", status=200, params={"status": "finishing"})
    await rec(
        "recordRunEvent",
        "POST",
        post(R1),
        run_event(ev7, "finish", "2026-03-04T11:07:00Z", answers={"glasses": 2, "hours": 7, "mood": "ok"}),
        status=200,
        variant="finish",
    )
    await rec(
        "recordRunEvent",
        "POST",
        post(R1),
        run_event(ev8, "finish", "2026-03-04T11:08:00Z", answers={"note": "Later."}, notes="Added later."),
        status=200,
        variant="finish_stopped",
    )
    # Editing the stopped run's times on its entry (§3.8): drink was skipped, now it is timed.
    await rec(
        "updateEntry",
        "PATCH",
        f"/entries/{R1}",
        {
            "expected_revision": 2,
            "timing": {
                "started_at": "2026-03-04T11:00:00Z",
                "segments": [
                    {"kind": "step", "step": "pour", "ended_at": "2026-03-04T11:02:00Z"},
                    {"kind": "step", "step": "drink", "ended_at": "2026-03-04T11:05:30Z"},
                ],
                "skipped": [],
                "pauses": [{"start": "2026-03-04T11:03:00Z", "end": "2026-03-04T11:03:30Z"}],
            },
        },
        status=200,
        variant="timing",
    )

    # R1's entry: a run of 'everything' v2 with a skipped step and a pause.
    await rec("getTopicTiming", "GET", "/topics/everything/timing", status=200)
    await rec("getTopicTiming", "GET", "/topics/water/timing", status=200, variant="untimed")

    await client.post(post(R3), json=start(R3, dishwasher, "2026-03-04T11:10:00Z"))
    await rec(
        "recordRunEvent",
        "POST",
        post(R3),
        run_event(ev9, "stop", "2026-03-04T11:14:05.5Z"),
        status=200,
        variant="stop",
    )

    await client.post(post(R4), json=start(R4, everything, "2026-03-04T11:20:00Z"))
    await client.post(post(R4), json=run_event(ev10, "stop", "2026-03-04T11:21:00Z"))
    await rec(
        "recordRunEvent",
        "POST",
        post(R4),
        run_event(ev11, "discard", "2026-03-04T11:22:00Z"),
        status=200,
        variant="discard_finishing",
    )
    # The same span once every run has closed: their entries, and one run deletion each.
    await rec("listChanges", "GET", f"/changes?after={runs_from}", status=200, variant="run_deletion")

    # --- problems ---
    await rec(
        "recordRunEvent",
        "POST",
        post(R5),
        run_event(
            R5,
            "start",
            "2026-03-04T11:30:00Z",
            topic_id=(await client.get("/topics/water")).json()["id"],
            version=1,
        ),
        status=409,
        variant="topic_not_timed",
    )
    await rec(
        "recordRunEvent",
        "POST",
        post(E1),
        start(E1, dishwasher, "2026-03-04T11:30:00Z"),
        status=409,
        variant="id_conflict",
    )
    await rec(
        "recordRunEvent",
        "POST",
        post(R1),
        run_event(ev1, "next", "2026-03-04T11:02:31Z", seg=0),
        status=409,
        variant="event_conflict",
    )
    await client.post(post(R5), json=start(R5, dishwasher, "2026-03-04T11:40:00Z"))
    await rec(
        "recordRunEvent",
        "POST",
        post(R5),
        run_event(ev12, "stop", "2026-03-04T11:39:59Z"),
        status=422,
        variant="before_start",
    )
    await rec(
        "createEntry",
        "POST",
        f"/topics/{dishwasher}/entries",
        {"id": R5, "answers": {}, "captured_at": "2026-03-04T11:41:00Z"},
        status=409,
        variant="run_id_conflict",
    )
    await client.post(f"/topics/{dishwasher}/archive")
    await client.delete(f"/topics/{dishwasher}")
    await rec(
        "recordRunEvent",
        "POST",
        post(R5),
        run_event(ev12, "stop", "2026-03-04T11:42:00Z"),
        status=409,
        variant="run_deleted",
    )


async def test_api_fixtures_match_committed(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, fake_apns: FakeApns
) -> None:
    # Only the topic service still reads the Python clock (due computation); entry and
    # topic timestamps come from the database's now() and are normalised instead.
    monkeypatch.setattr("app.services.topics.datetime", FrozenDatetime)
    # Runs: the start-age bound and the `at` bounds.
    monkeypatch.setattr("app.services.runs.now", lambda: FROZEN_NOW)
    monkeypatch.setattr("app.schemas.api.datetime", FrozenDatetime)
    monkeypatch.setattr("app.services.push.web.deliver", lambda *_: None)
    files = await scenario(client)
    existing = {p.name for p in API_DIR.glob("*.json")}
    if updating():
        for name in existing - files.keys():
            (API_DIR / name).unlink()
    else:
        assert existing == set(files), stale_message(API_DIR)
    for name, content in files.items():
        check_or_write(API_DIR / name, content)


def test_every_operation_has_a_fixture() -> None:
    from app.main import app

    operations = {op["operationId"] for item in app.openapi()["paths"].values() for op in item.values()}
    covered = {p.name.split(".")[0] for p in API_DIR.glob("*.json")}
    assert operations - covered == set(UNCOVERED_OPERATIONS), "add a rec(...) to scenario()"
    assert set(UNCOVERED_OPERATIONS) <= operations, "a stale exclusion"


@pytest.mark.parametrize("bad", ["2026-03-01T08:00:00", "2026-03-01", "soon", 1767225600])
def test_normaliser_rejects_non_aware_timestamps(bad: object) -> None:
    rec = Recorder(httpx.AsyncClient())
    with pytest.raises(AssertionError, match="created_at"):
        rec.normalise({"created_at": bad}, ("body",), "x.json")


def test_normaliser_only_touches_known_paths() -> None:
    rec = Recorder(httpx.AsyncClient())
    db_time = "2026-10-17T14:38:26.420960Z"
    body = {
        "created_at": db_time,
        "schedule_updated_at": "2026-01-01T00:00:00Z",  # pinned: kept
        "meta": {"created_at": "not a date"},
        "answers": [{"key": "k", "value": db_time}],
        "due": {"due_since": "2026-03-04T08:00:00Z", "next_due_at": None},
    }
    assert rec.normalise(body, ("body",), "x.json") == {
        **body,
        "created_at": SERVER_TIME,
    }
