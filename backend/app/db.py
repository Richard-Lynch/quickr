from collections.abc import AsyncIterator
from functools import lru_cache

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from app.config import get_settings

# Where IdentityHeadersMiddleware puts the request's session (app.api.identity).
REQUEST_SESSION_KEY = "quickr.db"


@lru_cache
def get_engine() -> AsyncEngine:
    settings = get_settings()
    return create_async_engine(settings.database_url, echo=settings.db_echo, pool_pre_ping=True)


@lru_cache
def get_sessionmaker() -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(get_engine(), expire_on_commit=False)


async def get_db(request: Request) -> AsyncIterator[AsyncSession]:
    """The request's session.

    Under ``/api/v1`` the identity middleware opens it, reads the response's identity
    headers on it, and closes it, so a request never holds two pooled connections.
    """
    session = request.scope.get(REQUEST_SESSION_KEY)
    if session is not None:
        yield session
        return
    async with get_sessionmaker()() as session:
        yield session


async def read_snapshot(db: AsyncSession) -> None:
    """Run the rest of this read in one REPEATABLE READ snapshot, so rows read by separate
    queries always agree even when a write commits between them. End it with a rollback."""
    await db.rollback()  # whatever the session had open; the snapshot starts with the next statement
    await db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
