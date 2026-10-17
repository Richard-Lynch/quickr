"""tools.test_database: per-checkout names, peer names and pruning, concurrent creation."""

from __future__ import annotations

import asyncio
import threading
from pathlib import Path

from sqlalchemy import make_url

from tools import test_database as tdb


def test_main_checkout_uses_quickr_test() -> None:
    assert tdb.database_name(None) == "quickr_test"


def test_worktree_names_differ_even_when_they_sanitize_alike() -> None:
    paths = [Path("/w/feature-a"), Path("/w/feature_a"), Path("/w/FEATURE-A"), Path("/x/feature-a")]
    names = [tdb.database_name(p) for p in paths]
    assert len(set(names)) == len(paths)
    assert all(n.startswith("quickr_test_feature_a_") for n in names)
    # Nothing left to sanitize: still the path hash, never the main checkout's database.
    assert tdb.database_name(Path("/w/!!!")) not in ("quickr_test", tdb.database_name(Path("/v/!!!")))


def test_names_fit_whole_in_a_peer_name() -> None:
    base = tdb.database_name(Path("/w/" + "very-long-worktree-name-" * 5))
    assert len(base.encode()) <= tdb.MAX_BASE_BYTES
    peer = make_url(tdb.peer_url(f"{tdb.SERVER_URL}/{base}")).database or ""
    assert len(peer.encode()) <= tdb.MAX_NAME_BYTES
    assert peer.startswith(f"{base}_peer_")
    long_override = make_url(tdb.peer_url(f"{tdb.SERVER_URL}/{'x' * 63}")).database or ""
    assert len(long_override.encode()) <= tdb.MAX_NAME_BYTES


def test_prune_takes_only_old_peers_of_this_checkout_unless_all() -> None:
    now = 2_000_000_000.0
    mine, other = f"{tdb.SERVER_URL}/quickr_test_a_11111111", f"{tdb.SERVER_URL}/quickr_test_b_22222222"

    def name(url: str, age: float) -> str:
        return make_url(tdb.peer_url(url, now=now - age)).database or ""

    old_mine, new_mine, old_other = name(mine, 7200), name(mine, 60), name(other, 7200)
    names = [old_mine, new_mine, old_other, "quickr_test_a_11111111", "quickr", "x_peer_123_abc"]
    assert tdb.stale_peers(names, mine, every_checkout=False, min_age=3600, now=now) == [old_mine]
    assert tdb.stale_peers(names, mine, every_checkout=True, min_age=3600, now=now) == [old_mine, old_other]
    assert tdb.stale_peers(names, mine, every_checkout=False, min_age=0, now=now) == [old_mine, new_mine]


async def _exists(url: str) -> bool:
    name = make_url(url).database or ""
    rows = await tdb._admin(url, "SELECT 1 FROM pg_database WHERE datname = :name", name=name)
    return bool(rows)


async def test_concurrent_ensure_creates_once(migrated_db: str) -> None:
    """Two runs starting at once both find (or make) the database; neither fails."""
    url = tdb.peer_url(migrated_db)  # a fresh name nobody else uses
    barrier = threading.Barrier(2)
    errors: list[BaseException] = []

    def run() -> None:
        try:
            barrier.wait(5)
            asyncio.run(tdb.ensure(url))
        except BaseException as exc:
            errors.append(exc)

    threads = [threading.Thread(target=run) for _ in range(2)]
    try:
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        assert errors == []
        assert await _exists(url)
    finally:
        await tdb.drop(url)
    assert not await _exists(url)


async def test_a_fresh_peer_with_no_connections_survives_prune(migrated_db: str) -> None:
    url = tdb.peer_url(migrated_db)
    await tdb.create(url)
    try:
        assert make_url(url).database not in await tdb.prune_peers(migrated_db)
        assert await _exists(url)
    finally:
        await tdb.drop(url)
