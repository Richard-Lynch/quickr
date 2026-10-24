"""Runs over the API: ``recordRunEvent``, ``getRun`` and ``listRuns`` (docs/specs/timers.md §3 to §6).

Spec cases T1 to T6, T9, T13, T15 and T16 (§13.2); T17 (the server-time header) is in
``test_identity.py``. The server clock is frozen at ``NOW`` (the start-age bound and the
``at`` bounds both read it).
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any, Self
from uuid import UUID, uuid4

import httpx
import pytest
from sqlalchemy import func, select, text, update

from app.db import get_sessionmaker
from app.models import ChangeLog, Channel, DeletedId, FeedKind, Run, RunEvent
from app.schemas.api import RunEventIn
from app.services import run_fold
from app.services import runs as run_svc
from app.services.feed import FEED_LOCK_ID
from tests.helpers import feed_locks, make_topic
from tests.vectors import FIXTURES_DIR

NOW = datetime(2026, 10, 23, 12, 0, tzinfo=UTC)
T0 = datetime(2026, 10, 23, 8, 0, tzinfo=UTC)
STEPS = [{"key": "shower", "label": "Shower"}, {"key": "breakfast", "label": "Breakfast"}]
REQUIRED = [{"key": "mood", "label": "Mood", "type": "int", "min": 0, "max": 10}]
OPTIONAL = [{"key": "note", "label": "Note", "type": "str", "required": False}]
VECTORS = json.loads((FIXTURES_DIR / "run-fold-vectors.json").read_text())


def frozen_clock(monkeypatch: pytest.MonkeyPatch, at: datetime) -> None:
    class Frozen(datetime):
        @classmethod
        def now(cls, tz: Any = None) -> Self:
            return cls.fromtimestamp(at.timestamp(), tz)

    monkeypatch.setattr(run_svc, "now", lambda: at)
    monkeypatch.setattr("app.schemas.api.datetime", Frozen)  # the `at` bounds (check_captured_at)


@pytest.fixture(autouse=True)
def _clock(monkeypatch: pytest.MonkeyPatch) -> None:
    frozen_clock(monkeypatch, NOW)


def at(seconds: float) -> str:
    return (T0 + timedelta(seconds=seconds)).isoformat()


async def timed(
    client: httpx.AsyncClient, name: str = "Routine", steps: list[dict[str, str]] | None = None, **extra: Any
) -> dict[str, Any]:
    """A timed topic; no questions unless given (``make_topic`` would add its own)."""
    body = {"name": name, "questions": [], "timer": {"steps": steps or []}, **extra}
    r = await client.post("/topics", json=body)
    assert r.status_code == 201, r.text
    topic: dict[str, Any] = r.json()
    return topic


class Driver:
    """One run driven over the API."""

    def __init__(self, client: httpx.AsyncClient, topic: dict[str, Any], run_id: str | None = None) -> None:
        self.client = client
        self.topic = topic
        self.id = run_id or str(uuid4())

    async def post(self, body: dict[str, Any], *, path_id: str | None = None, status: int = 200) -> Any:
        r = await self.client.post(f"/runs/{path_id or self.id}/events", json=body)
        assert r.status_code == status, r.text
        return r.json()

    async def start(self, seconds: float = 0, *, status: int = 201, **extra: Any) -> Any:
        body = {
            "id": self.id,
            "type": "start",
            "at": at(seconds),
            "topic_id": self.topic["id"],
            "version": self.topic["current_version"],
            **extra,
        }
        return await self.post(body, status=status)

    async def tap(self, kind: str, seconds: float, *, status: int = 200, **fields: Any) -> Any:
        body = {"id": fields.pop("id", None) or str(uuid4()), "type": kind, "at": at(seconds), **fields}
        return await self.post(body, path_id=fields.pop("path_id", None), status=status)

    async def get(self) -> Any:
        r = await self.client.get(f"/runs/{self.id}")
        assert r.status_code == 200, r.text
        return r.json()


async def log_rows(after: int = 0) -> list[tuple[str, str, str]]:
    async with get_sessionmaker()() as db:
        rows = await db.execute(
            select(ChangeLog.kind, ChangeLog.op, ChangeLog.entity_id)
            .where(ChangeLog.seq > after)
            .order_by(ChangeLog.seq)
        )
        return [(k.value, o.value, str(i)) for k, o, i in rows]


async def head() -> int:
    async with get_sessionmaker()() as db:
        return int(await db.scalar(select(func.coalesce(func.max(ChangeLog.seq), 0))) or 0)


async def tombstoned(kind: FeedKind) -> set[str]:
    async with get_sessionmaker()() as db:
        return {
            str(i) for i in (await db.execute(select(DeletedId.id).where(DeletedId.kind == kind))).scalars()
        }


async def event_count() -> int:
    async with get_sessionmaker()() as db:
        return int(await db.scalar(select(func.count()).select_from(RunEvent)) or 0)


# --- T1: every fold vector through the endpoint ---------------------------------------------


@pytest.mark.parametrize("case", VECTORS["cases"], ids=lambda c: c["name"])
async def test_fold_vectors_through_the_endpoint(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, case: dict[str, Any]
) -> None:
    events = case["events"]
    start = run_fold.from_ms(run_fold.parse_instant(events[0]["at"]))
    # Late enough for every event (at most 24h ahead), early enough for the start (7 days old).
    frozen_clock(monkeypatch, start + timedelta(days=7) - timedelta(hours=1))
    topic = await timed(client, steps=VECTORS["step_sets"][case["steps"]])
    run_id = VECTORS["meta"]["run_id"]
    expected = case["expected"]
    effects = expected["state"]["effects"]
    frozen = case["frozen"]
    refused: set[str] = set()
    for i, e in enumerate(events):
        if frozen is not None and i == frozen["after"]:
            await _freeze(client, run_id, frozen["reason"])
        body = {k: e[k] for k in ("id", "type", "at", "seg", "step", "pause_id")}
        if e["type"] == "start":
            body |= {"topic_id": topic["id"], "version": 1}
        r = await client.post(f"/runs/{e['id'] if e['type'] == 'start' else run_id}/events", json=body)
        if r.status_code == 422:
            # The server refuses a stop the fold would void as out of range (§3.5, §5).
            code = r.json()["code"]
            assert (e["type"], code) in {("stop", "before_start"), ("stop", "run_too_long")}, r.text
            assert effects[e["id"].lower()] == {
                "effect": "void",
                "reason": {"before_start": "before_start", "run_too_long": "too_long"}[code],
            }
            refused.add(e["id"].lower())
        else:
            assert r.status_code in (200, 201), r.text

    run = (await client.get(f"/runs/{run_id}")).json()
    state = run["state"]
    finishes = {e["id"].lower() for e in events if e["type"] == "finish"}  # the server decides them
    assert {k: v for k, v in state["effects"].items() if k not in finishes} == {
        k: v for k, v in effects.items() if k not in refused
    }
    assert {k: v for k, v in state.items() if k != "effects"} == {
        k: v for k, v in expected["state"].items() if k != "effects"
    }
    assert [e["effect"] for e in run["events"]] == [
        state["effects"][e["id"]]["effect"] for e in run["events"]
    ]
    entry = await client.get(f"/entries/{run_id}")
    if expected["timing"] is not None and frozen is None:
        assert entry.status_code == 200
        assert entry.json()["timing"] == expected["timing"]
        assert entry.json()["captured_at"] == expected["timing"]["ended_at"]


async def _freeze(client: httpx.AsyncClient, run_id: str, reason: str) -> None:
    """What makes the fold's ``frozen`` cut-off happen on the server."""
    if reason == "run_edited":  # T-EDIT's PATCH sets this flag; here it is set directly
        async with get_sessionmaker()() as db:
            await db.execute(update(Run).where(Run.id == UUID(run_id)).values(edited=True))
            await db.commit()
    elif reason == "entry_deleted":
        assert (await client.delete(f"/entries/{run_id}")).status_code == 204
    else:
        assert reason == "already_closed"
        assert (await client.get(f"/runs/{run_id}")).json()["status"] == "discarded"


# --- start (§3.3) -------------------------------------------------------------------------------


async def test_start_creates_a_running_run(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run = Driver(client, topic)
    before = await head()
    result = await run.start(source="iphone")
    assert result["event"] == {"id": run.id, "effect": "applied", "reason": None}
    assert result["entry"] is None
    out = result["run"]
    assert (out["id"], out["status"], out["revision"], out["version"]) == (run.id, "running", 1, 1)
    assert out["started_at"] == "2026-10-23T08:00:00Z"
    assert out["state"]["open"] == {
        "index": 0,
        "kind": "step",
        "step": "shower",
        "label": "Shower",
        "started_at": "2026-10-23T08:00:00Z",
    }
    assert out["state"]["next_step"] == "breakfast"
    assert out["events"] == [
        {
            "id": run.id,
            "type": "start",
            "at": "2026-10-23T08:00:00Z",
            "seg": None,
            "step": None,
            "pause_id": None,
            "arrival": out["events"][0]["arrival"],
            "effect": "applied",
            "reason": None,
            "source": "iphone",
        }
    ]
    assert await log_rows(before) == [("run", "upsert", run.id)]
    assert await run.get() == out


@pytest.mark.parametrize(
    ("setup", "status", "code"),
    [
        ("untimed", 409, "topic_not_timed"),
        ("no_version", 409, "topic_not_timed"),
        ("archived", 409, "topic_archived"),
        ("unknown_topic", 404, "not_found"),
        ("too_old", 422, "invalid_request"),
        ("id_mismatch", 422, "invalid_request"),
        ("no_topic_id", 422, "invalid_request"),
    ],
)
async def test_start_refusals(client: httpx.AsyncClient, setup: str, status: int, code: str) -> None:
    topic = await timed(client)
    body = {"id": str(uuid4()), "type": "start", "at": at(0), "topic_id": topic["id"], "version": 1}
    path = body["id"]
    match setup:
        case "untimed":
            body["topic_id"] = (await make_topic(client, "Plain", []))["id"]
        case "no_version":
            body["version"] = 2
        case "archived":
            await client.post(f"/topics/{topic['id']}/archive")
        case "unknown_topic":
            body["topic_id"] = str(uuid4())
        case "too_old":
            body["at"] = (NOW - timedelta(days=7, seconds=1)).isoformat()
        case "id_mismatch":
            path = str(uuid4())
        case "no_topic_id":
            del body["topic_id"]
    r = await client.post(f"/runs/{path}/events", json=body)
    assert (r.status_code, r.json()["code"]) == (status, code), r.text
    assert await event_count() == 0


async def test_untimed_version_after_publish(client: httpx.AsyncClient) -> None:
    """Timing switched off by a publish: a start on the new version is refused, one on the old
    version (still timed) is not, and that run stops against its own version (T11's tail)."""
    topic = await timed(client, steps=STEPS)
    r = await client.post(
        f"/topics/{topic['id']}/versions", json={"questions": [], "base_version": 1, "timer": None}
    )
    assert r.status_code == 201, r.text
    run = Driver(client, {**topic, "current_version": 2})
    r = await client.post(
        f"/runs/{run.id}/events",
        json={"id": run.id, "type": "start", "at": at(0), "topic_id": topic["id"], "version": 2},
    )
    assert r.json()["code"] == "topic_not_timed"
    old = Driver(client, topic)
    await old.start()
    result = await old.tap("stop", 60)
    assert result["entry"]["version"] == 1
    assert result["entry"]["timing"]["segments"][0]["label"] == "Shower"


# --- T3: two starts for one topic (§4.5) --------------------------------------------------------


async def test_concurrent_starts_merge(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    a, b = Driver(client, topic), Driver(client, topic)
    results = await _racing(
        lambda: client.post(f"/runs/{a.id}/events", json=_start_body(a, 0)),
        lambda: client.post(f"/runs/{b.id}/events", json=_start_body(b, -30)),
    )
    assert [r.status_code for r in results] == [201, 201]
    bodies = [r.json() for r in results]
    winner = bodies[0]["run"]["id"]
    loser = b.id if winner == a.id else a.id
    assert {body["run"]["id"] for body in bodies} == {winner}
    merged = next(body for body in bodies if body["event"]["id"] == loser)
    assert merged["event"] == {"id": loser, "effect": "void", "reason": "merged"}
    run = merged["run"]
    assert run["aliases"] == [loser]
    # The first run's start time is kept, even though the merged start is earlier.
    assert run["started_at"] == (at(0) if winner == a.id else at(-30)).replace("+00:00", "Z")

    # Later events to the alias apply to the run; getRun of the alias returns it; a replayed
    # start of the alias is a replay.
    via_alias = Driver(client, topic, loser)
    result = await via_alias.tap("next", 60, seg=0)
    assert (result["run"]["id"], result["event"]["effect"]) == (winner, "applied")
    assert (await via_alias.get())["id"] == winner
    replay = await client.post(
        f"/runs/{loser}/events", json=_start_body(via_alias, 0 if loser == a.id else -30)
    )
    assert replay.status_code == 200
    assert replay.json()["event"] == {"id": loser, "effect": "void", "reason": "merged"}
    async with get_sessionmaker()() as db:
        assert await db.scalar(select(func.count()).select_from(Run)) == 1


def _start_body(run: Driver, seconds: float) -> dict[str, Any]:
    return {"id": run.id, "type": "start", "at": at(seconds), "topic_id": run.topic["id"], "version": 1}


async def _racing(*requests: Callable[[], Any]) -> list[httpx.Response]:
    """Send the requests while the feed lock is held, so they all wait on it at once (T2, T3)."""
    async with get_sessionmaker()() as holder, get_sessionmaker()() as probe:
        await holder.execute(text("SELECT pg_advisory_xact_lock(:id)"), {"id": FEED_LOCK_ID})
        tasks = [asyncio.create_task(send()) for send in requests]
        async with asyncio.timeout(5):
            while await feed_locks(probe, granted=False) < len(tasks):
                await probe.rollback()
                await asyncio.sleep(0.01)
        await holder.commit()  # releases the lock: the writers go one at a time
        return list(await asyncio.gather(*tasks))


# --- T2: two devices tap Next on the same segment -----------------------------------------------


async def test_concurrent_next_same_segment(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run = Driver(client, topic)
    await run.start()

    def next_at(seconds: int) -> Callable[[], Any]:
        body = {"id": str(uuid4()), "type": "next", "at": at(seconds), "seg": 0}
        return lambda: client.post(f"/runs/{run.id}/events", json=body)

    results = await _racing(next_at(60), next_at(61))
    assert [r.status_code for r in results] == [200, 200]
    effects = sorted((r.json()["event"]["effect"], r.json()["event"]["reason"]) for r in results)
    assert effects == [("applied", None), ("void", "stale")]
    state = (await run.get())["state"]
    assert state["open"]["index"] == 1  # one advance
    assert [s["step"] for s in state["segments"]] == ["shower"]
    assert state["segments"][0]["ended_at"] == "2026-10-23T08:01:00Z"  # the earlier tap by time


# --- T4: idempotency and truncation ---------------------------------------------------------


async def test_replays_and_event_conflicts(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run = Driver(client, topic)
    first = await run.start()
    assert (await run.start(status=200))["run"] == first["run"]  # a replayed start: 200, no change

    nxt = {"id": str(uuid4()), "type": "next", "at": at(60.000_999), "seg": 0}
    applied = await run.post(nxt)
    before = await event_count()
    assert await run.post(nxt) == applied
    # Same instant after truncation to milliseconds: still a replay.
    assert await run.post({**nxt, "at": at(60.000_5)}) == applied
    assert await event_count() == before
    stored = applied["run"]["events"][-1]["at"]
    assert stored == "2026-10-23T08:01:00Z"  # 60.000999 s truncated to the millisecond

    for change in ({"at": at(61)}, {"seg": 1}, {"type": "lap"}):
        r = await client.post(f"/runs/{run.id}/events", json={**nxt, **change})
        assert (r.status_code, r.json()["code"]) == (409, "event_conflict"), change
    other_topic = {**_start_body(run, 0), "topic_id": (await timed(client, "Other"))["id"]}
    r = await client.post(f"/runs/{run.id}/events", json=other_topic)
    assert (r.status_code, r.json()["code"]) == (409, "event_conflict")
    # An event id already used on another run is a conflict too.
    other = Driver(client, await timed(client, "Third"))
    await other.start()
    r = await client.post(f"/runs/{other.id}/events", json=nxt)
    assert (r.status_code, r.json()["code"]) == (409, "event_conflict")
    # So is a start whose run id is already an event's id.
    reused = Driver(client, await timed(client, "Fourth"), str(nxt["id"]))
    r = await client.post(f"/runs/{reused.id}/events", json=_start_body(reused, 0))
    assert (r.status_code, r.json()["code"]) == (409, "event_conflict")
    assert await event_count() == before + 1


async def test_sub_millisecond_instants_are_truncated(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client))
    await run.start(0.000_999)
    result = await run.tap("stop", 1.234_567_8)
    timing = result["entry"]["timing"]
    assert (timing["started_at"], timing["ended_at"], timing["active_ms"]) == (
        "2026-10-23T08:00:00Z",
        "2026-10-23T08:00:01.234000Z",
        1234,
    )
    assert result["entry"]["captured_at"] == timing["ended_at"]  # T1 of §2.3


@pytest.mark.parametrize(
    ("kind", "fields", "loc"),
    [
        ("next", {}, ["body", "seg"]),
        ("lap", {}, ["body", "seg"]),
        ("skip", {"seg": 0}, ["body", "step"]),
        ("resume", {}, ["body", "pause_id"]),
        ("next", {"seg": 0, "answers": {}}, ["body", "answers"]),
        ("pause", {"notes": "x"}, ["body", "notes"]),
        ("next", {"seg": -1}, ["body", "seg"]),
    ],
)
async def test_event_fields_per_type(
    client: httpx.AsyncClient, kind: str, fields: dict[str, Any], loc: list[str]
) -> None:
    run = Driver(client, await timed(client))
    await run.start()
    r = await client.post(
        f"/runs/{run.id}/events", json={"id": str(uuid4()), "type": kind, "at": at(1), **fields}
    )
    assert r.status_code == 422
    assert r.json()["code"] == "invalid_request"
    assert r.json()["errors"][0]["loc"] == loc


@pytest.mark.parametrize("when", [datetime(1999, 12, 31, tzinfo=UTC), NOW + timedelta(hours=24, seconds=1)])
async def test_at_bounds(client: httpx.AsyncClient, when: datetime) -> None:
    run = Driver(client, await timed(client))
    await run.start()
    r = await client.post(
        f"/runs/{run.id}/events", json={"id": str(uuid4()), "type": "pause", "at": when.isoformat()}
    )
    assert (r.status_code, r.json()["errors"][0]["loc"]) == (422, ["body", "at"])


async def test_unknown_run(client: httpx.AsyncClient) -> None:
    r = await client.post(f"/runs/{uuid4()}/events", json={"id": str(uuid4()), "type": "pause", "at": at(1)})
    assert (r.status_code, r.json()["code"]) == (404, "not_found")
    assert (await client.get(f"/runs/{uuid4()}")).status_code == 404


async def test_too_many_events(client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(run_svc, "MAX_RUN_EVENTS", 3)
    topic = await timed(client)
    run = Driver(client, topic)
    await run.start()
    await run.tap("pause", 1)
    await run.tap("pause", 2)  # void (already_paused): it still counts
    r = await client.post(
        f"/runs/{run.id}/events", json={"id": str(uuid4()), "type": "lap", "at": at(3), "seg": 0}
    )
    assert (r.status_code, r.json()["code"]) == (422, "run_too_many_events")
    late = Driver(client, topic)  # a merged start counts against the open run too
    r = await client.post(f"/runs/{late.id}/events", json=_start_body(late, 5))
    assert (r.status_code, r.json()["code"]) == (422, "run_too_many_events")
    assert await event_count() == 3


# --- T5: stop, finishing, finish -------------------------------------------------------------


async def test_stop_without_required_questions_makes_the_entry(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS, questions=OPTIONAL)
    run = Driver(client, topic)
    await run.start(source="widget")
    await run.tap("next", 60, seg=0)
    before = await head()
    result = await run.tap("stop", 100, meta={"via": "live-activity"}, notes="quick")
    assert result["run"]["status"] == "stopped"
    assert result["run"]["ended_at"] == "2026-10-23T08:01:40Z"
    entry = result["entry"]
    assert (entry["id"], entry["version"], entry["source"], entry["channel"]) == (run.id, 1, "widget", "api")
    assert (entry["answers"], entry["notes"], entry["meta"]) == ([], "quick", {"via": "live-activity"})
    assert entry["captured_at"] == "2026-10-23T08:01:40Z"
    assert [(s["step"], s["active_ms"]) for s in entry["timing"]["segments"]] == [
        ("shower", 60_000),
        ("breakfast", 40_000),
    ]
    assert entry["timing"]["complete"] is True
    # The entry's upsert, then the run's delete, in the same transaction (§2.4).
    assert await log_rows(before) == [("entry", "upsert", run.id), ("run", "delete", run.id)]
    assert run.id in await tombstoned(FeedKind.run)


async def test_stop_with_required_questions_leaves_the_run_finishing(client: httpx.AsyncClient) -> None:
    topic = await timed(client, questions=REQUIRED)
    run = Driver(client, topic)
    await run.start()
    before = await head()
    result = await run.tap("stop", 30)
    assert (result["run"]["status"], result["run"]["state"]["status"], result["entry"]) == (
        "finishing",
        "finishing",
        None,
    )
    assert result["event"]["effect"] == "applied"
    assert await log_rows(before) == [("run", "upsert", run.id)]
    assert (await client.get(f"/entries/{run.id}")).status_code == 404

    # A finish with bad answers: 422 and nothing stored.
    events = await event_count()
    bad = await run.tap("finish", 40, status=422, answers={"mood": 99})
    assert bad["code"] == "invalid_answers"
    missing = await run.tap("finish", 40, status=422, answers={})
    assert missing["errors"] == [{"loc": ["answers", "mood"], "message": "required"}]
    assert await event_count() == events
    assert (await run.get())["status"] == "finishing"

    result = await run.tap("finish", 40, answers={"mood": 7}, notes="done")
    assert result["event"]["effect"] == "applied"
    assert result["run"]["status"] == "stopped"
    entry = result["entry"]
    assert (entry["answers"], entry["notes"], entry["captured_at"]) == (
        [{"key": "mood", "type": "int", "value": 7}],
        "done",
        "2026-10-23T08:00:30Z",
    )
    assert await log_rows(before + 1) == [("entry", "upsert", run.id), ("run", "delete", run.id)]


async def test_stop_with_answers_is_validated_first(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    assert (await run.tap("stop", 30, status=422, answers={"mood": "x"}))["code"] == "invalid_answers"
    assert (await run.get())["status"] == "running"
    result = await run.tap("stop", 30, answers={"mood": 3})
    assert result["entry"]["answers"] == [{"key": "mood", "type": "int", "value": 3}]


async def test_stop_before_the_start_is_refused(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    run = Driver(client, await timed(client))
    await run.start(10)
    before = await event_count()
    r = await run.tap("stop", 9.999, status=422)
    assert (r["code"], r["errors"][0]["loc"]) == ("before_start", ["at"])
    frozen_clock(monkeypatch, T0 + timedelta(days=7))  # so the late stop is within the `at` bounds
    r = await run.tap("stop", 10 + 7 * 86_400 + 1, status=422)
    assert r["code"] == "run_too_long"
    assert await event_count() == before
    assert (await run.get())["status"] == "running"


async def test_finish_before_the_stop_is_refused(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    assert (await run.tap("finish", 5, status=409, answers={"mood": 1}))["code"] == "run_open"
    assert await event_count() == 1


async def test_archived_topic_still_stops(client: httpx.AsyncClient) -> None:
    topic = await timed(client)
    run = Driver(client, topic)
    await run.start()
    assert (await client.post(f"/topics/{topic['id']}/archive")).status_code == 200
    result = await run.tap("stop", 30)
    assert result["entry"]["id"] == run.id


# --- pause, resume, the open state ------------------------------------------------------------


async def test_pause_and_resume(client: httpx.AsyncClient) -> None:
    topic = await timed(client)
    run = Driver(client, topic)
    await run.start()
    before = await head()
    pause = await run.tap("pause", 10)
    assert (pause["run"]["status"], pause["run"]["state"]["paused_since"]) == (
        "paused",
        "2026-10-23T08:00:10Z",
    )
    stray = await run.tap("resume", 12, pause_id=str(uuid4()))
    assert stray["event"] == {"id": stray["event"]["id"], "effect": "void", "reason": "stale"}
    resumed = await run.tap("resume", 15, pause_id=pause["event"]["id"])
    assert resumed["run"]["status"] == "running"
    assert resumed["run"]["revision"] == 4
    assert resumed["run"]["state"]["pauses"] == [
        {"start": "2026-10-23T08:00:10Z", "end": "2026-10-23T08:00:15Z"}
    ]
    assert resumed["run"]["events"][-1]["pause_id"] == pause["event"]["id"]
    # Every change to an open run logs a run upsert.
    assert await log_rows(before) == [("run", "upsert", run.id)] * 3


# --- T6: late merges into a stopped run (§4.4) ------------------------------------------------


async def test_late_next_merges_into_the_entry(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run = Driver(client, topic)
    await run.start()
    stopped = await run.tap("stop", 100)
    assert stopped["entry"]["revision"] == 1
    assert [s["step"] for s in stopped["entry"]["timing"]["segments"]] == ["shower"]
    before = await head()

    late = await run.tap("next", 40, seg=0)  # tapped offline before the stop
    assert late["event"]["effect"] == "applied"
    assert late["run"]["status"] == "stopped"
    entry = late["entry"]
    assert entry["revision"] == 2
    assert [(s["step"], s["active_ms"]) for s in entry["timing"]["segments"]] == [
        ("shower", 40_000),
        ("breakfast", 60_000),
    ]
    assert entry["captured_at"] == "2026-10-23T08:01:40Z"
    assert await log_rows(before) == [("entry", "upsert", run.id)]  # never a run upsert

    after_stop = await run.tap("lap", 120, seg=2)
    assert after_stop["event"] == {"id": after_stop["event"]["id"], "effect": "void", "reason": "after_stop"}
    assert after_stop["entry"]["revision"] == 2  # unchanged times: no entry bump
    assert await log_rows(before + 1) == []

    second = await run.tap("stop", 110)
    assert second["event"]["reason"] == "already_closed"
    assert (await run.tap("discard", 115))["event"]["reason"] == "already_closed"


async def test_late_next_merges_into_a_finishing_run(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS, questions=REQUIRED))
    await run.start()
    await run.tap("stop", 100)
    before = await head()
    late = await run.tap("next", 40, seg=0)
    assert late["run"]["status"] == "finishing"
    assert [s["step"] for s in late["run"]["state"]["segments"]] == ["shower", "breakfast"]
    assert await log_rows(before) == [("run", "upsert", run.id)]
    finished = await run.tap("finish", 120, answers={"mood": 1})
    assert [s["active_ms"] for s in finished["entry"]["timing"]["segments"]] == [40_000, 60_000]


async def test_events_after_the_entry_is_deleted(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS, questions=OPTIONAL))
    await run.start()
    await run.tap("stop", 100)
    assert (await client.delete(f"/entries/{run.id}")).status_code == 204
    before = await head()
    for kind, fields in (("next", {"seg": 0}), ("finish", {"answers": {"note": "x"}}), ("stop", {})):
        result = await run.tap(kind, 40 if kind == "next" else 120, **fields)
        assert result["event"]["reason"] == "entry_deleted", kind
        assert result["entry"] is None
    assert await log_rows(before) == []
    # The id stays reserved: no entry and no run can take it.
    r = await client.post(f"/topics/{run.topic['id']}/entries", json={"id": run.id, "answers": {}})
    assert r.json()["code"] == "entry_deleted"


async def test_events_on_a_discarded_run(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run = Driver(client, topic)
    await run.start()
    before = await head()
    discarded = await run.tap("discard", 50)
    assert (discarded["event"]["effect"], discarded["run"]["status"]) == ("applied", "discarded")
    assert await log_rows(before) == [("run", "delete", run.id)]
    late = await run.tap("next", 40, seg=0)
    assert late["event"]["reason"] == "already_closed"
    assert late["run"]["state"]["segments"] == []  # not refolded
    # The topic has no open run now: a new start makes a new run.
    assert (await Driver(client, topic).start())["event"]["effect"] == "applied"


# --- T15: discard of a finishing run (§3.7) ---------------------------------------------------


async def test_discard_finishing_and_stopped(client: httpx.AsyncClient) -> None:
    topic = await timed(client, questions=REQUIRED)
    run = Driver(client, topic)
    await run.start()
    await run.tap("stop", 30)
    before = await head()
    result = await run.tap("discard", 40)
    assert result["event"]["effect"] == "applied"
    assert (result["run"]["status"], result["run"]["state"]["status"]) == ("discarded", "discarded")
    assert await log_rows(before) == [("run", "delete", run.id)]
    assert run.id in await tombstoned(FeedKind.run)
    assert (await run.tap("finish", 50, answers={"mood": 1}))["event"]["reason"] == "already_closed"
    assert (await run.get())["state"]["effects"][result["event"]["id"]]["effect"] == "applied"

    stopped = Driver(client, topic)
    await stopped.start()
    await stopped.tap("stop", 30, answers={"mood": 2})
    void = await stopped.tap("discard", 40)
    assert (void["event"]["reason"], void["run"]["status"]) == ("already_closed", "stopped")
    assert void["entry"]["id"] == stopped.id


# --- T16: finish on a stopped run, a second stop with answers, edited runs ----------------------


async def test_finish_patches_a_stopped_entry(client: httpx.AsyncClient) -> None:
    questions = [*OPTIONAL, {"key": "score", "label": "Score", "type": "int", "required": False}]
    run = Driver(client, await timed(client, questions=questions))
    await run.start()
    stopped = await run.tap("stop", 30, answers={"note": "first"})
    assert stopped["entry"]["revision"] == 1
    before = await head()
    result = await run.tap("finish", 40, answers={"score": 4}, notes="later")
    assert result["event"]["effect"] == "applied"
    entry = result["entry"]
    assert entry["revision"] == 2
    assert {a["key"]: a["value"] for a in entry["answers"]} == {"note": "first", "score": 4}  # merged by key
    assert entry["notes"] == "later"
    assert await log_rows(before) == [("entry", "upsert", run.id)]

    # A second stop with answers (another device stopped first) is applied as a finish.
    second = await run.tap("stop", 35, answers={"note": "second"})
    assert second["event"]["effect"] == "applied"
    assert {a["key"]: a["value"] for a in second["entry"]["answers"]} == {"note": "second", "score": 4}
    assert second["entry"]["revision"] == 3
    assert second["entry"]["captured_at"] == "2026-10-23T08:00:30Z"  # the first stop's time stays
    # And a late Next refolds without undoing either.
    later = await run.tap("lap", 10, seg=0)
    effects = later["run"]["state"]["effects"]
    assert effects[second["event"]["id"]]["effect"] == "applied"
    assert effects[result["event"]["id"]]["effect"] == "applied"


async def test_finish_on_a_stopped_entry_enforces_required(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=[*REQUIRED, *OPTIONAL]))
    await run.start()
    await run.tap("stop", 30, answers={"mood": 1})
    r = await run.tap("finish", 40, status=422, answers={"mood": None})
    assert r["errors"] == [{"loc": ["answers", "mood"], "message": "required"}]


async def test_edited_run_ignores_later_events(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS, questions=OPTIONAL))
    await run.start()
    stopped = await run.tap("stop", 100)
    async with get_sessionmaker()() as db:  # T-EDIT's PATCH sets the flag (§3.8)
        await db.execute(update(Run).where(Run.id == UUID(run.id)).values(edited=True))
        await db.commit()
    before = await head()
    late = await run.tap("next", 40, seg=0)
    assert late["event"]["reason"] == "run_edited"
    assert late["run"]["state"]["segments"] == stopped["run"]["state"]["segments"]  # no refold
    assert late["entry"] == stopped["entry"]
    assert (await run.tap("stop", 120))["event"]["reason"] == "run_edited"
    assert await log_rows(before) == []
    # Answers aren't times: a finish still lands on the edited run's entry.
    finished = await run.tap("finish", 130, answers={"note": "kept"})
    assert finished["event"]["effect"] == "applied"
    assert finished["entry"]["answers"] == [{"key": "note", "type": "str", "value": "kept"}]


# --- T13: one id space for runs and entries (§1.1, §3.9) ---------------------------------------


async def test_id_conflicts(client: httpx.AsyncClient) -> None:
    topic = await timed(client, questions=REQUIRED)
    entry = (
        await client.post(f"/topics/{topic['id']}/entries", json={"id": str(uuid4()), "answers": {"mood": 1}})
    ).json()
    r = await client.post(
        f"/runs/{entry['id']}/events", json={**_start_body(Driver(client, topic, entry["id"]), 0)}
    )
    assert (r.status_code, r.json()["code"]) == (409, "id_conflict")

    def create(entry_id: str) -> Any:
        return client.post(f"/topics/{topic['id']}/entries", json={"id": entry_id, "answers": {"mood": 1}})

    open_run = Driver(client, topic)
    await open_run.start()
    alias = Driver(client, topic)
    await alias.start(5)  # merged
    for run_id in (open_run.id, alias.id):
        r = await create(run_id)
        assert (r.status_code, r.json()["code"]) == (409, "id_conflict")
    await open_run.tap("stop", 30)  # finishing
    r = await create(open_run.id)
    assert (r.status_code, r.json()["code"]) == (409, "id_conflict")
    stopped = await open_run.tap("finish", 40, answers={"mood": 2})
    r = await create(open_run.id)  # a stopped run's id: the idempotent replay of its entry
    assert (r.status_code, r.json()) == (201, stopped["entry"])

    discarded = Driver(client, topic)
    await discarded.start()
    await discarded.tap("discard", 10)
    r = await create(discarded.id)
    assert (r.status_code, r.json()["code"]) == (409, "id_conflict")


async def test_deleted_entry_id_cant_start(client: httpx.AsyncClient) -> None:
    topic = await timed(client)
    entry_id = str(uuid4())
    await client.delete(f"/entries/{entry_id}")  # reserves the id
    r = await client.post(f"/runs/{entry_id}/events", json=_start_body(Driver(client, topic, entry_id), 0))
    assert (r.status_code, r.json()["code"]) == (409, "id_conflict")


# --- T9: topic delete with an open run ----------------------------------------------------------


async def test_topic_delete_with_an_open_run(client: httpx.AsyncClient) -> None:
    topic = await timed(client, steps=STEPS)
    run, alias, closed = Driver(client, topic), Driver(client, topic), Driver(client, topic)
    await closed.start()
    await closed.tap("stop", 5)
    await run.start(10)
    await alias.start(11)  # merged into run
    assert (await client.post(f"/topics/{topic['id']}/archive")).status_code == 200
    assert (await client.delete(f"/topics/{topic['id']}")).status_code == 204

    assert {run.id, alias.id, closed.id} <= await tombstoned(FeedKind.run)
    for target in (run, alias):
        r = await client.post(
            f"/runs/{target.id}/events", json={"id": str(uuid4()), "type": "pause", "at": at(20)}
        )
        assert (r.status_code, r.json()["code"]) == (409, "run_deleted")
        r = await client.post(f"/runs/{target.id}/events", json=_start_body(target, 10))
        assert (r.status_code, r.json()["code"]) == (409, "run_deleted")
    assert (await client.get(f"/runs/{run.id}")).status_code == 404
    async with get_sessionmaker()() as db:
        assert await db.scalar(select(func.count()).select_from(Run)) == 0


# --- listRuns ------------------------------------------------------------------------------------


async def test_list_runs(client: httpx.AsyncClient) -> None:
    a = await timed(client, "A", questions=REQUIRED)
    b = await timed(client, "B")
    finishing, running, paused, again = (
        Driver(client, a),
        Driver(client, b),
        Driver(client, a),
        Driver(client, b),
    )
    await finishing.start(0)
    await finishing.tap("stop", 5)
    await running.start(10)
    await paused.start(20)
    await paused.tap("pause", 25)
    await running.tap("stop", 30)  # stopped: b has no required question
    await again.start(40)  # b's run stopped: a new one

    async def ids(**params: Any) -> list[str]:
        r = await client.get("/runs", params=params)
        assert r.status_code == 200, r.text
        return [run["id"] for run in r.json()]

    assert await ids() == [finishing.id, paused.id, again.id]
    assert await ids(status="open") == [paused.id, again.id]
    assert await ids(status="finishing") == [finishing.id]
    assert await ids(status=["open", "finishing"], topic="a") == [finishing.id, paused.id]
    assert await ids(topic=b["id"]) == [again.id]
    assert (await client.get("/runs", params={"status": "stopped"})).status_code == 422
    assert (await client.get("/runs", params={"topic": "nope"})).status_code == 404
    listed = (await client.get("/runs", params={"topic": "a", "status": "open"})).json()
    assert listed == [await paused.get()]


# --- review follow-ups -----------------------------------------------------------------------


async def test_replays_differing_in_step_or_pause_id_conflict(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS))
    await run.start()
    skip = {"id": str(uuid4()), "type": "skip", "at": at(10), "seg": 0, "step": "shower"}
    await run.post(skip)
    r = await client.post(f"/runs/{run.id}/events", json={**skip, "step": "breakfast"})
    assert (r.status_code, r.json()["code"]) == (409, "event_conflict")
    pause = await run.tap("pause", 20)
    resume = {"id": str(uuid4()), "type": "resume", "at": at(30), "pause_id": pause["event"]["id"]}
    await run.post(resume)
    r = await client.post(f"/runs/{run.id}/events", json={**resume, "pause_id": str(uuid4())})
    assert (r.status_code, r.json()["code"]) == (409, "event_conflict")


async def test_stop_with_empty_answers_enforces_required(client: httpx.AsyncClient) -> None:
    """Answers present (even empty) are validated like createEntry's: no `finishing` fallback."""
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    r = await run.tap("stop", 30, status=422, answers={})
    assert r["errors"] == [{"loc": ["answers", "mood"], "message": "required"}]
    assert (await run.get())["status"] == "running"


async def test_create_entry_with_a_deleted_topics_run_id(client: httpx.AsyncClient) -> None:
    gone = await timed(client, "Gone")
    run = Driver(client, gone)
    await run.start()
    await client.post(f"/topics/{gone['id']}/archive")
    assert (await client.delete(f"/topics/{gone['id']}")).status_code == 204
    other = await timed(client, "Other")
    r = await client.post(f"/topics/{other['id']}/entries", json={"id": run.id, "answers": {}})
    assert (r.status_code, r.json()["code"]) == (409, "id_conflict")


async def test_second_stop_with_answers_on_a_finishing_run(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    await run.tap("stop", 30, meta={"via": "widget"})  # finishing
    before = await head()
    second = await run.tap("stop", 45, answers={"mood": 5})
    assert second["event"]["effect"] == "applied"
    assert second["run"]["status"] == "stopped"
    entry = second["entry"]
    assert entry["captured_at"] == "2026-10-23T08:00:30Z"  # the first stop's time
    assert (entry["answers"], entry["meta"]) == (
        [{"key": "mood", "type": "int", "value": 5}],
        {"via": "widget"},
    )
    assert await log_rows(before) == [("entry", "upsert", run.id), ("run", "delete", run.id)]


async def test_finish_on_a_stopped_entry_merges_meta(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=OPTIONAL))
    await run.start()
    await run.tap("stop", 30, meta={"via": "widget", "n": "1"})
    finished = await run.tap("finish", 40, answers={}, meta={"n": "2", "form": "sheet"})
    assert finished["entry"]["meta"] == {"via": "widget", "n": "2", "form": "sheet"}
    again = await run.tap("stop", 50, answers={"note": "x"}, meta={"late": "yes"})
    assert again["entry"]["meta"] == {"via": "widget", "n": "2", "form": "sheet", "late": "yes"}
    plain = await run.tap("finish", 60, answers={"note": "y"})  # no meta: kept as it is
    assert plain["entry"]["meta"] == again["entry"]["meta"]


@pytest.mark.parametrize("read", ["get", "list"])
async def test_reads_see_one_snapshot(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, read: str
) -> None:
    """A tap that commits between reading the run row and reading its events doesn't show up
    half: the events and the state agree (no KeyError, no 500)."""
    run = Driver(client, await timed(client))
    await run.start()
    real = run_svc._events
    late = {"id": str(uuid4()), "type": "pause", "at": at(5)}

    async def events_after_a_commit(db: Any, run_id: UUID) -> Any:
        monkeypatch.setattr(run_svc, "_events", real)
        async with get_sessionmaker()() as other:
            await run_svc.record_event(other, run_id, RunEventIn.model_validate(late), Channel.api)
        return await real(db, run_id)

    monkeypatch.setattr(run_svc, "_events", events_after_a_commit)
    r = await (client.get(f"/runs/{run.id}") if read == "get" else client.get("/runs"))
    assert r.status_code == 200, r.text
    out = r.json() if read == "get" else r.json()[0]
    assert [e["type"] for e in out["events"]] == ["start"]  # the snapshot from before the tap
    assert set(out["state"]["effects"]) == {run.id}
    assert [e["type"] for e in (await run.get())["events"]] == ["start", "pause"]
