"""Server identity on the wire: response headers and mutation preconditions.

Every ``/api/v1`` response (errors and ``/health`` included) carries
``X-QuickR-Server-Id`` and ``X-QuickR-Epoch``, so a client can tell on any
response that it is still talking to the server, and the database epoch, its
local store belongs to.

Mutating endpoints accept ``X-QuickR-Expect-Server-Id`` / ``X-QuickR-Expect-Epoch``:
when present and different, the request is rejected with 409 ``server_mismatch`` /
``epoch_mismatch`` before anything runs. Absent headers mean no check (PWA, MCP).
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import Depends, Header, Request
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.db import get_sessionmaker
from app.errors import EpochMismatch, ServerMismatch
from app.schemas.base import Problem
from app.services.feed import FeedIdentity, feed_identity

log = logging.getLogger(__name__)

SERVER_ID_HEADER = "X-QuickR-Server-Id"
EPOCH_HEADER = "X-QuickR-Epoch"
_STATE_KEY = "quickr_identity"


async def _load_identity() -> FeedIdentity:
    async with get_sessionmaker()() as db:
        return await feed_identity(db)


class IdentityHeadersMiddleware:
    """Adds the identity headers to every response under ``prefix``.

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
        identity = await _load_identity()
        # The precondition check reads the same values, so headers and checks agree.
        scope.setdefault("state", {})[_STATE_KEY] = identity
        extra = [
            (SERVER_ID_HEADER.lower().encode(), identity.server_id.encode()),
            (EPOCH_HEADER.lower().encode(), identity.epoch.encode()),
        ]

        started = False

        async def send_with_identity(message: Message) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                message = {**message, "headers": [*message.get("headers", []), *extra]}
            await send(message)

        try:
            await self.app(scope, receive, send_with_identity)
        except Exception:
            if started:
                raise
            log.exception("unhandled error in %s %s", scope.get("method"), scope["path"])
            body = Problem(code="internal_error", detail="internal server error")
            response = JSONResponse(status_code=500, content=body.model_dump(mode="json"))
            await response(scope, receive, send_with_identity)


async def check_expected_identity(
    request: Request,
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
    if expect_server_id is None and expect_epoch is None:
        return
    identity: FeedIdentity | None = getattr(request.state, _STATE_KEY, None)
    if identity is None:
        identity = await _load_identity()
    if expect_server_id is not None and expect_server_id != identity.server_id:
        raise ServerMismatch(f"this is server '{identity.server_id}', not '{expect_server_id}'")
    if expect_epoch is not None and expect_epoch != identity.epoch:
        raise EpochMismatch(
            f"the feed epoch is '{identity.epoch}', not '{expect_epoch}'; resync from after=0"
        )


ExpectIdentity = Depends(check_expected_identity)
