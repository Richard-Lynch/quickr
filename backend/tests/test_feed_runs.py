"""Runs in the change feed (docs/specs/timers.md §2.4, §7.1): spec cases T7 and T8 (§13.2).

T8 checks page contents, never just the order of the log rows.
"""

from __future__ import annotations

from typing import Any

import httpx
import pytest

from tests.test_api_runs import NOW, OPTIONAL, REQUIRED, Driver, frozen_clock, head, log_rows, timed
from tests.test_feed import changes, drain


@pytest.fixture(autouse=True)
def _clock(monkeypatch: pytest.MonkeyPatch) -> None:
    frozen_clock(monkeypatch, NOW)


def run_items(page: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {i["run"]["id"]: i for i in page["items"] if i["kind"] == "run"}


def entry_ids(page: dict[str, Any]) -> set[str]:
    return {i["entry"]["id"] for i in page["items"] if i["kind"] == "entry"}


def deleted(page: dict[str, Any], kind: str) -> dict[str, dict[str, Any]]:
    return {d["id"]: d for d in page["deleted"] if d["kind"] == kind}


async def started(client: httpx.AsyncClient, name: str, **topic: Any) -> Driver:
    run = Driver(client, await timed(client, name, **topic))
    await run.start()
    return run


# --- T7 ---------------------------------------------------------------------------------------


async def test_bootstrap_carries_open_and_finishing_runs_only(client: httpx.AsyncClient) -> None:
    running = await started(client, "Running", steps=[{"key": "a", "label": "A"}])
    paused = await started(client, "Paused")
    await paused.tap("pause", 10)
    finishing = await started(client, "Finishing", questions=REQUIRED)
    await finishing.tap("stop", 20)
    stopped = await started(client, "Stopped", questions=OPTIONAL)
    await stopped.tap("stop", 30)
    discarded = await started(client, "Discarded")
    await discarded.tap("discard", 40)

    page = await changes(client)
    items = run_items(page)
    assert set(items) == {running.id, paused.id, finishing.id}
    assert {i["run"]["status"] for i in items.values()} == {"running", "paused", "finishing"}
    assert items[finishing.id]["run"] == await finishing.get()
    assert stopped.id in entry_ids(page)  # a closed run reaches clients as its entry
    # F3: a bootstrap also deletes every closed run ever (accepted for one user, §7.1).
    run_deletions = deleted(page, "run")
    assert set(run_deletions) == {stopped.id, discarded.id}
    assert run_deletions[stopped.id]["topic_id"] == stopped.topic["id"]
    # Runs apply after entries, and their deletions before every other kind.
    assert [i["kind"] for i in page["items"]][-3:] == ["run"] * 3
    assert page["deleted"][0]["kind"] == "run"


async def test_incremental_pages_carry_run_upserts_and_deletions(client: httpx.AsyncClient) -> None:
    topic = await timed(client, "Routine", steps=[{"key": "a", "label": "A"}, {"key": "b", "label": "B"}])
    run = Driver(client, topic)
    cursor = await head()

    await run.start()
    page = await changes(client, cursor)
    assert set(run_items(page)) == {run.id}
    assert not page["deleted"]
    assert run_items(page)[run.id]["run"]["revision"] == 1
    cursor = page["next"]

    await run.tap("next", 60, seg=0)
    page = await changes(client, cursor)
    assert [i["kind"] for i in page["items"]] == ["run"]
    assert run_items(page)[run.id]["run"] == await run.get()
    assert run_items(page)[run.id]["seq"] == page["next"]
    cursor = page["next"]

    await run.tap("stop", 120)
    page = await changes(client, cursor)
    assert entry_ids(page) == {run.id}
    assert not run_items(page)
    deletion = deleted(page, "run")[run.id]
    assert deletion["seq"] == page["next"]  # the delete row, after the entry's
    assert set(deleted(page, "run")) == {run.id}
    assert len(page["deleted"]) == 1

    # A late event changes the entry, never the run item (§2.4).
    cursor = page["next"]
    await run.tap("next", 90, seg=1)
    page = await changes(client, cursor)
    assert entry_ids(page) == {run.id}
    assert not run_items(page)
    assert not page["deleted"]


async def test_a_discarded_run_is_a_deletion_without_an_entry(client: httpx.AsyncClient) -> None:
    run = Driver(client, await timed(client, "Routine"))
    cursor = await head()
    await run.start()
    await run.tap("discard", 30)
    page = await changes(client, cursor)
    assert not page["items"]
    assert set(deleted(page, "run")) == {run.id}


async def test_a_run_deleted_with_its_topic_is_a_deletion(client: httpx.AsyncClient) -> None:
    run = await started(client, "Routine")
    assert (await client.post(f"/topics/{run.topic['id']}/archive")).status_code == 200
    assert (await client.delete(f"/topics/{run.topic['id']}")).status_code == 204
    # The topic delete logs only the topic; its run's own rows, read now, find no row and a
    # tombstone (§2.2).
    page = await changes(client)
    assert not run_items(page)
    assert set(deleted(page, "run")) == {run.id}
    assert set(deleted(page, "topic")) == {run.topic["id"]}


# --- T8 ---------------------------------------------------------------------------------------


async def test_limit_between_a_runs_rows_and_its_delete_row(client: httpx.AsyncClient) -> None:
    """Every limit, every page: a run deletion only with its delete row, and an entry for
    every deleted stopped run on that page or an earlier one."""
    steps = [{"key": "a", "label": "A"}, {"key": "b", "label": "B"}]
    other = await timed(client, "Other", questions=OPTIONAL)
    cursor = await head()
    stopped = await started(client, "Stopped", steps=steps)
    await stopped.tap("next", 10, seg=0)
    await stopped.tap("pause", 20)
    await client.post("/topics/other/entries", json={"answers": {}})  # rows of another kind between
    await stopped.tap("stop", 30)
    discarded = await started(client, "Discarded")
    await discarded.tap("discard", 40)
    late = await started(client, "Late", questions=OPTIONAL)
    await late.tap("stop", 50)
    await late.tap("pause", 45)  # a late event: an entry upsert after the run's delete
    open_run = Driver(client, other)
    await open_run.start(60)

    rows = await log_rows(cursor)
    seqs = range(cursor + 1, cursor + 1 + len(rows))
    run_rows = {seq: (op, eid) for seq, (kind, op, eid) in zip(seqs, rows, strict=True) if kind == "run"}
    delete_seq = {eid: seq for seq, (op, eid) in run_rows.items() if op == "delete"}
    assert set(delete_seq) == {stopped.id, discarded.id, late.id}
    stopped_runs = {stopped.id, late.id}
    assert ("entry", "upsert", late.id) in rows[delete_seq[late.id] - cursor :]

    for limit in range(1, len(rows) + 1):
        seen_entries: set[str] = set()
        all_deletions: list[str] = []
        live: set[str] = set()
        after = cursor
        for page in await drain(client, cursor, limit):
            span = range(after + 1, page["next"] + 1)
            seen_entries |= entry_ids(page)
            for run_id, d in deleted(page, "run").items():
                assert delete_seq[run_id] in span, (limit, run_id, "deletion without its delete row")
                assert d["seq"] == delete_seq[run_id]
                if run_id in stopped_runs:
                    assert run_id in seen_entries, (limit, run_id, "deletion before its entry")
                all_deletions.append(run_id)
            # A closed run is never an item; a page with its rows but not its delete row skips it.
            items = run_items(page)
            assert set(items) <= {open_run.id}, limit
            live |= set(items)
            after = page["next"]
        assert sorted(all_deletions) == sorted(delete_seq), limit
        assert live == {open_run.id}, limit
        assert seen_entries >= stopped_runs, limit
