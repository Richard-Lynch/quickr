"""Web Push: VAPID keys, browser subscriptions, and delivery.

VAPID keys come from ``QUICKR_VAPID_PRIVATE_KEY`` / ``QUICKR_VAPID_PUBLIC_KEY``
when set. Otherwise a key pair is generated on first use and stored in
``app_settings`` so every restart (and replica) signs with the same key --
rotating it would silently invalidate every browser subscription.

``deliver`` is the only function that talks to push services. It is blocking
(pywebpush uses requests) and is run in a worker thread.
"""

from __future__ import annotations

import asyncio
import base64
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from py_vapid import Vapid
from pywebpush import WebPushException, webpush
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import AppSetting, PushSubscription
from app.push_guard import PushEndpointRejected, check_endpoint, ensure_public
from app.schemas.api import PushPayload, PushSubscriptionIn, PushSubscriptionOut
from app.services.feed import writer
from app.services.push.base import Notification, PushFailed, PushGone

PRIVATE_KEY_SETTING = "vapid_private_key"
PUBLIC_KEY_SETTING = "vapid_public_key"
SEND_TIMEOUT_SECONDS = 10


@dataclass(frozen=True, slots=True)
class VapidKeys:
    private_key: str  # base64url raw private value (what pywebpush/py_vapid accept)
    public_key: str  # base64url uncompressed point (the browser's applicationServerKey)


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _public_from_private(private_key: str) -> str:
    key: ec.EllipticCurvePrivateKey = Vapid.from_string(private_key).private_key
    point = key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    return _b64url(point)


def generate_vapid_keys() -> VapidKeys:
    key = ec.generate_private_key(ec.SECP256R1())
    private = _b64url(key.private_numbers().private_value.to_bytes(32, "big"))
    return VapidKeys(private_key=private, public_key=_public_from_private(private))


async def get_vapid_keys(db: AsyncSession) -> VapidKeys:
    keys = await _ensure_vapid_keys(db)
    await db.commit()
    return keys


async def _ensure_vapid_keys(db: AsyncSession) -> VapidKeys:
    """The keys, generating and storing them on first use, in the caller's transaction."""
    settings = get_settings()
    if settings.vapid_private_key:
        return VapidKeys(
            private_key=settings.vapid_private_key,
            public_key=settings.vapid_public_key or _public_from_private(settings.vapid_private_key),
        )
    stored = await _stored_keys(db)
    if stored is None:
        fresh = generate_vapid_keys()
        # Concurrent first use (e.g. two replicas): first writer wins, everyone re-reads.
        await db.execute(
            insert(AppSetting)
            .values(
                [
                    {"key": PRIVATE_KEY_SETTING, "value": fresh.private_key},
                    {"key": PUBLIC_KEY_SETTING, "value": fresh.public_key},
                ]
            )
            .on_conflict_do_nothing(index_elements=["key"])
        )
        stored = await _stored_keys(db)
        assert stored is not None
    return stored


async def _stored_keys(db: AsyncSession) -> VapidKeys | None:
    result = await db.execute(
        select(AppSetting.key, AppSetting.value).where(
            AppSetting.key.in_([PRIVATE_KEY_SETTING, PUBLIC_KEY_SETTING])
        )
    )
    rows: dict[str, str] = {row.key: row.value for row in result}
    if PRIVATE_KEY_SETTING not in rows:
        return None
    private = rows[PRIVATE_KEY_SETTING]
    return VapidKeys(
        private_key=private, public_key=rows.get(PUBLIC_KEY_SETTING) or _public_from_private(private)
    )


# --- subscriptions -----------------------------------------------------------


def _out(sub: PushSubscription) -> PushSubscriptionOut:
    return PushSubscriptionOut(id=sub.id, endpoint=sub.endpoint, created_at=sub.created_at)


@writer  # the feed lock: the request's identity preconditions are checked under it
async def subscribe(db: AsyncSession, body: PushSubscriptionIn) -> PushSubscriptionOut:
    """Create or refresh (by endpoint) a subscription."""
    values = {"p256dh": body.keys.p256dh, "auth": body.keys.auth, "user_agent": body.user_agent}
    stmt = (
        insert(PushSubscription)
        .values(endpoint=body.endpoint, **values)
        .on_conflict_do_update(index_elements=["endpoint"], set_={**values, "failure_count": 0})
        .returning(PushSubscription)
        .execution_options(populate_existing=True)
    )
    sub = (await db.execute(stmt)).scalar_one()
    return _out(sub)


@writer
async def unsubscribe(db: AsyncSession, endpoint: str) -> None:
    """Remove a subscription. Unknown endpoints are ignored (idempotent)."""
    await db.execute(delete(PushSubscription).where(PushSubscription.endpoint == endpoint))


# --- delivery ----------------------------------------------------------------


class _NoRedirectSession(requests.Session):
    """A session that never follows redirects (a 3xx is a delivery failure)."""

    def request(self, *args: Any, **kwargs: Any) -> requests.Response:
        kwargs["allow_redirects"] = False
        return super().request(*args, **kwargs)


def signing_key(private_key: str) -> Vapid:
    """The VAPID signer for `private_key`, accepting any `mailto:` or `https:` subject.

    py_vapid's strict check only allows a bare `https://host` subject, which rejects
    the default `https://github.com/...` URL (RFC 8292 allows any https URI) and made every
    send fail. The subject itself is operator configuration (QUICKR_VAPID_SUBJECT).
    """
    vapid = Vapid.from_string(private_key)
    vapid.conf = {"no-strict": True}
    return vapid


def deliver(
    subscription: dict[str, Any],
    data: str,
    private_key: str | Vapid,
    claims: dict[str, str | int],
    ttl: int,
) -> None:
    """Send one push message (blocking). Raises PushGone or PushFailed.

    The endpoint is re-validated (allowlist + public address) right before
    sending, and redirects are never followed.
    """
    try:
        host = check_endpoint(subscription["endpoint"])
    except PushEndpointRejected as exc:
        raise PushGone(f"endpoint no longer allowed: {exc}") from exc  # will never work: drop it
    try:
        ensure_public(host)
    except PushEndpointRejected as exc:
        raise PushFailed(str(exc)) from exc
    try:
        webpush(
            subscription_info=subscription,
            data=data,
            vapid_private_key=private_key,
            vapid_claims=dict(claims),  # webpush adds aud/exp in place
            timeout=SEND_TIMEOUT_SECONDS,
            ttl=ttl,
            requests_session=_NoRedirectSession(),
        )
    except WebPushException as exc:
        status = getattr(exc.response, "status_code", None)
        if status in (404, 410):
            raise PushGone(str(exc)) from exc
        raise PushFailed(str(exc)) from exc
    except (requests.RequestException, ValueError) as exc:
        raise PushFailed(str(exc)) from exc


def render(n: Notification) -> PushPayload:
    """The Web Push JSON for ``n`` (what the service worker reads)."""
    return PushPayload(title=n.title, body=n.body, url=n.url, tag=n.tag, topic_slug=n.topic_slug)


class WebPushSender:
    """Web Push to every browser subscription, signed with the VAPID key."""

    kind = "web"

    def __init__(self, keys: VapidKeys) -> None:
        self._signer = signing_key(keys.private_key)
        self._claims: dict[str, str | int] = {"sub": get_settings().vapid_subject}

    @classmethod
    async def create(cls, db: AsyncSession) -> WebPushSender:
        """A sender with the VAPID keys (generated on first use, in the caller's transaction)."""
        return cls(await _ensure_vapid_keys(db))

    async def targets(self, db: AsyncSession) -> Sequence[PushSubscription]:
        return (
            (await db.execute(select(PushSubscription).order_by(PushSubscription.created_at))).scalars().all()
        )

    async def send(self, target: PushSubscription, n: Notification, ttl: int) -> None:
        info = {"endpoint": target.endpoint, "keys": {"p256dh": target.p256dh, "auth": target.auth}}
        await asyncio.to_thread(deliver, info, render(n).model_dump_json(), self._signer, self._claims, ttl)
