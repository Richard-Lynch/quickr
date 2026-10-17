"""Server identity on the wire: response headers and mutation preconditions.

Every ``/api/v1`` response (errors and ``/health`` included) carries
``X-QuickR-Server-Id`` and ``X-QuickR-Epoch``, so a client can tell on any
response that it is still talking to the server, and the database epoch, its
local store belongs to.

Mutating endpoints accept ``X-QuickR-Expect-Server-Id`` / ``X-QuickR-Expect-Epoch``:
when present and different, the request is rejected with 409 ``server_mismatch`` /
``epoch_mismatch`` and nothing is written. The check runs inside the mutation's own
transaction, right after it takes the feed lock (``app.services.feed.writer``), and
epoch rotation takes the same lock, so it can't race a rotation. Absent headers mean
no check (PWA, MCP).
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import Depends, Header
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.db import REQUEST_SESSION_KEY, get_sessionmaker
from app.schemas.base import Problem
from app.services.feed import ExpectedIdentity, FeedIdentity, expected_identity, feed_identity

log = logging.getLogger(__name__)

SERVER_ID_HEADER = "X-QuickR-Server-Id"
EPOCH_HEADER = "X-QuickR-Epoch"


_SERVER_ID_KEY = SERVER_ID_HEADER.lower().encode()
_EPOCH_KEY = EPOCH_HEADER.lower().encode()


# Whether the open transaction has written anything (Postgres assigns an xid on first write).
_WROTE = text("SELECT pg_current_xact_id_if_assigned() IS NOT NULL")
_IN_FAILED_TRANSACTION = "25P02"


async def _discard_unfinished_work(db: AsyncSession, path: str) -> None:
    """End whatever transaction the handler left open, without committing it.

    A finished handler has committed its writes (every writer does), so what's left is
    normally a read. Pending ORM changes or an open transaction that wrote are a handler
    bug: they are rolled back, with a warning, never committed on the handler's behalf.
    """
    unfinished = bool(db.new or db.dirty or db.deleted)
    if not unfinished and db.in_transaction():
        try:
            unfinished = bool(await db.scalar(_WROTE))
        except DBAPIError as exc:
            if getattr(exc.orig, "sqlstate", None) != _IN_FAILED_TRANSACTION:
                raise
            unfinished = True
    if unfinished:
        log.warning("%s left uncommitted changes; rolling them back", path)
    await db.rollback()


async def _identity_headers(db: AsyncSession, path: str) -> list[tuple[bytes, bytes]]:
    """The current identity as raw headers; none when it can't be read (database down)."""
    try:
        await _discard_unfinished_work(db, path)
        identity = await feed_identity(db)
    except Exception as exc:
        # Once per request while the database is down: no traceback, it says nothing new.
        log.warning("could not read the server identity: %s: %s", type(exc).__name__, exc)
        return []
    return [(_SERVER_ID_KEY, identity.server_id.encode()), (_EPOCH_KEY, identity.epoch.encode())]


def _under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


class IdentityHeadersMiddleware:
    """Adds the identity headers to every response under ``prefix``.

    The middleware owns the request's database session: it opens it, hands it to the
    handler (``app.db.get_db``), reads the identity on it, and closes it after the
    response. FastAPI closes a yield dependency only after the response is sent, so a
    separate session here would hold the handler's connection while waiting for a second
    one, and a saturated pool would starve. One session means at most one connection
    per request.

    The identity is read when the response starts, i.e. after the handler has produced
    it (for a streamed response: before its body streams), in a new transaction, so it
    sees every commit the handler's data could have seen. A rotation during the request
    therefore labels the response with the new epoch, which a client holding the old
    one rejects: a response is never labelled with an epoch older than its data. A
    response that already carries the headers keeps its own (``/changes`` and the CSV
    export set them from their snapshot, so headers and body always agree; a streamed
    response that reads the database while streaming must do the same, since this read
    ends the session's transaction). Reading the headers never commits: whatever the
    handler left open is rolled back first (with a warning if it had written). The
    middleware also scopes the request's expected identity, so it never leaks into
    another request.

    Unhandled errors are answered here (500 ``internal_error``) rather than by
    Starlette's outer error middleware, so they carry the headers too. Only a
    failure to read the identity itself (database down) goes out without them.
    """

    def __init__(self, app: ASGIApp, prefix: str = "/api/v1") -> None:
        self.app = app
        self.prefix = prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not _under(scope["path"], self.prefix):
            await self.app(scope, receive, send)
            return
        async with get_sessionmaker()() as db:
            scope[REQUEST_SESSION_KEY] = db
            await self._handle(db, scope, receive, send)

    async def _handle(self, db: AsyncSession, scope: Scope, receive: Receive, send: Send) -> None:
        started = False

        async def send_with_identity(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                present = {name.lower() for name, _ in headers}
                if not {_SERVER_ID_KEY, _EPOCH_KEY} <= present:
                    headers += [
                        (k, v) for k, v in (await _identity_headers(db, scope["path"])) if k not in present
                    ]
                message = {**message, "headers": headers}
                started = True
            await send(message)

        token = expected_identity.set(None)
        try:
            await self.app(scope, receive, send_with_identity)
        except Exception:
            if started:
                raise
            log.exception("unhandled error in %s %s", scope.get("method"), scope["path"])
            try:
                await db.rollback()  # expected after an error, so no warning from the header read
            except Exception as exc:  # database down: the header read will say so
                log.debug("rollback after an unhandled error failed: %s", exc)
            body = Problem(code="internal_error", detail="internal server error")
            response = JSONResponse(status_code=500, content=body.model_dump(mode="json"))
            await response(scope, receive, send_with_identity)
        finally:
            expected_identity.reset(token)


async def expect_identity(
    expect_server_id: Annotated[
        str | None,
        Header(
            alias="X-QuickR-Expect-Server-Id",
            description="Optional: reject with 409 server_mismatch unless this is the server's id.",
        ),
    ] = None,
    expect_epoch: Annotated[
        str | None,
        Header(
            alias="X-QuickR-Expect-Epoch",
            description="Optional: reject with 409 epoch_mismatch unless this is the current feed epoch.",
        ),
    ] = None,
) -> None:
    """Record the request's preconditions; the mutation checks them under the feed lock."""
    if expect_server_id is not None or expect_epoch is not None:
        expected_identity.set(ExpectedIdentity(server_id=expect_server_id, epoch=expect_epoch))


def identity_headers(identity: FeedIdentity) -> dict[str, str]:
    return {SERVER_ID_HEADER: identity.server_id, EPOCH_HEADER: identity.epoch}


ExpectIdentity = Depends(expect_identity)
