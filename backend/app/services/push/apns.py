"""APNs: the iOS app's device tokens, and delivery over HTTP/2 with a token-based (.p8) key.

Off unless ``QUICKR_APNS_TEAM_ID``, ``QUICKR_APNS_KEY_ID`` and a key
(``QUICKR_APNS_PRIVATE_KEY`` or ``QUICKR_APNS_PRIVATE_KEY_FILE``) are all set: devices
can still register, but :func:`get_sender` is None and nothing is sent to them.

Each device says which APNs host its token belongs to (``sandbox`` for debug builds,
``production`` for TestFlight and App Store builds). There is one HTTP/2 client per
host, created on first use and closed by :func:`lifespan`. Requests carry an ES256
provider token (JWT) that is cached and re-signed after 50 minutes: Apple rejects
tokens older than an hour and answers ``TooManyProviderTokenUpdates`` to more than
one new token per 20 minutes.

Responses map to the shared outcomes (Apple, "Handling notification responses from
APNs"): 410 and 400 ``BadDeviceToken`` mean the token is gone (deleted; the app
registers again on its next launch, so a token sent with the wrong environment heals
itself). Every other failure counts against the device; the ones that are our bug
(``DeviceTokenNotForTopic``: a topic/key mismatch, never the device's fault; other
400s) are logged as errors. 403 ``ExpiredProviderToken`` re-signs the token, if it is
older than 20 minutes, and retries once.

Device tokens never reach the logs: httpx's request log lines have the token in the
URL redacted (:class:`RedactDeviceTokens`), and transport failures are reported by
exception type and redacted message, without the URL-bearing exception chain.
"""

from __future__ import annotations

import contextlib
import json
import logging
import re
import time
from collections.abc import AsyncIterator, Callable, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.models import ApnsDevice
from app.schemas.api import ApnsDeviceIn, ApnsDeviceOut, ApnsEnvironment
from app.services.feed import writer
from app.services.notification import actions, canonical_instant, category_id, more_suffix, truncate
from app.services.push.base import Notification, PushFailed, PushGone

log = logging.getLogger(__name__)

HOSTS: dict[ApnsEnvironment, str] = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
TOKEN_MAX_AGE_SECONDS = 50 * 60  # re-sign before Apple's 60-minute limit
TOKEN_MIN_REFRESH_SECONDS = 20 * 60  # Apple's TooManyProviderTokenUpdates threshold
MAX_PAYLOAD_BYTES = 4096
MAX_TITLE_LENGTH = 120
RELEVANCE_SCORE = 0.8
TIMEOUT = httpx.Timeout(10, connect=5)

_DEVICE_PATH = re.compile(r"/3/device/[0-9A-Fa-f]+")


def redact(text: str) -> str:
    """``text`` with any APNs device token in a request path replaced."""
    return _DEVICE_PATH.sub("/3/device/<token>", text)


class RedactDeviceTokens(logging.Filter):
    """Redacts device tokens from httpx's ``HTTP Request: POST <url> ...`` lines."""

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        if "/3/device/" in message:
            record.msg, record.args = redact(message), None
        return True


logging.getLogger("httpx").addFilter(RedactDeviceTokens())

type Clock = Callable[[], float]


# --- payload ------------------------------------------------------------------------


def render(n: Notification) -> dict[str, Any]:
    """The APNs JSON body for ``n``: the alert in ``aps``, our fields under ``quickr``.

    docs/ios/specs/notifications.md §2. A due notification is grouped per topic
    (``thread-id``) and, when its topic can be logged from it, has the category of its
    actions, and a body saying so when the actions show only some options. Never a
    ``badge``: the device owns it. ``mutable-content`` lets the app's Notification Service
    Extension register the category and set the badge before display.
    """
    aps: dict[str, Any] = {
        "alert": {"title": truncate(n.title, MAX_TITLE_LENGTH), "body": n.body + more_suffix(n.quick_log)},
        "sound": "default",
    }
    if n.kind == "due" and n.topic_id is not None:
        aps["thread-id"] = f"topic-{n.topic_id}"
    if n.server_id and n.topic_id and n.version is not None and n.quick_log is not None:
        topic_id = str(n.topic_id)
        aps["category"] = category_id(topic_id, actions(n.server_id, topic_id, n.version, n.quick_log))
    aps["mutable-content"] = 1
    aps["relevance-score"] = RELEVANCE_SCORE
    return {
        "aps": aps,
        "quickr": {
            "v": 1,
            "kind": n.kind,
            "server_id": n.server_id,
            "topic_id": str(n.topic_id) if n.topic_id else None,
            "topic_slug": n.topic_slug,
            "version": n.version,
            "due_since": canonical_instant(n.due_since) if n.due_since else None,
            "url": n.url,
            "quick_log": n.quick_log.model_dump(mode="json") if n.quick_log else None,
        },
    }


def encode(n: Notification) -> bytes:
    """The request body. Raises :class:`PushFailed` (our bug) above Apple's 4 KB limit."""
    body = json.dumps(render(n), ensure_ascii=False, separators=(",", ":")).encode()
    if len(body) > MAX_PAYLOAD_BYTES:
        log.error("APNs payload for %r is %d bytes, over the %d limit", n.tag, len(body), MAX_PAYLOAD_BYTES)
        raise PushFailed(f"payload too large ({len(body)} bytes)")
    return body


# --- configuration and the provider token ------------------------------------------


@dataclass(frozen=True, slots=True)
class SigningKey:
    key_id: str
    pem: str


@dataclass(frozen=True, slots=True)
class ApnsConfig:
    team_id: str
    topic: str
    keys: dict[ApnsEnvironment, SigningKey]

    @classmethod
    def from_settings(cls, settings: Settings) -> ApnsConfig | None:
        """The configuration, or None when APNs is off. Raises OSError for an unreadable key file."""
        key = _key(settings.apns_key_id, settings.apns_private_key, settings.apns_private_key_file)
        if not (settings.apns_team_id and key):
            if settings.apns_team_id or settings.apns_key_id or key:
                log.warning("APNs is partly configured (team id, key id and key are all needed); it is off")
            return None
        sandbox_id = settings.apns_sandbox_key_id
        sandbox_pem = settings.apns_sandbox_private_key or settings.apns_sandbox_private_key_file
        if bool(sandbox_id) != bool(sandbox_pem):
            # Never fall back to the default key here: it may be limited to production.
            raise ValueError(
                "the sandbox key override needs both QUICKR_APNS_SANDBOX_KEY_ID and "
                "QUICKR_APNS_SANDBOX_PRIVATE_KEY (or _FILE), or neither"
            )
        sandbox = _key(sandbox_id, settings.apns_sandbox_private_key, settings.apns_sandbox_private_key_file)
        return cls(
            team_id=settings.apns_team_id,
            topic=settings.apns_topic,
            keys={"production": key, "sandbox": sandbox or key},
        )


def _key(key_id: str | None, pem: str | None, path: str | None) -> SigningKey | None:
    if path and not pem:
        pem = Path(path).read_text()
    if not (key_id and pem):
        return None
    return SigningKey(key_id=key_id, pem=pem.replace("\\n", "\n"))


class ProviderToken:
    """The ES256 JWT for one signing key, re-signed after ``TOKEN_MAX_AGE_SECONDS``."""

    def __init__(self, team_id: str, key: SigningKey, clock: Clock = time.time) -> None:
        private = load_pem_private_key(key.pem.encode(), password=None)
        if not (isinstance(private, ec.EllipticCurvePrivateKey) and isinstance(private.curve, ec.SECP256R1)):
            raise ValueError(f"APNs key {key.key_id} is not a P-256 (.p8) key")
        self._private = private
        self._team_id = team_id
        self._key_id = key.key_id
        self._clock = clock
        self._token = ""
        self._issued_at = 0

    def get(self) -> str:
        if not self._token or self._clock() - self._issued_at >= TOKEN_MAX_AGE_SECONDS:
            self._sign()
        return self._token

    def renew(self, rejected: str) -> bool:
        """After Apple rejected ``rejected`` as expired: whether a retry can use a newer token.

        True when another request already re-signed it, or when it is old enough to re-sign
        without tripping ``TooManyProviderTokenUpdates``.
        """
        if rejected != self._token:
            return True
        if self._clock() - self._issued_at < TOKEN_MIN_REFRESH_SECONDS:
            return False
        self._sign()
        return True

    def _sign(self) -> None:
        self._issued_at = int(self._clock())
        self._token = jwt.encode(
            {"iss": self._team_id, "iat": self._issued_at},
            self._private,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )


# --- delivery -------------------------------------------------------------------------


def _reason(response: httpx.Response) -> str:
    try:
        reason = response.json().get("reason")
    except ValueError, AttributeError:
        reason = None
    return reason if isinstance(reason, str) else ""


class ApnsSender:
    """APNs to every registered device, each on its own environment's host."""

    kind = "apns"

    def __init__(
        self,
        config: ApnsConfig,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        clock: Clock = time.time,
    ) -> None:
        self.topic = config.topic
        by_key_id: dict[str, ProviderToken] = {}
        self._tokens: dict[ApnsEnvironment, ProviderToken] = {}
        for environment, key in config.keys.items():
            if key.key_id not in by_key_id:
                by_key_id[key.key_id] = ProviderToken(config.team_id, key, clock)
            self._tokens[environment] = by_key_id[key.key_id]
        self._transport = transport
        self._clock = clock
        self._clients: dict[ApnsEnvironment, httpx.AsyncClient] = {}
        self._closed = False

    def _client(self, environment: ApnsEnvironment) -> httpx.AsyncClient:
        if self._closed:
            raise PushFailed("the APNs sender is closed (shutting down)")
        if environment not in self._clients:
            self._clients[environment] = httpx.AsyncClient(
                base_url=HOSTS[environment],
                http2=True,
                timeout=TIMEOUT,
                follow_redirects=False,
                transport=self._transport,
            )
        return self._clients[environment]

    async def aclose(self) -> None:
        """Close the connections. The sender can't send (or reconnect) afterwards."""
        self._closed = True
        clients, self._clients = list(self._clients.values()), {}
        for client in clients:
            await client.aclose()

    async def targets(self, db: AsyncSession) -> Sequence[ApnsDevice]:
        return (await db.execute(select(ApnsDevice).order_by(ApnsDevice.created_at))).scalars().all()

    async def send(self, target: ApnsDevice, n: Notification, ttl: int) -> None:
        environment: ApnsEnvironment = "sandbox" if target.environment == "sandbox" else "production"
        await self.post(target.token, environment, n, ttl)

    async def post(self, token: str, environment: ApnsEnvironment, n: Notification, ttl: int) -> str:
        """Send ``n`` to one device token. Returns Apple's ``apns-id``.

        Raises :class:`PushGone` or :class:`PushFailed`.
        """
        headers = {
            "apns-topic": self.topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(int(self._clock()) + ttl),
            "apns-collapse-id": n.tag,
        }
        return await self._request(token, environment, encode(n), headers, n.tag)

    def now(self) -> int:
        """The sender's clock, in whole Unix seconds (a Live Activity payload's ``timestamp``)."""
        return int(self._clock())

    async def post_live_activity(
        self, token: str, environment: ApnsEnvironment, body: bytes, *, expiration: int, what: str
    ) -> str:
        """Send a Live Activity payload (``push/live_activity.py``) to one activity or
        push-to-start token: push type ``liveactivity`` on the ``<bundle>.push-type.liveactivity``
        topic (Apple, "Starting and updating Live Activities with ActivityKit push notifications").
        Returns Apple's ``apns-id``. Raises :class:`PushGone` or :class:`PushFailed`.
        """
        headers = {
            "apns-topic": f"{self.topic}.push-type.liveactivity",
            "apns-push-type": "liveactivity",
            "apns-priority": "10",
            "apns-expiration": str(expiration),
        }
        return await self._request(token, environment, body, headers, what)

    async def _request(
        self, token: str, environment: ApnsEnvironment, body: bytes, headers: dict[str, str], what: str
    ) -> str:
        provider = self._tokens[environment]
        for attempt in (1, 2):
            jwt_token = provider.get()
            try:
                response = await self._client(environment).post(
                    f"/3/device/{token}",
                    content=body,
                    headers={**headers, "authorization": f"bearer {jwt_token}"},
                )
            except httpx.HTTPError as exc:
                # No chain: httpx errors can carry the request URL, which holds the token.
                raise PushFailed(f"APNs {environment} {type(exc).__name__}: {redact(str(exc))}") from None
            if response.status_code == 200:
                apns_id = str(response.headers.get("apns-id", ""))
                log.info("APNs %s accepted %s (apns-id %s)", environment, what, apns_id)
                return apns_id
            reason = _reason(response)
            if (
                attempt == 1
                and response.status_code == 403
                and reason == "ExpiredProviderToken"
                and provider.renew(jwt_token)
            ):
                continue
            raise _failure(response.status_code, reason, environment)
        raise AssertionError("unreachable")


def _failure(status: int, reason: str, environment: ApnsEnvironment) -> PushGone | PushFailed:
    what = f"APNs {environment} {status} {reason or '(no reason)'}"
    if status == 410 or (status == 400 and reason == "BadDeviceToken"):
        return PushGone(what)
    if reason == "DeviceTokenNotForTopic":
        log.error("%s: QUICKR_APNS_TOPIC does not match the app's bundle id", what)
    elif status in (400, 404, 405, 413):
        log.error("%s: the request is malformed (a server bug)", what)
    return PushFailed(what)


class _Holder:
    """The process-wide sender (it caches the provider tokens and the connections)."""

    loaded = False
    sender: ApnsSender | None = None


def _load() -> ApnsSender | None:
    try:
        config = ApnsConfig.from_settings(get_settings())
        return ApnsSender(config) if config else None
    except (OSError, ValueError, TypeError) as exc:
        log.error("APNs is configured but its key can't be loaded, so it is off: %s", exc)
        return None


def get_sender() -> ApnsSender | None:
    """The configured sender, or None when APNs is off (configuration is read once)."""
    if not _Holder.loaded:
        _Holder.loaded = True
        _Holder.sender = _load()
    return _Holder.sender


@asynccontextmanager
async def lifespan(_app: Any) -> AsyncIterator[None]:
    """App lifespan: close the APNs connections on shutdown.

    Enter it before the scheduler's lifespan, so the scheduler (which sends) has stopped
    before the connections close. After shutdown, :func:`get_sender` is None: nothing
    can reopen a connection. A new lifespan reads the configuration again.
    """
    _Holder.loaded, _Holder.sender = False, None
    try:
        yield
    finally:
        await _shut_down()


async def _shut_down() -> None:
    sender, _Holder.sender, _Holder.loaded = _Holder.sender, None, True
    if sender is not None:
        with contextlib.suppress(Exception):
            await sender.aclose()


# --- devices ----------------------------------------------------------------------------


def _out(device: ApnsDevice) -> ApnsDeviceOut:
    return ApnsDeviceOut.model_validate(device, from_attributes=True)


@writer
async def register_device(db: AsyncSession, body: ApnsDeviceIn) -> ApnsDeviceOut:
    """Create or refresh (by token) a device, resetting its failure count."""
    values = body.model_dump(exclude={"token"})
    stmt = (
        insert(ApnsDevice)
        .values(token=body.token, **values)
        .on_conflict_do_update(
            index_elements=["token"], set_={**values, "failure_count": 0, "updated_at": func.now()}
        )
        .returning(ApnsDevice)
        .execution_options(populate_existing=True)
    )
    return _out((await db.execute(stmt)).scalar_one())


@writer
async def unregister_device(db: AsyncSession, token: str) -> None:
    """Remove a device. Unknown tokens are ignored (idempotent)."""
    await db.execute(delete(ApnsDevice).where(ApnsDevice.token == token))


async def find_device(db: AsyncSession, token: str) -> ApnsDevice | None:
    return (await db.execute(select(ApnsDevice).where(ApnsDevice.token == token))).scalar_one_or_none()
