"""Runs in the change feed (docs/specs/timers.md §2.4, §7.1; timers2.md §5.1, §5.2, §5.4): spec
cases T7 and T8 (timers.md §13.2) as updated by T27 (timers2.md §12.2).

T8 checks page contents, never just the order of the log rows. A page emits a run by its state in
the page's snapshot (current state at read time): its latest row on the page decides whether it is
on the page, its current row decides as what. A ``run`` deletion carries the run's ``revision`` in
that snapshot, or null when the row is gone (topic cascade); every other kind carries null.
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
    # T27: bootstrap deletions carry the run's revision in the snapshot (timers2.md §5.4).
    assert run_deletions[stopped.id]["revision"] == (await stopped.get())["revision"]
    assert run_deletions[discarded.id]["revision"] == (await discarded.get())["revision"]
    # Runs apply after entries (deletion order: test_a_run_deleted_with_its_topic_is_a_deletion).
    assert [i["kind"] for i in page["items"]][-3:] == ["run"] * 3


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
    assert deletion["revision"] == (await run.get())["revision"] == 3  # start, next, stop

    # A late event changes the entry, never the run item (§2.4).
    cursor = page["next"]
    await run.tap("next", 90, seg=1)
    page = await changes(client, cursor)
    assert entry_ids(page) == {run.id}
    assert not run_items(page)
    assert not page["deleted"]


async def test_incremental_pages_carry_a_finishing_run(client: httpx.AsyncClient) -> None:
    run = await started(client, "Routine", questions=REQUIRED)
    cursor = await head()

    await run.tap("stop", 60)
    page = await changes(client, cursor)
    assert [i["kind"] for i in page["items"]] == ["run"]
    assert run_items(page)[run.id]["run"]["status"] == "finishing"
    assert not page["deleted"]
    cursor = page["next"]

    await run.tap("finish", 70, answers={"mood": 5})
    page = await changes(client, cursor)
    assert entry_ids(page) == {run.id}
    assert not run_items(page)
    assert set(deleted(page, "run")) == {run.id}
    assert len(page["deleted"]) == 1


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
    r = await client.post(f"/topics/{run.topic['id']}/entries", json={"answers": {}})
    assert r.status_code == 201, r.text
    assert (await client.post(f"/topics/{run.topic['id']}/archive")).status_code == 200
    assert (await client.delete(f"/topics/{run.topic['id']}")).status_code == 204
    # The topic delete logs only the topic; its run's own rows, read now, find no row and a
    # tombstone (§2.2).
    page = await changes(client)
    assert not run_items(page)
    assert set(deleted(page, "run")) == {run.id}
    assert set(deleted(page, "topic")) == {run.topic["id"]}
    # Deletions apply children first: runs, then entries, versions and the topic.
    assert [d["kind"] for d in page["deleted"]] == ["run", "entry", "version", "topic"]
    # T27: the cascade run deletion has no row to read a revision from; other kinds never carry one.
    assert [d["revision"] for d in page["deleted"]] == [None] * 4


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


# --- T27: reopen, revision and the page cuts (timers2.md §5.1, §5.2) ------------------------------


class Client:
    """A feed consumer applying timers2.md §5.2's revision rules to runs: an item applies iff its
    revision is above the local row's or marker's; a deletion against a row applies iff its revision
    is above the row's, and against a marker only raises it."""

    def __init__(self) -> None:
        self.live: dict[str, int] = {}
        self.closed: dict[str, int] = {}

    def apply(self, page: dict[str, Any]) -> None:
        for run_id, item in run_items(page).items():
            rev = item["run"]["revision"]
            if rev > self.live.get(run_id, self.closed.get(run_id, -1)):
                self.live[run_id] = rev
                self.closed.pop(run_id, None)
        for run_id, d in deleted(page, "run").items():
            rev = d["revision"]
            assert isinstance(rev, int), d
            if run_id in self.live:
                if rev > self.live[run_id]:
                    del self.live[run_id]
                    self.closed[run_id] = rev
            else:
                self.closed[run_id] = max(self.closed.get(run_id, -1), rev)


async def stop_reopen(client: httpx.AsyncClient, name: str) -> tuple[Driver, int]:
    """A run started and stopped once before the returned cursor, then stopped again after it
    (``(entry, upsert)``, ``(run, delete)``) and reopened (``(run, upsert)``)."""
    run = await started(client, name, questions=OPTIONAL)
    await run.tap("lap", 10, seg=0)
    cursor = await head()
    stop = (await run.tap("stop", 20))["event"]["id"]
    reopened = await run.tap("reopen", 30, target=stop)
    assert reopened["run"]["status"] == "running"
    return run, cursor


async def every_cut(client: httpx.AsyncClient, cursor: int) -> list[tuple[int, list[dict[str, Any]]]]:
    """``(start, pages)`` for every start cursor in the span since ``cursor`` and every limit."""
    end = await head()
    return [
        (start, await drain(client, start, limit))
        for start in range(cursor, end)
        for limit in range(1, end - start + 1)
    ]


def spans(start: int, pages: list[dict[str, Any]]) -> list[tuple[int, dict[str, Any]]]:
    """Each page with the cursor it was fetched after."""
    out = []
    for page in pages:
        out.append((start, page))
        start = page["next"]
    return out


async def test_a_stop_reopen_restop_within_one_page_is_one_deletion(client: httpx.AsyncClient) -> None:
    run, cursor = await stop_reopen(client, "Once")
    await run.tap("stop", 40)
    page = await changes(client, cursor)
    assert not run_items(page)
    [deletion] = page["deleted"]
    assert (deletion["kind"], deletion["id"]) == ("run", run.id)
    assert deletion["revision"] == (await run.get())["revision"]
    assert deletion["seq"] == page["next"]  # the re-stop's delete row, after the entry's
    assert entry_ids(page) == {run.id}


async def test_an_incremental_page_after_a_reopen_carries_the_run_again(client: httpx.AsyncClient) -> None:
    run, _ = await stop_reopen(client, "Resurrected")
    page = await changes(client, await head() - 1)  # just the reopen's upsert
    item = run_items(page)[run.id]
    assert item["run"] == await run.get()
    assert item["run"]["status"] == "running"
    assert not page["deleted"]


async def test_stop_reopen_restop_split_every_way_converges(client: httpx.AsyncClient) -> None:
    """§5.1's first cut: the run is closed at read time, so no page emits it as an item; a page
    emits its deletion exactly when the page's latest row for it is a delete row (so the middle
    page of stop | reopen | re-stop emits nothing for it), and every page sequence converges."""
    run, cursor = await stop_reopen(client, "Every way")
    await run.tap("lap", 35, seg=1)
    await run.tap("stop", 40)
    rows = await log_rows(cursor)
    assert [r[:2] for r in rows] == [
        ("entry", "upsert"),
        ("run", "delete"),
        ("run", "upsert"),
        ("run", "upsert"),
        ("entry", "upsert"),
        ("run", "delete"),
    ]
    final = await run.get()
    assert final["status"] == "stopped"
    middles = 0
    for start, pages in await every_cut(client, cursor):
        model = Client()
        for after, page in spans(start, pages):
            model.apply(page)
            latest = latest_op(rows, cursor, after, page["next"], run.id)
            assert run.id not in run_items(page), (start, after, "a closed run is never an item")
            if latest == "delete":
                assert deleted(page, "run")[run.id]["revision"] == final["revision"], (start, after)
            else:
                assert run.id not in deleted(page, "run"), (start, after, latest)
                middles += latest == "upsert"
        assert run.id not in model.live, start
        assert model.closed.get(run.id) == final["revision"], start
    assert middles  # some cut yields a page whose latest row for the run is the reopen's upsert


async def test_stop_reopen_split_with_the_run_open_emits_the_item(client: httpx.AsyncClient) -> None:
    """§5.1's second cut: the run is open again at read time, so a page whose latest row for it is
    the stop's delete row emits the item at its current revision, never a deletion."""
    run, cursor = await stop_reopen(client, "Open again")
    rows = await log_rows(cursor)
    assert [r[:2] for r in rows] == [("entry", "upsert"), ("run", "delete"), ("run", "upsert")]
    current = await run.get()
    deletes_first = 0
    for start, pages in await every_cut(client, cursor):
        model = Client()
        for after, page in spans(start, pages):
            model.apply(page)
            latest = latest_op(rows, cursor, after, page["next"], run.id)
            assert run.id not in deleted(page, "run"), (start, after)
            if latest is None:
                assert run.id not in run_items(page), (start, after)
            else:
                assert run_items(page)[run.id]["run"] == current, (start, after)
                deletes_first += latest == "delete"
        assert model.live == {run.id: current["revision"]}, start
    assert deletes_first  # the cut between the stop's delete row and the reopen's upsert


async def test_an_upsert_row_of_a_run_discarded_since_emits_nothing(client: httpx.AsyncClient) -> None:
    """A reopened run whose entry was deleted is discarded by its revert (issue #183): a page whose
    latest row for it is the reopen's upsert emits nothing; the next page, with the discard's delete
    row, emits the deletion with its revision."""
    run, cursor = await stop_reopen(client, "Reverted")
    upsert = await head()
    assert (await client.delete(f"/entries/{run.id}")).status_code == 204
    assert (await run.tap("discard", 40))["run"]["status"] == "discarded"
    revision = (await run.get())["revision"]
    page = await changes(client, cursor, upsert - cursor)
    assert page["next"] == upsert
    assert not run_items(page)
    assert run.id not in deleted(page, "run")
    page = await changes(client, upsert)
    assert deleted(page, "run")[run.id]["revision"] == revision


async def test_a_bootstrap_carries_a_reopened_run_as_an_item(client: httpx.AsyncClient) -> None:
    run, _ = await stop_reopen(client, "Bootstrap open")
    closed, _ = await stop_reopen(client, "Bootstrap closed")
    await closed.tap("stop", 40)
    pages = await drain(client, 0, 3)
    model = Client()
    for page in pages:
        model.apply(page)
    assert model.live.get(run.id) == (await run.get())["revision"]
    assert model.closed.get(closed.id) == (await closed.get())["revision"]


def latest_op(
    rows: list[tuple[str, str, str]], cursor: int, after: int, upto: int, run_id: str
) -> str | None:
    """The run's latest op among the log rows with ``after < seq <= upto`` (``rows`` start after
    ``cursor``)."""
    op = None
    for seq, (kind, row_op, eid) in enumerate(rows, cursor + 1):
        if kind == "run" and eid == run_id and after < seq <= upto:
            op = row_op
    return op
