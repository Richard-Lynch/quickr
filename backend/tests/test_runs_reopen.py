"""Reopen and remove over the API (docs/specs/timers2.md §4, §7): spec cases T19 to T26 (§12.2).

T18 (every fold v4 vector through the endpoint) is ``test_api_runs.py``'s vector test, widened
to the reopen and remove cases. The server clock is frozen at ``NOW`` (``test_api_runs``).
"""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest

from app.db import get_sessionmaker
from app.models import Entry, FeedKind, RunEvent
from tests.fake_apns import FakeApns, token
from tests.test_api_runs import (
    NOW,
    OPTIONAL,
    REQUIRED,
    STEPS,
    Driver,
    _racing,
    at,
    event_count,
    frozen_clock,
    head,
    log_rows,
    timed,
    tombstoned,
)
from tests.test_feed import changes
from tests.test_live_activity import aps, device, start_token, to

RENAMED = {"steps": [], "laps": [{"key": "cig", "label": "Cig"}]}
TIKTOK = {"steps": [], "laps": [{"key": "run", "label": "Run"}, {"key": "rest", "label": "Rest"}]}


@pytest.fixture(autouse=True)
def _clock(monkeypatch: pytest.MonkeyPatch) -> None:
    frozen_clock(monkeypatch, NOW)


def ts(seconds: float) -> str:
    """``at(seconds)`` as the API writes it."""
    return at(seconds).replace("+00:00", "Z")


async def entry(client: httpx.AsyncClient, run: Driver) -> dict[str, Any]:
    r = await client.get(f"/entries/{run.id}")
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()
    return out


async def stopped_run(
    client: httpx.AsyncClient,
    *,
    stop_at: float = 90,
    questions: list[dict[str, Any]] | None = None,
    **topic: Any,
) -> tuple[Driver, str]:
    """A run with a lap at 60 s, stopped at ``stop_at``: its entry exists (revision 1)."""
    run = Driver(
        client, await timed(client, questions=questions if questions is not None else OPTIONAL, **topic)
    )
    await run.start()
    await run.tap("lap", 60, seg=0)
    stop = str(uuid4())
    result = await run.tap("stop", stop_at, id=stop)
    assert result["run"]["status"] == "stopped"
    assert result["entry"]["revision"] == 1
    return run, stop


async def stored_target(event_id: str) -> UUID | None:
    async with get_sessionmaker()() as db:
        row = await db.get(RunEvent, UUID(event_id))
        assert row is not None
        return row.target_id


def effect_of(result: dict[str, Any], event_id: str) -> dict[str, Any]:
    out: dict[str, Any] = result["run"]["state"]["effects"][event_id]
    return out


# --- T19: reopen ---------------------------------------------------------------------------------


async def test_reopen_a_stopped_run(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    saved = await entry(client, run)
    revision = (await run.get())["revision"]
    before = await head()
    reopen = str(uuid4())
    result = await run.tap("reopen", 110, id=reopen, target=stop)
    assert result["event"] == {"id": reopen, "effect": "applied", "reason": None}
    out = result["run"]
    assert (out["status"], out["ended_at"], out["revision"]) == ("running", None, revision + 1)
    assert result["entry"] is None  # the run is open: it represents the entry (§5.3)
    state = out["state"]
    assert (state["status"], state["terminal_id"], state["paused_since"]) == ("running", None, None)
    # The gap is a pause that carries its stop's id; the open lap spans it (§3.4).
    assert state["pauses"] == [{"start": ts(90), "end": ts(110), "id": stop}]
    assert state["open"]["started_at"] == ts(60)
    assert next(e for e in out["events"] if e["id"] == reopen)["target"] == stop
    assert await log_rows(before) == [("run", "upsert", run.id)]
    # The entry stays, unchanged, and createEntry with its id replays it.
    assert await entry(client, run) == saved
    r = await client.post(f"/topics/{run.topic['id']}/entries", json={"id": run.id, "answers": {}})
    assert r.status_code == 201, r.text
    assert r.json() == saved
    assert await run.get() == out


async def test_reopen_a_finishing_run(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    stop = str(uuid4())
    assert (await run.tap("stop", 60, id=stop))["run"]["status"] == "finishing"
    before = await head()
    result = await run.tap("reopen", 80, target=stop)
    assert result["event"]["effect"] == "applied"
    assert (result["run"]["status"], result["run"]["ended_at"], result["entry"]) == ("running", None, None)
    assert await log_rows(before) == [("run", "upsert", run.id)]
    # Its re-stop is a first stop again: finishing, as required answers are still missing.
    again = await run.tap("stop", 120)
    assert (again["run"]["status"], again["entry"]) == ("finishing", None)
    assert (await client.get(f"/entries/{run.id}")).status_code == 404


async def test_a_null_target_resolves_to_the_terminal(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    reopen = str(uuid4())
    result = await run.tap("reopen", 110, id=reopen)  # no target: "the current terminal" (§4.2)
    assert result["event"]["effect"] == "applied"
    assert next(e for e in result["run"]["events"] if e["id"] == reopen)["target"] == stop
    assert await stored_target(reopen) == UUID(stop)
    # A replay without the target is the same event; with another target it isn't.
    replay = await run.tap("reopen", 110, id=reopen)
    assert replay["event"] == result["event"]
    conflict = await run.tap("reopen", 110, id=reopen, target=str(uuid4()), status=409)
    assert conflict["code"] == "event_conflict"


async def test_a_null_target_on_an_open_run_is_no_target(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client))
    await run.start()
    reopen = str(uuid4())
    result = await run.tap("reopen", 30, id=reopen)
    assert result["event"] == {"id": reopen, "effect": "void", "reason": "no_target"}
    assert next(e for e in result["run"]["events"] if e["id"] == reopen)["target"] is None
    assert await stored_target(reopen) is None


async def test_two_reopens_of_one_stop_race(client: httpx.AsyncClient) -> None:
    """T2/T3-style: both wait on the feed lock; one applies, the other is not_stopped."""
    run, stop = await stopped_run(client)

    def reopen(seconds: int) -> Any:
        body = {"id": str(uuid4()), "type": "reopen", "at": at(seconds), "target": stop}
        return lambda: client.post(f"/runs/{run.id}/events", json=body)

    results = await _racing(reopen(100), reopen(101))
    assert [r.status_code for r in results] == [200, 200]
    effects = sorted((r.json()["event"]["effect"], r.json()["event"]["reason"]) for r in results)
    assert effects == [("applied", None), ("void", "not_stopped")]
    assert (await run.get())["status"] == "running"


# --- T20: re-stop ---------------------------------------------------------------------------------


async def test_restop_replaces_the_entry_timing(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    await run.tap("reopen", 110, target=stop)
    await run.tap("lap", 150, seg=1)
    before = await head()
    restop = str(uuid4())
    result = await run.tap("stop", 180, id=restop, answers={"note": "again"}, notes="re-stopped")
    assert result["event"]["effect"] == "applied"
    assert (result["run"]["status"], result["run"]["ended_at"]) == ("stopped", ts(180))
    saved = result["entry"]
    assert (saved["revision"], saved["captured_at"], saved["notes"]) == (2, ts(180), "re-stopped")
    assert saved["answers"] == [{"key": "note", "type": "str", "value": "again"}]
    timing = saved["timing"]
    assert (timing["ended_at"], timing["terminal_id"], timing["paused_ms"]) == (ts(180), restop, 20_000)
    assert [(s["label"], s["active_ms"], s["paused_ms"]) for s in timing["segments"]] == [
        ("Lap 1", 60_000, 0),
        ("Lap 2", 70_000, 20_000),
        ("Lap 3", 30_000, 0),
    ]
    assert timing["pauses"] == [{"start": ts(90), "end": ts(110), "id": stop}]
    assert await log_rows(before) == [("entry", "upsert", run.id), ("run", "delete", run.id)]
    assert run.id not in await tombstoned(FeedKind.run)
    assert result["run"]["state"]["terminal_id"] == restop


async def test_restop_enforces_required_answers(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    stop = str(uuid4())
    assert (await run.tap("stop", 90, id=stop, answers={"mood": 3}))["entry"]["revision"] == 1
    await run.tap("reopen", 110, target=stop)
    count = await event_count()
    refused = await run.tap("stop", 150, status=422, answers={"mood": None})
    assert refused["errors"] == [{"loc": ["answers", "mood"], "message": "required"}]
    assert await event_count() == count  # nothing stored
    assert (await run.get())["status"] == "running"
    # Without answers the entry's own are kept: never finishing.
    result = await run.tap("stop", 160)
    assert result["run"]["status"] == "stopped"
    assert result["entry"]["answers"] == [{"key": "mood", "type": "int", "value": 3}]


async def test_restop_more_than_7_days_is_refused(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    run, stop = await stopped_run(client)
    await run.tap("reopen", 110, target=stop)
    late = 7 * 24 * 3600 + 1
    frozen_clock(monkeypatch, NOW.replace(day=30))
    refused = await run.tap("stop", late, status=422)
    assert refused["code"] == "run_too_long"


# --- T21: revert ----------------------------------------------------------------------------------


async def test_discard_after_reopen_reverts(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    reopen = str(uuid4())
    await run.tap("reopen", 110, id=reopen, target=stop)
    lap = str(uuid4())
    await run.tap("lap", 130, id=lap, seg=1)
    before = await head()
    result = await run.tap("discard", 150)
    assert result["event"]["effect"] == "applied"
    out = result["run"]
    assert (out["status"], out["ended_at"], out["state"]["terminal_id"]) == ("stopped", ts(90), stop)
    events = {e["id"]: e for e in out["events"]}
    assert (events[reopen]["effect"], events[reopen]["reason"]) == ("void", "reverted")
    assert (events[lap]["effect"], events[lap]["reason"]) == ("void", "after_stop")
    assert await log_rows(before) == [("run", "delete", run.id)]
    assert run.id not in await tombstoned(FeedKind.run)
    assert result["entry"]["revision"] == 1
    # The run can be reopened again.
    assert (await run.tap("reopen", 200, target=stop))["event"]["effect"] == "applied"


async def test_revert_of_a_reopened_finishing_run_discards_it(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    stop = str(uuid4())
    await run.tap("stop", 60, id=stop)
    await run.tap("reopen", 80, target=stop)
    before = await head()
    result = await run.tap("discard", 100)
    assert result["event"]["effect"] == "applied"
    assert result["run"]["status"] == "discarded"
    assert await log_rows(before) == [("run", "delete", run.id)]
    assert run.id in await tombstoned(FeedKind.run)


# --- T22: another open run ------------------------------------------------------------------------


async def test_reopen_while_another_run_is_open_conflicts(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    other = Driver(client, run.topic)
    await other.start(120)
    count = await event_count()
    before = await head()
    refused = await run.tap("reopen", 130, target=stop, status=409)
    assert refused["code"] == "conflict"
    assert await event_count() == count
    assert await log_rows(before) == []
    assert (await run.get())["status"] == "stopped"


# --- T23: void reasons, targets, ids, timing edits ------------------------------------------------


async def test_reopen_void_reasons(client: httpx.AsyncClient) -> None:
    # An edited run: the edit wins.
    edited, stop = await stopped_run(client)
    saved = await entry(client, edited)
    edit = {
        "expected_revision": saved["revision"],
        "timing": {
            "started_at": at(0),
            "segments": [{"kind": "lap", "step": None, "ended_at": at(80)}],
            "skipped": [],
            "pauses": [],
        },
    }
    assert (await client.patch(f"/entries/{edited.id}", json=edit)).status_code == 200
    before = await head()
    void = await edited.tap("reopen", 110, target=stop)
    assert void["event"]["reason"] == "run_edited"
    assert await log_rows(before) == []

    # Its entry deleted: gone for good.
    deleted, stop = await stopped_run(client, name="Deleted")
    assert (await client.delete(f"/entries/{deleted.id}")).status_code == 204
    assert (await deleted.tap("reopen", 110, target=stop))["event"]["reason"] == "entry_deleted"
    assert (await deleted.tap("remove", 120, target=stop))["event"]["reason"] == "entry_deleted"

    # A discarded run.
    discarded = Driver(client, await timed(client, "Discarded"))
    await discarded.start()
    gone = str(uuid4())
    await discarded.tap("discard", 30, id=gone)
    assert (await discarded.tap("reopen", 40, target=gone))["event"]["reason"] == "already_closed"

    # A stop that is not the current terminal, and an unknown id.
    run, first = await stopped_run(client, name="Twice")
    await run.tap("reopen", 100, target=first)
    second = str(uuid4())
    await run.tap("stop", 120, id=second)
    assert (await run.tap("reopen", 130, target=first))["event"]["reason"] == "not_stopped"
    assert (await run.tap("reopen", 130, target=str(uuid4())))["event"]["reason"] == "no_target"
    assert (await run.get())["state"]["terminal_id"] == second


@pytest.mark.parametrize(
    ("kind", "fields", "loc"),
    [
        ("remove", {}, "target"),
        ("lap", {"seg": 0, "target": "00000000-0000-4000-8000-000000000001"}, "target"),
        ("stop", {"target": "00000000-0000-4000-8000-000000000001"}, "target"),
        ("reopen", {"answers": {}}, "answers"),
    ],
)
async def test_target_fields_per_type(
    client: httpx.AsyncClient, kind: str, fields: dict[str, Any], loc: str
) -> None:
    run = Driver(client, await timed(client))
    await run.start()
    r = await run.tap(kind, 10, status=422, **fields)
    assert r["code"] == "invalid_request"
    assert [e["loc"] for e in r["errors"]] == [[loc]]


async def test_timing_carries_event_ids(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS, questions=OPTIONAL))
    await run.start()
    nxt, pause, resume, stop = (str(uuid4()) for _ in range(4))
    await run.tap("next", 30, id=nxt, seg=0)
    await run.tap("pause", 40, id=pause)
    await run.tap("resume", 50, id=resume, pause_id=pause)
    result = await run.tap("stop", 90, id=stop)
    timing = result["entry"]["timing"]
    assert timing["terminal_id"] == stop
    assert [(s["event_id"], s["opened_by"]) for s in timing["segments"]] == [(None, "start"), (nxt, "next")]
    assert [p["id"] for p in timing["pauses"]] == [pause]
    # An edit nulls the segment and pause ids and keeps terminal_id (§3.3).
    edit = {
        "expected_revision": 1,
        "timing": {
            "started_at": at(0),
            "segments": [
                {"kind": "step", "step": "shower", "ended_at": at(30)},
                {"kind": "step", "step": "breakfast", "ended_at": at(90)},
            ],
            "skipped": [],
            "pauses": [{"start": at(40), "end": at(50)}],
        },
    }
    r = await client.patch(f"/entries/{run.id}", json=edit)
    assert r.status_code == 200, r.text
    edited = r.json()["timing"]
    assert edited["terminal_id"] == stop
    assert [(s["event_id"], s["opened_by"]) for s in edited["segments"]] == [(None, None), (None, None)]
    assert [p["id"] for p in edited["pauses"]] == [None]


async def test_a_stored_v1_timing_is_served_with_null_ids(client: httpx.AsyncClient) -> None:
    run, _ = await stopped_run(client)
    v1 = {
        "started_at": ts(0),
        "ended_at": ts(90),
        "active_ms": 80_000,
        "paused_ms": 10_000,
        "complete": True,
        "edited": False,
        "segments": [
            {
                "kind": "lap",
                "step": None,
                "label": "Lap 1",
                "started_at": ts(0),
                "ended_at": ts(90),
                "active_ms": 80_000,
                "paused_ms": 10_000,
            }
        ],
        "skipped": [],
        "pauses": [{"start": ts(40), "end": ts(50)}],
    }
    async with get_sessionmaker()() as db:
        row = await db.get_one(Entry, UUID(run.id))
        row.timing = v1
        await db.commit()
    timing = (await entry(client, run))["timing"]
    assert timing["terminal_id"] is None
    assert [(s["lap_type"], s["event_id"], s["opened_by"]) for s in timing["segments"]] == [
        (None, None, None)
    ]
    assert timing["pauses"] == [{"start": ts(40), "end": ts(50), "id": None}]


async def test_timing_edit_while_the_run_is_open_conflicts(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    await run.tap("reopen", 110, target=stop)
    saved = await entry(client, run)
    revision = (await run.get())["revision"]
    before = await head()
    edit = {
        "expected_revision": saved["revision"],
        "timing": {
            "started_at": at(0),
            "segments": [{"kind": "lap", "step": None, "ended_at": at(80)}],
            "skipped": [],
            "pauses": [],
        },
    }
    r = await client.patch(f"/entries/{run.id}", json=edit)
    assert (r.status_code, r.json()["code"]) == (409, "conflict")
    assert await entry(client, run) == saved
    assert (await run.get())["revision"] == revision
    assert await log_rows(before) == []
    # Fields other than timing still go through.
    r = await client.patch(f"/entries/{run.id}", json={"notes": "fine"})
    assert r.status_code == 200, r.text


# --- T24: remove on an open run -------------------------------------------------------------------


async def test_remove_a_pause_on_an_open_run(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client))
    await run.start()
    pause, resume = str(uuid4()), str(uuid4())
    await run.tap("pause", 60, id=pause)
    await run.tap("resume", 80, id=resume, pause_id=pause)
    await run.tap("lap", 120, seg=0)
    before = await head()
    remove = str(uuid4())
    result = await run.tap("remove", 130, id=remove, target=pause)
    assert result["event"] == {"id": remove, "effect": "applied", "reason": None}
    assert effect_of(result, pause) == {"effect": "void", "reason": "deleted"}
    assert effect_of(result, resume) == {"effect": "void", "reason": "deleted"}
    state = result["run"]["state"]
    assert state["pauses"] == []
    assert [(s["label"], s["active_ms"]) for s in state["segments"]] == [("Lap 1", 120_000)]
    assert await log_rows(before) == [("run", "upsert", run.id)]


async def test_remove_the_gap_pause_after_a_reopen(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=OPTIONAL))
    await run.start()
    stop = str(uuid4())
    await run.tap("stop", 60, id=stop)
    await run.tap("reopen", 90, target=stop)
    result = await run.tap("remove", 100, target=stop)
    assert result["event"]["effect"] == "applied"
    assert effect_of(result, stop) == {"effect": "void", "reason": "deleted"}
    assert result["run"]["state"]["pauses"] == []
    final = await run.tap("stop", 120)
    assert [(s["active_ms"], s["paused_ms"]) for s in final["entry"]["timing"]["segments"]] == [(120_000, 0)]
    assert final["entry"]["revision"] == 2


async def test_remove_a_double_tapped_lap_keeps_the_rhythm(client: httpx.AsyncClient) -> None:
    """§6.4: the ghost keeps the later lap applied; a tap after the remove with the renumbered
    seg applies."""
    run = Driver(client, await timed(client, timer=TIKTOK))
    await run.start()
    e1, e2, e3 = str(uuid4()), str(uuid4()), str(uuid4())
    await run.tap("lap", 60, id=e1, seg=0)
    await run.tap("lap", 60.4, id=e2, seg=1)
    await run.tap("lap", 120, id=e3, seg=2)
    result = await run.tap("remove", 125, target=e2)
    assert effect_of(result, e2) == {"effect": "void", "reason": "deleted"}
    assert effect_of(result, e3) == {"effect": "applied", "reason": None}
    state = result["run"]["state"]
    assert [s["label"] for s in state["segments"]] == ["Run 1", "Rest 1"]
    assert (state["open"]["label"], state["next_lap_type"], state["lap_count"]) == ("Run 2", "rest", 2)
    after = await run.tap("lap", 150, seg=2)
    assert after["event"]["effect"] == "applied"
    assert after["run"]["state"]["open"]["label"] == "Rest 2"


async def test_remove_on_a_finishing_run_is_a_run_upsert(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, questions=REQUIRED))
    await run.start()
    pause = str(uuid4())
    await run.tap("pause", 20, id=pause)
    await run.tap("resume", 30, pause_id=pause)
    await run.tap("stop", 60)
    before = await head()
    result = await run.tap("remove", 70, target=pause)
    assert (result["event"]["effect"], result["run"]["status"]) == ("applied", "finishing")
    assert result["run"]["state"]["pauses"] == []
    assert await log_rows(before) == [("run", "upsert", run.id)]


# --- T25: remove on a stopped run -----------------------------------------------------------------


async def test_remove_a_lap_on_a_stopped_run_is_a_late_merge(client: httpx.AsyncClient) -> None:
    """§6.5 (timer ``renamed``): remove into the previous, then a late lap still merges."""
    run = Driver(client, await timed(client, timer=RENAMED, questions=OPTIONAL))
    await run.start()
    e1 = str(uuid4())
    await run.tap("lap", 60, id=e1, seg=0)
    await run.tap("lap", 65, seg=1)
    await run.tap("stop", 180)
    before = await head()
    result = await run.tap("remove", 220, target=e1)
    assert result["event"]["effect"] == "applied"
    saved = result["entry"]
    assert (saved["revision"], saved["captured_at"]) == (2, ts(180))
    assert [(s["label"], s["active_ms"]) for s in saved["timing"]["segments"]] == [
        ("Cig 1", 65_000),
        ("Cig 2", 115_000),
    ]
    assert result["run"]["edited"] is False
    assert await log_rows(before) == [("entry", "upsert", run.id)]

    late = await run.tap("lap", 120, seg=2)
    assert late["event"]["effect"] == "applied"
    assert late["entry"]["revision"] == 3
    assert [(s["label"], s["active_ms"]) for s in late["entry"]["timing"]["segments"]] == [
        ("Cig 1", 65_000),
        ("Cig 2", 55_000),
        ("Cig 3", 60_000),
    ]


async def test_remove_no_target_cases(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, steps=STEPS, questions=OPTIONAL))
    await run.start()
    nxt, lap, stop = str(uuid4()), str(uuid4()), str(uuid4())
    await run.tap("next", 30, id=nxt, seg=0)
    await run.tap("lap", 60, id=lap, seg=1)
    await run.tap("stop", 90, id=stop)
    assert (await run.tap("remove", 100, target=nxt))["event"]["reason"] == "no_target"  # a next
    assert (await run.tap("remove", 100, target=stop))["event"]["reason"] == "no_target"  # the terminal
    assert (await run.tap("remove", 50, target=lap))["event"]["reason"] == "no_target"  # at <= target.at
    before = await head()
    assert (await run.tap("remove", 110, target=lap))["event"]["effect"] == "applied"
    assert await log_rows(before) == [("entry", "upsert", run.id)]
    before = await head()
    assert (await run.tap("remove", 120, target=lap))["event"]["reason"] == "no_target"  # removed already
    assert await log_rows(before) == []  # a void late event on a stopped run logs nothing


# --- T26: tombstones --------------------------------------------------------------------------------


async def test_a_stop_writes_no_tombstone_but_the_feed_still_deletes_the_run(
    client: httpx.AsyncClient,
) -> None:
    cursor = await head()
    run, _ = await stopped_run(client)
    assert run.id not in await tombstoned(FeedKind.run)
    page = await changes(client, cursor)
    assert [d["id"] for d in page["deleted"] if d["kind"] == "run"] == [run.id]
    discarded = Driver(client, await timed(client, "Discarded"))
    await discarded.start()
    await discarded.tap("discard", 30)
    assert discarded.id in await tombstoned(FeedKind.run)


async def test_a_reopened_run_is_a_feed_item_again(client: httpx.AsyncClient) -> None:
    run, stop = await stopped_run(client)
    cursor = await head()
    await run.tap("reopen", 110, target=stop)
    page = await changes(client, cursor)
    [item] = [i for i in page["items"] if i["kind"] == "run"]
    assert (item["run"]["id"], item["run"]["status"]) == (run.id, "running")
    assert not page["deleted"]


# --- §4.6: Live Activity push-to-start on reopen ----------------------------------------------------


async def test_an_applied_reopen_pushes_start(client: httpx.AsyncClient, fake_apns: FakeApns) -> None:
    phone_a, phone_b = token(0xA), token(0xB)
    a, b = await start_token(client, 1, phone_a), await start_token(client, 2, phone_b)
    run, stop = await stopped_run(client)
    fake_apns.sent.clear()
    await run.tap("reopen", 110, target=stop, device=device(phone_a))
    assert to(fake_apns, a) == []  # it requested its own activity
    assert [aps(s)["event"] for s in to(fake_apns, b)] == ["start"]
    # A void reopen pushes no start (the run is open: not_stopped).
    fake_apns.sent.clear()
    void = await run.tap("reopen", 120, target=stop, device=device(phone_a))
    assert void["event"]["reason"] == "not_stopped"
    assert [aps(s)["event"] for s in to(fake_apns, b)] == []
