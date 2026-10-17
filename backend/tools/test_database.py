"""The test database: which one this checkout uses, and creating and dropping them.

``QUICKR_TEST_DATABASE_URL`` wins when set (CI sets it). Otherwise the main checkout
uses ``quickr_test`` and a git worktree ``quickr_test_<worktree directory>``, so
worktrees running their suites at the same time never truncate each other's tables.
conftest.py and ``make check-migrations`` both resolve it here::

    python -m tools.test_database url         # print this checkout's URL
    python -m tools.test_database ensure      # create it if missing, print the URL
    python -m tools.test_database reset       # drop it (the next test run recreates it)
    python -m tools.test_database prune-peers # drop leftover *_peer_* databases

``reset`` is the fix for a test database migrated before a migration was edited in place
(e.g. an old ``deleted_ids`` key). ``prune-peers`` removes peer databases a killed run
left behind; one still in use by a running suite is skipped, not force-dropped.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path

from sqlalchemy import make_url, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine

SERVER_URL = "postgresql+asyncpg://quickr:quickr@localhost:5433"
BASE_NAME = "quickr_test"
MAX_NAME_BYTES = 63  # Postgres silently truncates longer identifiers
PEER_SUFFIX = "_peer_"


def bounded(name: str, limit: int = MAX_NAME_BYTES) -> str:
    """``name`` if it fits in ``limit`` bytes, else a prefix plus a short hash of the whole."""
    if len(name.encode()) <= limit:
        return name
    digest = hashlib.sha256(name.encode()).hexdigest()[:8]
    return f"{name.encode()[: limit - 9].decode(errors='ignore')}_{digest}"


def _worktree() -> str | None:
    """This checkout's directory name if it is a linked git worktree, else None."""
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
    return None if git_dir == common_dir else Path(toplevel).name


def default_name() -> str:
    worktree = _worktree()
    if worktree is None:
        return BASE_NAME
    slug = re.sub(r"[^a-z0-9]+", "_", worktree.lower()).strip("_")
    return bounded(f"{BASE_NAME}_{slug}") if slug else BASE_NAME


def url() -> str:
    return os.environ.get("QUICKR_TEST_DATABASE_URL") or f"{SERVER_URL}/{default_name()}"


def peer_url(base_url: str) -> str:
    """A fresh, unique database name next to ``base_url``'s, for one fixture to own."""
    base = make_url(base_url)
    stem = bounded(base.database or BASE_NAME, MAX_NAME_BYTES - len(PEER_SUFFIX) - 8)
    return base.set(database=f"{stem}{PEER_SUFFIX}{secrets.token_hex(4)}").render_as_string(
        hide_password=False
    )


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
    """Create the database unless it exists (not race-free: for the checkout's own database)."""
    name = make_url(url).database or ""
    if not await _admin(url, "SELECT 1 FROM pg_database WHERE datname = :name", name=name):
        await create(url)


async def create(url: str) -> None:
    """Create the database; fails if it exists."""
    await _admin(url, f"CREATE DATABASE {_quoted(url)}")


async def drop(url: str, *, force: bool = True) -> None:
    """Drop the database if it exists (``force``: disconnecting its sessions)."""
    await _admin(url, f"DROP DATABASE IF EXISTS {_quoted(url)}{' WITH (FORCE)' if force else ''}")


async def prune_peers(url: str) -> list[str]:
    """Drop every peer database that nobody is connected to; returns the dropped names."""
    pattern = f"^{BASE_NAME}.*{PEER_SUFFIX}[0-9a-f]{{8}}$"
    names = await _admin(url, "SELECT datname FROM pg_database WHERE datname ~ :p ORDER BY 1", p=pattern)
    dropped = []
    for name in names:
        try:
            await drop(make_url(url).set(database=name).render_as_string(hide_password=False), force=False)
        except DBAPIError as exc:  # in use by a running suite
            print(f"skipped {name}: {exc}", file=sys.stderr)
            continue
        dropped.append(name)
    return dropped


def main(argv: list[str]) -> int:
    command = argv[0] if argv else "url"
    target = url()
    if command == "url":
        print(target)
    elif command == "ensure":
        asyncio.run(ensure(target))
        print(target)
    elif command == "reset":
        asyncio.run(drop(target))
        print(f"dropped {make_url(target).database}")
    elif command == "prune-peers":
        for name in asyncio.run(prune_peers(target)):
            print(f"dropped {name}")
    else:
        print(f"usage: python -m tools.test_database [url|ensure|reset|prune-peers], not {command!r}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
