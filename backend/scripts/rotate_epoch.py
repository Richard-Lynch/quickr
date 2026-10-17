"""Start a new change-feed epoch.

Run after restoring a backup or resetting the database: every client sees the new
epoch on its next sync and rebuilds its copy of the server data from scratch
(keeping any changes it has not sent yet).
"""

from __future__ import annotations

import asyncio

from app.db import get_engine, get_sessionmaker
from app.services.feed import feed_identity, rotate_epoch


async def main() -> None:
    async with get_sessionmaker()() as db:
        old = (await feed_identity(db)).epoch
        new = await rotate_epoch(db)
    await get_engine().dispose()
    print(f"feed epoch rotated: {old} -> {new}")


if __name__ == "__main__":
    asyncio.run(main())
