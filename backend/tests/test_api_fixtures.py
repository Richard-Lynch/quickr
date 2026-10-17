"""API response fixtures for the Swift client: ``shared/fixtures/api/*.json``.

One scenario drives the real app (ASGI client, test database) through every
response shape the iOS client decodes, and each recorded call becomes one file:
``{operation_id, request: {method, path, body}, status, body}``, named
``<operationId>[.<variant>].json``. Adding an endpoint is one ``rec(...)`` line.

Volatile values are normalised so the output is stable: server-generated UUIDs
become ``00000000-0000-4000-8000-<n>`` in order of first appearance (client-
supplied ids are kept), server clock timestamps (``SERVER_TIME_KEYS``) become
``SERVER_TIME`` and the generated VAPID key a fixed one. Entries carry explicit
``captured_at`` values and schedules are backdated, so due state is fixed too.

``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the directory (removing
files no longer produced); otherwise the committed files must match.
"""

from __future__ import annotations

import re
from datetime import UTC, datetime
from typing import Any

import httpx

from tests.helpers import backdate_schedule, make_topic, record
from tests.vectors import FIXTURES_DIR, check_or_write, dump_json, stale_message, updating

API_DIR = FIXTURES_DIR / "api"
PREFIX = "/api/v1"
SERVER_TIME = "2026-06-01T12:00:00.123456Z"
SERVER_TIME_KEYS = frozenset(
    {"created_at", "updated_at", "archived_at", "schedule_updated_at", "due_since", "next_due_at"}
)
FIXED_VALUES = {"public_key": "B" + "A" * 86}
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SCHEDULE_SET_AT = datetime(2026, 1, 1, tzinfo=UTC)

ENTRY_IDS = [f"0f1e2d3c-4b5a-4968-8778-{n:012d}" for n in range(1, 6)]
E1, E2, E3, E4, E5 = ENTRY_IDS

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


class Recorder:
    def __init__(self, client: httpx.AsyncClient) -> None:
        self.client = client
        self.files: dict[str, str] = {}
        self.uuids: dict[str, str] = {i: i for i in ENTRY_IDS}

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
        record = {
            "operation_id": operation_id,
            "request": {"method": method, "path": PREFIX + path + query, "body": body},
            "status": status,
            "body": data,
        }
        self.files[name] = dump_json(self.normalise(record))
        return data

    def normalise(self, value: Any, key: str | None = None) -> Any:
        if isinstance(value, dict):
            return {k: self.normalise(value[k], k) for k in sorted(value)}
        if isinstance(value, list):
            return [self.normalise(v) for v in value]
        if isinstance(value, str):
            if key in SERVER_TIME_KEYS:
                return SERVER_TIME
            if key in FIXED_VALUES:
                return FIXED_VALUES[key]
            return UUID_RE.sub(lambda m: self._uuid(m.group()), value)
        return value

    def _uuid(self, real: str) -> str:
        if real not in self.uuids:
            self.uuids[real] = f"00000000-0000-4000-8000-{len(self.uuids) - len(ENTRY_IDS) + 1:012d}"
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
        {"questions": everything_v2(), "base_version": 1, "change_note": "Retire 'poor'"},
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
        {"questions": everything_v2(), "base_version": 1},
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
    await record(client, "water", {"glasses": 1}, id=E5)
    await rec("deleteEntry", "DELETE", f"/entries/{E5}", status=204)
    return rec.files


async def test_api_fixtures_match_committed(client: httpx.AsyncClient) -> None:
    files = await scenario(client)
    existing = {p.name for p in API_DIR.glob("*.json")}
    if updating():
        for name in existing - files.keys():
            (API_DIR / name).unlink()
    else:
        assert existing == set(files), stale_message(API_DIR)
    for name, content in files.items():
        check_or_write(API_DIR / name, content)
