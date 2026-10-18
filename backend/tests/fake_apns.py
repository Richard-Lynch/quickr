"""A fake APNs: an ``ApnsSender`` over ``httpx.MockTransport`` with a fresh P-256 key."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.services.push.apns import ApnsConfig, ApnsSender, SigningKey

TEAM_ID = "TEAM123456"
KEY_ID = "KEY1234567"
TOPIC = "com.bahumia.quickr"


def new_key() -> tuple[ec.EllipticCurvePrivateKey, str]:
    """A fresh P-256 key and its PEM (what a .p8 file holds)."""
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    return key, pem


def token(n: int) -> str:
    """A well-formed 64-hex-digit device token."""
    return f"{n:064x}"


@dataclass
class Sent:
    host: str
    path: str
    headers: dict[str, str]
    body: dict[str, Any]
    size: int

    @property
    def device(self) -> str:
        return self.path.removeprefix("/3/device/")

    def claims(self, key: ec.EllipticCurvePrivateKey) -> dict[str, Any]:
        """The provider token's claims, verified with the public key."""
        bearer = self.headers["authorization"].removeprefix("bearer ")
        claims: dict[str, Any] = jwt.decode(
            bearer, key.public_key(), algorithms=["ES256"], options={"verify_iat": False}
        )
        return claims


@dataclass
class FakeApns:
    """Records every answered request. ``replies`` maps a device token to the (status, reason)
    replies it gets, in order; the last one repeats. Unknown tokens get 200."""

    key: ec.EllipticCurvePrivateKey
    pem: str
    now: float = 1_800_000_000.0
    sent: list[Sent] = field(default_factory=list)
    replies: dict[str, list[tuple[int, str]]] = field(default_factory=dict)
    raises: dict[str, Exception] = field(default_factory=dict)
    on_send: Callable[[Sent], None] | None = None
    delay: float = 0.0  # seconds each response takes
    # Requests answered (from the first); later ones stall until cancelled or :meth:`allow`.
    # Lets a test cut a tick off at its budget without depending on how fast the machine is.
    quota: int | None = None
    admitted: int = 0  # requests let through the quota
    in_flight: int = 0
    max_in_flight: int = 0
    events: list[str] = field(default_factory=list)
    started: int = 0  # delayed or quota-limited requests started
    _start: asyncio.Event = field(default_factory=asyncio.Event)
    _allowed: asyncio.Event = field(default_factory=asyncio.Event)

    @classmethod
    def create(cls) -> FakeApns:
        key, pem = new_key()
        return cls(key=key, pem=pem)

    async def wait_started(self, n: int = 1) -> None:
        """Until ``n`` delayed requests have started."""
        while self.started < n:
            self._start.clear()
            await self._start.wait()

    def allow(self, more: int | None = None) -> None:
        """Answer ``more`` further requests (None: every request), stalled ones first."""
        self.quota = None if more is None else self.admitted + more
        self._allowed.set()

    def clock(self) -> float:
        return self.now

    def sender(self, sandbox_key: SigningKey | None = None) -> ApnsSender:
        key = SigningKey(key_id=KEY_ID, pem=self.pem)
        config = ApnsConfig(
            team_id=TEAM_ID, topic=TOPIC, keys={"production": key, "sandbox": sandbox_key or key}
        )
        return ApnsSender(config, transport=httpx.MockTransport(self.handle), clock=self.clock)

    async def handle(self, request: httpx.Request) -> httpx.Response:
        device = request.url.path.removeprefix("/3/device/")
        if device in self.raises:
            raise self.raises[device]
        if self.delay or self.quota is not None:
            self.started += 1
            self._start.set()
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
            try:
                while self.quota is not None and self.admitted >= self.quota:
                    self._allowed.clear()
                    await self._allowed.wait()
                self.admitted += 1
                await asyncio.sleep(self.delay)  # a cancelled request is never recorded
            except asyncio.CancelledError:
                self.events.append("request cancelled")
                raise
            finally:
                self.in_flight -= 1
        sent = Sent(
            host=request.url.host,
            path=request.url.path,
            headers=dict(request.headers),
            body=json.loads(request.content),
            size=len(request.content),
        )
        self.sent.append(sent)
        if self.on_send is not None:
            self.on_send(sent)
        replies = self.replies.get(device, [(200, "")])
        status, reason = replies.pop(0) if len(replies) > 1 else replies[0]
        if status == 200:
            return httpx.Response(200, headers={"apns-id": f"apns-{len(self.sent)}"})
        return httpx.Response(status, json={"reason": reason})
