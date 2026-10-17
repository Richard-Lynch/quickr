"""The test database: which one this checkout uses, and creating and dropping them.

``QUICKR_TEST_DATABASE_URL`` wins when set (CI sets it). Otherwise the main checkout
uses ``quickr_test`` and a git worktree ``quickr_test_<worktree directory>_<hash>`` (the
hash of its path tells apart worktrees whose names sanitize alike), so worktrees running
their suites at the same time never truncate each other's tables. conftest.py and
``make check-migrations`` both resolve it here::

    python -m tools.test_database url          # print this checkout's URL
    python -m tools.test_database ensure       # create it if missing, print the URL
    python -m tools.test_database reset        # drop it (the next test run recreates it)
    python -m tools.test_database prune-peers  # drop this checkout's leftover peer databases
        [--all] [--min-age SECONDS]            #   (--all: every checkout's)

``reset`` is the fix for a test database migrated before a migration was edited in place
(e.g. an old ``deleted_ids`` key). Peer databases (``<base>_peer_<epoch>_<random>``) are
created and dropped by one fixture each; ``prune-peers`` removes ones a killed run left
behind: it is for crashed runs. It only considers ``quickr_test*_peer_<epoch>_<hex>`` names,
skips any still in use (never force-dropped) and any younger than ``--min-age`` (default an
hour, at least 10 minutes), since a fresh peer may belong to a running suite that hasn't
connected to it yet. A run that keeps a peer unconnected for longer than that is the
accepted residual risk: there is no liveness protocol beyond the age and the connections.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

from sqlalchemy import make_url, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

SERVER_URL = "postgresql+asyncpg://quickr:quickr@localhost:5433"
BASE_NAME = "quickr_test"
MAX_NAME_BYTES = 63  # Postgres silently truncates longer identifiers
# Only names like this are ever pruned: nothing outside quickr_test*.
PEER = re.compile(r"^(?P<stem>quickr_test.*)_peer_(?P<epoch>\d{10})_[0-9a-f]{8}$")
PEER_SUFFIX_BYTES = len("_peer_") + 10 + 1 + 8
# Room for a whole base name inside a peer name.
MAX_BASE_BYTES = MAX_NAME_BYTES - PEER_SUFFIX_BYTES
# Serialises check-then-create in ensure() (on the maintenance database, so server-wide).
CREATE_LOCK_ID = 0x716B7203
DEFAULT_MIN_AGE_SECONDS = 3600
MIN_AGE_FLOOR_SECONDS = 600


def _hash8(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:8]


def bounded(name: str, limit: int = MAX_NAME_BYTES) -> str:
    """``name`` if it fits in ``limit`` bytes, else a prefix plus a short hash of the whole."""
    if len(name.encode()) <= limit:
        return name
    return f"{name.encode()[: limit - 9].decode(errors='ignore')}_{_hash8(name)}"


def _worktree() -> Path | None:
    """This checkout's top-level directory if it is a linked git worktree, else None."""
    here = Path(__file__).resolve().parent
    try:
        out = subprocess.run(
            [
                "git",
                "rev-parse",
                "--path-format=absolute",
                "--git-dir",
                "--git-common-dir",
                "--show-toplevel",
            ],
            cwd=here,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split("\n")
    except OSError, subprocess.CalledProcessError:
        return None  # no git (e.g. a container): the default database
    git_dir, common_dir, toplevel = out[:3]
    return None if git_dir == common_dir else Path(toplevel).resolve()


def database_name(worktree: Path | None) -> str:
    """``quickr_test`` for the main checkout, else ``quickr_test_<slug>_<path hash>``, short
    enough to fit whole in a peer database name."""
    if worktree is None:
        return BASE_NAME
    room = MAX_BASE_BYTES - len(BASE_NAME) - 2 - 8  # two underscores and the hash
    slug = re.sub(r"[^a-z0-9]+", "_", worktree.name.lower()).strip("_")[:room].strip("_")
    return "_".join(part for part in (BASE_NAME, slug, _hash8(str(worktree))) if part)


def url() -> str:
    return os.environ.get("QUICKR_TEST_DATABASE_URL") or f"{SERVER_URL}/{database_name(_worktree())}"


def _peer_stem(base_url: str) -> str:
    return bounded(make_url(base_url).database or BASE_NAME, MAX_BASE_BYTES)


def peer_url(base_url: str, *, now: float | None = None) -> str:
    """A fresh, unique database name next to ``base_url``'s, for one fixture to own."""
    epoch = int(time.time() if now is None else now)
    name = f"{_peer_stem(base_url)}_peer_{epoch:010d}_{secrets.token_hex(4)}"
    return make_url(base_url).set(database=name).render_as_string(hide_password=False)


async def _admin(url: str, sql: str, **params: str) -> list[str]:
    """Run ``sql`` on the server's ``postgres`` database; returns its first column's values."""
    admin = create_async_engine(make_url(url).set(database="postgres"), isolation_level="AUTOCOMMIT")
    try:
        async with admin.connect() as conn:
            result = await conn.execute(text(sql), params)
            return [str(row[0]) for row in result] if result.returns_rows else []
    finally:
        await admin.dispose()


def _quoted(url: str) -> str:
    name = make_url(url).database or ""
    return '"' + name.replace('"', '""') + '"'


async def ensure(url: str) -> None:
    """Create the database unless it exists. Safe when several runs start at once."""
    admin = create_async_engine(make_url(url).set(database="postgres"), isolation_level="AUTOCOMMIT")
    try:
        async with admin.connect() as conn:
            await conn.execute(text("SELECT pg_advisory_lock(:id)"), {"id": CREATE_LOCK_ID})
            try:
                exists = await conn.scalar(
                    text("SELECT 1 FROM pg_database WHERE datname = :name"), {"name": make_url(url).database}
                )
                if not exists:
                    await conn.execute(text(f"CREATE DATABASE {_quoted(url)}"))
            finally:
                await conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": CREATE_LOCK_ID})
    finally:
        await admin.dispose()


async def create(url: str) -> None:
    """Create the database; fails if it exists."""
    await _admin(url, f"CREATE DATABASE {_quoted(url)}")


async def drop(url: str, *, force: bool = True) -> None:
    """Drop the database if it exists (``force``: disconnecting its sessions)."""
    await _admin(url, f"DROP DATABASE IF EXISTS {_quoted(url)}{' WITH (FORCE)' if force else ''}")


def stale_peers(
    names: list[str], base_url: str, *, every_checkout: bool, min_age: float, now: float
) -> list[str]:
    """The peer databases among ``names`` to prune: ``base_url``'s (or ``every_checkout``'s)
    created at least ``min_age`` seconds before ``now``."""
    stem = _peer_stem(base_url)
    stale = []
    for name in names:
        match = PEER.match(name)
        if match is None or not (every_checkout or match["stem"] == stem):
            continue
        if now - int(match["epoch"]) >= min_age:
            stale.append(name)
    return stale


async def prune_peers(
    url: str, *, every_checkout: bool = False, min_age: float = DEFAULT_MIN_AGE_SECONDS
) -> list[str]:
    """Drop the stale peer databases nobody is connected to; returns the dropped names."""
    if min_age < MIN_AGE_FLOOR_SECONDS:
        raise ValueError(f"min_age must be at least {MIN_AGE_FLOOR_SECONDS} s, not {min_age:g}")
    names = await _admin(
        url, "SELECT datname FROM pg_database WHERE datname LIKE 'quickr\\_test%\\_peer\\_%'"
    )
    dropped = []
    for name in stale_peers(names, url, every_checkout=every_checkout, min_age=min_age, now=time.time()):
        try:
            await drop(make_url(url).set(database=name).render_as_string(hide_password=False), force=False)
        except DBAPIError as exc:  # in use by a running suite
            print(f"skipped {name}: {exc}", file=sys.stderr)
            continue
        dropped.append(name)
    return dropped


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="python -m tools.test_database")
    parser.add_argument(
        "command", nargs="?", default="url", choices=["url", "ensure", "reset", "prune-peers"]
    )
    parser.add_argument("--all", action="store_true", help="prune-peers: every checkout's peers")
    parser.add_argument("--min-age", type=float, default=DEFAULT_MIN_AGE_SECONDS, metavar="SECONDS")
    args = parser.parse_args(argv)
    if args.min_age < MIN_AGE_FLOOR_SECONDS:
        parser.error(
            f"--min-age must be at least {MIN_AGE_FLOOR_SECONDS} seconds (pruning is for crashed runs)"
        )
    target = url()
    if args.command == "url":
        print(target)
    elif args.command == "ensure":
        asyncio.run(ensure(target))
        print(target)
    elif args.command == "reset":
        asyncio.run(drop(target))
        print(f"dropped {make_url(target).database}")
    else:
        for name in asyncio.run(prune_peers(target, every_checkout=args.all, min_age=args.min_age)):
            print(f"dropped {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
