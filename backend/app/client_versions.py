"""Client API levels and forced updates (docs/specs/client-versions.md).

The server speaks one API level and accepts, per platform, clients at or above a minimum.
Both come from ``api_level.json``, a generated copy of ``shared/api-level.json``
(``make api-level``; the image can't read ``shared/``). The minimum can be raised, never
lowered, by ``QUICKR_MIN_CLIENT_LEVEL_IOS`` / ``QUICKR_MIN_CLIENT_LEVEL_WEB``, clamped to
the API level (§2).

Every ``/api/v1`` response carries the levels (:func:`response_headers`, added by
``IdentityHeadersMiddleware``). :class:`ClientVersionMiddleware` refuses a client below its
platform's minimum with 426 ``client_outdated`` before the route runs, so a refused request
has no effect (§3.3). A client is recognised by ``X-QuickR-Client: <platform>; level=<int>;
build=<string>``, or as a level-0 build from before this mechanism by ``X-QuickR-Channel``
(``ios`` or ``ui``) alone. A request with neither (curl, scripts, tests) is not checked, and
neither are ``OPTIONS``, ``/health`` and ``getClientVersions``.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Mapping
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Literal

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.datastructures import Headers
from starlette.types import ASGIApp, Receive, Scope, Send

from app.config import Settings, get_settings
from app.schemas.api import ClientOutdatedProblem

log = logging.getLogger(__name__)

API_LEVEL_FILE = Path(__file__).with_name("api_level.json")
CLIENT_HEADER = "X-QuickR-Client"
CHANNEL_HEADER = "X-QuickR-Channel"
API_LEVEL_HEADER = "X-QuickR-Api-Level"
MIN_CLIENT_LEVEL_HEADER = "X-QuickR-Min-Client-Level"

type Platform = Literal["ios", "web"]
PLATFORMS: tuple[Platform, ...] = ("ios", "web")
# A pre-CV build is known by its channel alone (§3.3).
_CHANNEL_PLATFORMS: dict[str, Platform] = {"ios": "ios", "ui": "web"}

OUTDATED_STATUS = 426
OUTDATED_DETAIL = (
    "This version of quickR is too old for the server. Update it from TestFlight (or reload the "
    "web app) to keep syncing. Nothing on this device has been lost."
)


def _load(path: Path) -> tuple[int, dict[Platform, int]]:
    data = json.loads(path.read_text())
    api_level = data["api_level"]
    minimums = {platform: data["min_client_level"][platform] for platform in PLATFORMS}
    if not all(type(v) is int and v >= 0 for v in (api_level, *minimums.values())):
        raise ValueError(f"{path.name}: levels must be non-negative integers")
    if any(v > api_level for v in minimums.values()):
        raise ValueError(f"{path.name}: min_client_level must be at most api_level")
    return api_level, minimums


API_LEVEL, MIN_CLIENT_LEVEL = _load(API_LEVEL_FILE)


@dataclass(frozen=True, slots=True)
class Levels:
    """What this server speaks and accepts, with the environment's overrides applied."""

    api_level: int
    min_client_level: Mapping[Platform, int]
    ios_update_url: str

    def minimum(self, platform: Platform | None) -> int:
        """The minimum for ``platform``; the strictest one when the platform is unknown."""
        if platform is None:
            return max(self.min_client_level.values())
        return self.min_client_level[platform]

    def headers(self) -> list[tuple[bytes, bytes]]:
        """The level response headers, raw (§3.2)."""
        minimums = ", ".join(f"{p}={self.min_client_level[p]}" for p in PLATFORMS)
        return [
            (API_LEVEL_HEADER.lower().encode(), str(self.api_level).encode()),
            (MIN_CLIENT_LEVEL_HEADER.lower().encode(), minimums.encode()),
        ]


def resolve(settings: Settings) -> Levels:
    """The levels from the built-in file and ``settings``' overrides, which may only raise a
    minimum (a lower one is ignored) and are clamped to the API level; both with a warning."""
    minimums = dict(MIN_CLIENT_LEVEL)
    overrides: dict[Platform, int | None] = {
        "ios": settings.min_client_level_ios,
        "web": settings.min_client_level_web,
    }
    for platform, override in overrides.items():
        if override is None:
            continue
        name = f"QUICKR_MIN_CLIENT_LEVEL_{platform.upper()}"
        if override < minimums[platform]:
            log.warning("%s=%d is below the built-in minimum %d; ignored", name, override, minimums[platform])
        elif override > API_LEVEL:
            log.warning(
                "%s=%d is above the API level %d, which no client could meet; using %d",
                name,
                override,
                API_LEVEL,
                API_LEVEL,
            )
            minimums[platform] = API_LEVEL
        else:
            minimums[platform] = override
    return Levels(api_level=API_LEVEL, min_client_level=minimums, ios_update_url=settings.ios_update_url)


@cache
def current() -> Levels:
    """The server's levels (the environment is read once)."""
    return resolve(get_settings())


def response_headers() -> list[tuple[bytes, bytes]]:
    return current().headers()


# --- the client ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Client:
    """Who sent a request: the platform (None when it can't be told) and the level it speaks."""

    platform: Platform | None
    level: int
    build: str | None = None


def parse_client(value: str) -> Client:
    """``X-QuickR-Client``: ``<platform>; level=<int>; build=<string>``. A malformed header is
    level 0, with its platform when that much is readable."""
    head, *params = (part.strip() for part in value.split(";"))
    platform: Platform | None = "ios" if head == "ios" else "web" if head == "web" else None
    fields: dict[str, str] = {}
    for param in params:
        key, _, val = param.partition("=")
        fields[key.strip()] = val.strip()
    level_text = fields.get("level", "")
    level = int(level_text) if level_text.isascii() and level_text.isdigit() else None
    if platform is None or level is None:
        return Client(platform=platform, level=0)
    return Client(platform=platform, level=level, build=fields.get("build") or None)


def request_client(headers: Mapping[str, str]) -> Client | None:
    """The client a request comes from (§3.3), or None when it isn't one of ours (not checked)."""
    channel_platform = _CHANNEL_PLATFORMS.get(headers.get(CHANNEL_HEADER, ""))
    if (raw := headers.get(CLIENT_HEADER)) is not None:
        client = parse_client(raw)
        if client.platform is None and channel_platform is not None:
            return Client(platform=channel_platform, level=client.level)
        return client
    if channel_platform is not None:
        return Client(platform=channel_platform, level=0)
    return None


def client_level(request: Request) -> int:
    """The request's client level, to store with a push token: 0 without ``X-QuickR-Client``."""
    client = request_client(request.headers)
    return 0 if client is None else client.level


# --- enforcement ----------------------------------------------------------------------------


def _under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


class ClientVersionMiddleware:
    """Refuses a client below its platform's minimum with 426 ``client_outdated``, before the
    route runs, so nothing is read or written. Reads are refused too (§3.3).

    Registered inside ``IdentityHeadersMiddleware``, so the 426 carries the identity, server
    time and level headers like any other response. A client above the server's level is never
    refused: the clients only warn about it.
    """

    def __init__(self, app: ASGIApp, prefix: str = "/api/v1") -> None:
        self.app = app
        self.prefix = prefix
        self.exempt = frozenset({f"{prefix}/health", f"{prefix}/client-versions"})

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] != "http"
            or scope["method"] == "OPTIONS"
            or not _under(scope["path"], self.prefix)
            or scope["path"] in self.exempt
        ):
            await self.app(scope, receive, send)
            return
        client = request_client(Headers(scope=scope))
        minimum = 0 if client is None else current().minimum(client.platform)
        if client is None or client.level >= minimum:
            await self.app(scope, receive, send)
            return
        log.info(
            "refused %s %s: %s client at level %d (build %s), below the minimum %d",
            scope["method"],
            scope["path"],
            client.platform or "an unknown",
            client.level,
            client.build or "unknown",
            minimum,
        )
        body = ClientOutdatedProblem(
            code="client_outdated",
            detail=OUTDATED_DETAIL,
            min_client_level=minimum,
            client_level=client.level,
        )
        response = JSONResponse(
            status_code=OUTDATED_STATUS,
            content=body.model_dump(mode="json"),
            media_type="application/problem+json",
        )
        await response(scope, receive, send)
