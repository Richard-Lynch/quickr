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
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.db import get_sessionmaker
from app.schemas.base import Problem
from app.services.feed import ExpectedIdentity, FeedIdentity, expected_identity, feed_identity

log = logging.getLogger(__name__)

SERVER_ID_HEADER = "X-QuickR-Server-Id"
EPOCH_HEADER = "X-QuickR-Epoch"


_SERVER_ID_KEY = SERVER_ID_HEADER.lower().encode()
_EPOCH_KEY = EPOCH_HEADER.lower().encode()


async def _identity_headers() -> list[tuple[bytes, bytes]]:
    """The current identity as raw headers; none when it can't be read (database down)."""
    try:
        async with get_sessionmaker()() as db:
            identity = await feed_identity(db)
    except Exception:
        log.exception("could not read the server identity")
        return []
    return [(_SERVER_ID_KEY, identity.server_id.encode()), (_EPOCH_KEY, identity.epoch.encode())]


class IdentityHeadersMiddleware:
    """Adds the identity headers to every response under ``prefix``.

    The identity is read when the response starts, i.e. after the handler has produced
    it (for a streamed response: before its body streams). A rotation during the request
    therefore labels the response with the new epoch, which a client holding the old
    one rejects: a response is never labelled with an epoch older than its data. A
    response that already carries the headers keeps its own (``/changes`` sets them from
    the page's snapshot, so headers and body always agree). The middleware also scopes the
    request's expected identity, so it never leaks into another request.

    Unhandled errors are answered here (500 ``internal_error``) rather than by
    Starlette's outer error middleware, so they carry the headers too. Only a
    failure to read the identity itself (database down) goes out without them.
    """

    def __init__(self, app: ASGIApp, prefix: str = "/api/v1") -> None:
        self.app = app
        self.prefix = prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not scope["path"].startswith(self.prefix):
            await self.app(scope, receive, send)
            return
        started = False

        async def send_with_identity(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                present = {name.lower() for name, _ in headers}
                if not {_SERVER_ID_KEY, _EPOCH_KEY} <= present:
                    headers += [(k, v) for k, v in (await _identity_headers()) if k not in present]
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
