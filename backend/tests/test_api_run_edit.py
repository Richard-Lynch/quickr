"""Editing a stopped run's times: ``PATCH /entries/{id}`` with ``timing`` (docs/specs/timers.md §3.8).

Spec cases T10 and the last clause of T16 (§13.2), and the edit's validation per invariant
T2 to T5 (§2.3). The server clock is frozen at ``NOW``, as in ``test_api_runs.py``.
"""

from __future__ import annotations

import dataclasses
from typing import Any

import httpx
import pytest

from app.services import run_fold
from tests.test_api_runs import NOW, OPTIONAL, STEPS, Driver, at, frozen_clock, head, log_rows, timed


@pytest.fixture(autouse=True)
def _clock(monkeypatch: pytest.MonkeyPatch) -> None:
    frozen_clock(monkeypatch, NOW)


async def stopped_run(
    client: httpx.AsyncClient, steps: list[dict[str, str]] | None = None
) -> tuple[Driver, Any]:
    """Shower 0 to 60 s (paused 20 to 30 s), breakfast 60 to 100 s: the stopped run and its entry."""
    run = Driver(client, await timed(client, steps=STEPS if steps is None else steps, questions=OPTIONAL))
    await run.start()
    await run.tap("next", 60, seg=0)
    pause = await run.tap("pause", 20)
    await run.tap("resume", 30, pause_id=pause["event"]["id"])
    stopped = await run.tap("stop", 100)
    assert stopped["entry"]["timing"]["edited"] is False
    return run, stopped["entry"]


def edit(
    started: float = 0,
    segments: list[tuple[str | None, float]] | None = None,
    skipped: list[str] | None = None,
    pauses: list[tuple[float, float]] | None = None,
) -> dict[str, Any]:
    """A ``TimingEdit``; segment and pause times in seconds after ``T0``."""
    return {
        "started_at": at(started),
        "segments": [
            {"kind": "lap" if step is None else "step", "step": step, "ended_at": at(end)}
            for step, end in (segments if segments is not None else [("shower", 50), ("breakfast", 120)])
        ],
        "skipped": skipped or [],
        "pauses": [{"start": at(a), "end": at(b)} for a, b in (pauses or [])],
    }


async def patch(client: httpx.AsyncClient, entry: Any, body: dict[str, Any], status: int = 200) -> Any:
    r = await client.patch(f"/entries/{entry['id']}", json={"expected_revision": entry["revision"], **body})
    assert r.status_code == status, r.text
    return r.json()


# --- the edit (§3.8) ------------------------------------------------------------------------------


async def test_edit_rebuilds_the_timing(client: httpx.AsyncClient) -> None:
    run, entry = await stopped_run(client)
    before = await head()
    run_before = await run.get()
    body = edit(-10.0004, [("shower", 50), ("breakfast", 120)], pauses=[(40, 55)])  # sub-ms truncated
    edited = await patch(client, entry, {"timing": body, "notes": "fixed the times"})

    timing = edited["timing"]
    assert timing == {
        "started_at": "2026-10-23T07:59:49.999000Z",
        "ended_at": "2026-10-23T08:02:00Z",
        "active_ms": 130_001 - 15_000,
        "paused_ms": 15_000,
        "complete": True,
        "edited": True,
        "segments": [
            {
                "kind": "step",
                "step": "shower",
                "label": "Shower",
                "started_at": "2026-10-23T07:59:49.999000Z",
                "ended_at": "2026-10-23T08:00:50Z",
                "active_ms": 60_001 - 10_000,
                "paused_ms": 10_000,  # pauses stay whole: each segment gets its overlap (T5)
            },
            {
                "kind": "step",
                "step": "breakfast",
                "label": "Breakfast",
                "started_at": "2026-10-23T08:00:50Z",
                "ended_at": "2026-10-23T08:02:00Z",
                "active_ms": 70_000 - 5_000,
                "paused_ms": 5_000,
            },
        ],
        "skipped": [],
        "pauses": [{"start": "2026-10-23T08:00:40Z", "end": "2026-10-23T08:00:55Z"}],
    }
    assert edited["captured_at"] == timing["ended_at"]  # T1
    assert (edited["revision"], edited["notes"]) == (entry["revision"] + 1, "fixed the times")
    assert await log_rows(before) == [("entry", "upsert", entry["id"])]  # the run is closed: no run row

    run_after = await run.get()
    assert (run_after["edited"], run_after["revision"]) == (True, run_before["revision"] + 1)
    assert run_after["state"] == run_before["state"]  # the last fold stays; the entry has the edit
    assert (await client.get(f"/entries/{entry['id']}")).json() == edited


async def test_complete_follows_the_versions_steps(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    skipped = await patch(client, entry, {"timing": edit(0, [("breakfast", 100)], skipped=["shower"])})
    assert (skipped["timing"]["complete"], skipped["timing"]["skipped"]) == (False, ["shower"])
    short = await patch(client, skipped, {"timing": edit(0, [("shower", 60), (None, 100)])})
    assert short["timing"]["complete"] is False  # breakfast has no segment
    assert [s["label"] for s in short["timing"]["segments"]] == ["Shower", "Lap 1"]
    done = await patch(client, short, {"timing": edit(0, [("breakfast", 30), ("shower", 60), (None, 90)])})
    assert done["timing"]["complete"] is True  # every step timed, in any order


async def test_skipped_steps_are_kept_in_step_order(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    edited = await patch(client, entry, {"timing": edit(0, [(None, 100)], skipped=["breakfast", "shower"])})
    assert edited["timing"]["skipped"] == ["shower", "breakfast"]


async def test_a_stopwatch_edits_its_laps(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client, steps=[])
    edited = await patch(client, entry, {"timing": edit(0, [(None, 30), (None, 30), (None, 45)])})
    assert [(s["label"], s["active_ms"]) for s in edited["timing"]["segments"]] == [
        ("Lap 1", 30_000),
        ("Lap 2", 0),  # non-negative length: zero is fine
        ("Lap 3", 15_000),
    ]
    assert edited["timing"]["complete"] is True


# --- validation: one case per rule, each changing nothing ------------------------------------------

DAY = 24 * 3600

INVALID: list[tuple[str, dict[str, Any], int, str, list[str | int]]] = [
    # T2: segments are contiguous by construction, so a negative length is the only way to break it.
    (
        "negative segment",
        edit(0, [("shower", 50), ("breakfast", 40)]),
        422,
        "invalid_request",
        ["timing", "segments", 1, "ended_at"],
    ),
    (
        "segment before the start",
        edit(10, [("shower", 5), ("breakfast", 40)]),
        422,
        "invalid_request",
        ["timing", "segments", 0, "ended_at"],
    ),
    (
        "step segment without its step",
        edit(0, [("shower", 50)]) | {"segments": [{"kind": "step", "ended_at": at(50)}]},
        422,
        "invalid_request",
        ["timing", "segments", 0, "step"],
    ),
    (
        "lap naming a step",
        edit(0, [("shower", 50)]) | {"segments": [{"kind": "lap", "step": "shower", "ended_at": at(50)}]},
        422,
        "invalid_request",
        ["timing", "segments", 0, "step"],
    ),
    # T3: pauses sorted, disjoint, within [started_at, ended_at].
    (
        "pause before the start",
        edit(10, pauses=[(5, 20)]),
        422,
        "invalid_request",
        ["timing", "pauses", 0, "start"],
    ),
    (
        "pause after the end",
        edit(pauses=[(100, 130)]),
        422,
        "invalid_request",
        ["timing", "pauses", 0, "end"],
    ),
    (
        "pause ending before it starts",
        edit(pauses=[(30, 20)]),
        422,
        "invalid_request",
        ["timing", "pauses", 0, "end"],
    ),
    (
        "overlapping pauses",
        edit(pauses=[(10, 30), (25, 40)]),
        422,
        "invalid_request",
        ["timing", "pauses", 1, "start"],
    ),
    (
        "unsorted pauses",
        edit(pauses=[(30, 40), (10, 20)]),
        422,
        "invalid_request",
        ["timing", "pauses", 1, "start"],
    ),
    # T4: each step key at most once across segments and skipped.
    (
        "step timed twice",
        edit(0, [("shower", 50), ("shower", 120)]),
        422,
        "invalid_request",
        ["timing", "segments", 1, "step"],
    ),
    ("step timed and skipped", edit(skipped=["shower"]), 422, "invalid_request", ["timing", "skipped", 0]),
    # Step keys belong to the run's version.
    (
        "unknown step",
        edit(0, [("shower", 50), ("coffee", 120)]),
        422,
        "invalid_request",
        ["timing", "segments", 1, "step"],
    ),
    ("unknown skipped step", edit(skipped=["coffee"]), 422, "invalid_request", ["timing", "skipped", 0]),
    # §5: at most 7 days.
    (
        "longer than 7 days",
        edit(-7 * DAY - 51, [("shower", 0), ("breakfast", 50)]),
        422,
        "run_too_long",
        ["timing", "segments", 1, "ended_at"],
    ),
    # The request's own rules (schema): every instant within the captured_at bounds, one segment at least.
    (
        "end too far ahead",
        edit(0, [("shower", 50), ("breakfast", 4 * 3600 + DAY + 1)]),
        422,
        "invalid_request",
        ["body", "timing", "segments", 1, "ended_at"],
    ),
    ("no segments", edit() | {"segments": []}, 422, "invalid_request", ["body", "timing", "segments"]),
    (
        "durations are derived, not sent",
        edit() | {"active_ms": 1},
        422,
        "invalid_request",
        ["body", "timing", "active_ms"],
    ),
]


@pytest.mark.parametrize(
    ("body", "status", "code", "loc"), [c[1:] for c in INVALID], ids=[c[0] for c in INVALID]
)
async def test_invalid_edits_change_nothing(
    client: httpx.AsyncClient, body: dict[str, Any], status: int, code: str, loc: list[str | int]
) -> None:
    run, entry = await stopped_run(client)
    before = await head()
    problem = await patch(client, entry, {"timing": body}, status=status)
    assert (problem["code"], problem["errors"][0]["loc"]) == (code, loc)
    assert (await client.get(f"/entries/{entry['id']}")).json() == entry
    assert (await run.get())["edited"] is False
    assert await log_rows(before) == []


async def test_the_invariant_guard_answers_422(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``check_timing`` (T1 to T5) checks the rebuilt timing; a broken one is a 422, not a 500."""
    real = run_fold.make_timing

    def broken(*args: Any, **kwargs: Any) -> run_fold.Timing:
        t = real(*args, **kwargs)
        return dataclasses.replace(t, active_ms=t.active_ms + 1)

    monkeypatch.setattr(run_fold, "make_timing", broken)
    _, entry = await stopped_run(client)
    problem = await patch(client, entry, {"timing": edit()}, status=422)
    assert (problem["code"], problem["errors"][0]["loc"]) == ("invalid_request", ["timing"])
    assert "T5" in problem["errors"][0]["message"]


@pytest.mark.parametrize(
    ("extra", "loc"),
    [
        ({"captured_at": at(120)}, ["body", "captured_at"]),
        ({"expected_revision": None}, ["body", "expected_revision"]),
        ({"timing": None}, ["body", "timing"]),
    ],
    ids=["with captured_at", "without expected_revision", "timing null"],
)
async def test_request_rules(client: httpx.AsyncClient, extra: dict[str, Any], loc: list[str]) -> None:
    _, entry = await stopped_run(client)
    problem = await patch(client, entry, {"timing": edit(), **extra}, status=422)
    assert (problem["code"], problem["errors"][0]["loc"]) == ("invalid_request", loc)
    assert (await client.get(f"/entries/{entry['id']}")).json() == entry


async def test_stale_revision(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    problem = await patch(
        client, {**entry, "revision": entry["revision"] + 1}, {"timing": edit()}, status=409
    )
    assert problem["code"] == "stale_revision"


async def test_an_untimed_entry_has_no_times_to_edit(client: httpx.AsyncClient) -> None:
    topic = await timed(client)
    r = await client.post(
        f"/topics/{topic['id']}/entries", json={"answers": {}}
    )  # untimed, though the topic is timed
    entry = r.json()
    assert entry["timing"] is None
    problem = await patch(client, entry, {"timing": edit(0, [(None, 10)])}, status=422)
    assert (problem["code"], problem["errors"][0]["loc"]) == ("invalid_request", ["timing"])


# --- T10: captured_at on a timed entry --------------------------------------------------------------


async def test_captured_at_without_timing_on_a_timed_entry(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    before = await head()
    r = await client.patch(f"/entries/{entry['id']}", json={"captured_at": at(200), "notes": "and this"})
    assert r.status_code == 422, r.text
    assert (r.json()["code"], r.json()["errors"][0]["loc"]) == ("invalid_request", ["captured_at"])
    assert (await client.get(f"/entries/{entry['id']}")).json() == entry
    assert await log_rows(before) == []

    # An untimed entry's captured_at is still its own.
    plain = (await client.post(f"/topics/{entry['topic_id']}/entries", json={"answers": {}})).json()
    r = await client.patch(f"/entries/{plain['id']}", json={"captured_at": at(200)})
    assert (r.status_code, r.json()["captured_at"]) == (200, "2026-10-23T08:03:20Z")


# --- T16, last clause: an edited run ignores later events without refolding -------------------------


async def test_late_events_after_an_edit_are_void(client: httpx.AsyncClient) -> None:
    run, entry = await stopped_run(client)
    edited = await patch(client, entry, {"timing": edit()})
    frozen_run = await run.get()
    before = await head()

    for kind, seconds, fields in [
        ("next", 10, {"seg": 0}),  # before the stop: would merge into an unedited run
        ("lap", 90, {"seg": 1}),
        ("pause", 95, {}),
        ("stop", 130, {}),
        ("discard", 140, {}),
    ]:
        late = await run.tap(kind, seconds, **fields)
        assert late["event"]["reason"] == "run_edited", kind
        assert late["entry"] == edited  # no refold, no revision bump
        assert late["run"]["state"]["segments"] == frozen_run["state"]["segments"]
    assert await log_rows(before) == []

    # Answers aren't times: a finish, and a stop with answers, still land; the edited times stay.
    finished = await run.tap("finish", 150, answers={"note": "kept"})
    assert finished["event"]["effect"] == "applied"
    stop_answers = await run.tap("stop", 160, answers={"note": "again"})
    assert stop_answers["event"]["effect"] == "applied"
    assert stop_answers["entry"]["answers"] == [{"key": "note", "type": "str", "value": "again"}]
    assert stop_answers["entry"]["timing"] == edited["timing"]
    assert stop_answers["entry"]["revision"] == edited["revision"] + 2


async def test_a_second_edit_replaces_the_first(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    first = await patch(client, entry, {"timing": edit()})
    second = await patch(client, first, {"timing": edit(0, [("shower", 20), ("breakfast", 70)])})
    assert (second["captured_at"], second["timing"]["active_ms"]) == ("2026-10-23T08:01:10Z", 70_000)


async def test_late_stop_with_answers_before_the_start_still_lands(client: httpx.AsyncClient) -> None:
    """An edited run decides a stop's effect before its time is checked: answers aren't times."""
    run, entry = await stopped_run(client)
    edited = await patch(client, entry, {"timing": edit(30, [("shower", 50), ("breakfast", 120)])})
    late = await run.tap("stop", -5, answers={"note": "from the other phone"})
    assert late["event"]["effect"] == "applied"
    assert late["entry"]["answers"] == [{"key": "note", "type": "str", "value": "from the other phone"}]
    assert late["entry"]["timing"] == edited["timing"]


# --- boundaries -------------------------------------------------------------------------------------


async def test_the_runs_version_decides_the_steps(client: httpx.AsyncClient) -> None:
    """A publish after the run doesn't change which step keys its edit may use."""
    run = Driver(client, await timed(client, steps=STEPS, questions=OPTIONAL))
    await run.start()
    r = await client.post(
        f"/topics/{run.topic['id']}/versions",
        json={
            "questions": OPTIONAL,
            "base_version": 1,
            "timer": {"steps": [{"key": "coffee", "label": "Coffee"}]},
        },
    )
    assert r.status_code == 201, r.text
    entry = (await run.tap("stop", 100))["entry"]
    problem = await patch(client, entry, {"timing": edit(0, [("coffee", 100)])}, status=422)
    assert problem["errors"][0]["loc"] == ["timing", "segments", 0, "step"]
    edited = await patch(client, entry, {"timing": edit(0, [("shower", 40), ("breakfast", 100)])})
    assert edited["timing"]["complete"] is True


async def test_exactly_seven_days_is_allowed(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    week = edit(-7 * DAY + 100, [("shower", 0), ("breakfast", 100)])
    edited = await patch(client, entry, {"timing": week})
    assert edited["timing"]["active_ms"] == run_fold.MAX_RUN_MS
    over = edit(-7 * DAY + 99.999, [("shower", 0), ("breakfast", 100)])
    problem = await patch(client, edited, {"timing": over}, status=422)
    assert problem["code"] == "run_too_long"


async def test_a_pause_may_end_at_the_runs_end(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    edited = await patch(client, entry, {"timing": edit(pauses=[(100, 120)])})
    assert edited["timing"]["segments"][-1]["paused_ms"] == 20_000
    assert edited["timing"]["active_ms"] == 100_000


async def test_laps_may_come_before_steps(client: httpx.AsyncClient) -> None:
    _, entry = await stopped_run(client)
    edited = await patch(
        client, entry, {"timing": edit(0, [(None, 10), ("shower", 60), (None, 70), ("breakfast", 100)])}
    )
    assert [s["label"] for s in edited["timing"]["segments"]] == ["Lap 1", "Shower", "Lap 2", "Breakfast"]
    assert edited["timing"]["complete"] is True
