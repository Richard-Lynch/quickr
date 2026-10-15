"""Web Push: VAPID keys, subscriptions, and delivery.

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
import logging
from dataclasses import dataclass
from datetime import UTC, datetime
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
from app.schemas.api import PushPayload, PushSubscriptionIn, PushSubscriptionOut, PushTestResult

log = logging.getLogger(__name__)

PRIVATE_KEY_SETTING = "vapid_private_key"
PUBLIC_KEY_SETTING = "vapid_public_key"
SEND_TIMEOUT_SECONDS = 10
# How long a push service keeps an undelivered message (e.g. phone offline).
DEFAULT_TTL_SECONDS = 12 * 3600


@dataclass(frozen=True, slots=True)
class VapidKeys:
    private_key: str  # base64url raw private value (what pywebpush/py_vapid accept)
    public_key: str  # base64url uncompressed point (the browser's applicationServerKey)


class PushGone(Exception):
    """The push service says the subscription no longer exists (404/410)."""


class PushFailed(Exception):
    """Any other delivery failure."""


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
        await db.commit()
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
    await db.commit()
    return _out(sub)


async def unsubscribe(db: AsyncSession, endpoint: str) -> None:
    """Remove a subscription. Unknown endpoints are ignored (idempotent)."""
    await db.execute(delete(PushSubscription).where(PushSubscription.endpoint == endpoint))
    await db.commit()


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


async def send_to_all(
    db: AsyncSession, payload: PushPayload, *, ttl: int = DEFAULT_TTL_SECONDS
) -> PushTestResult:
    """Send ``payload`` to every subscription. Gone subscriptions are deleted.

    Changes are flushed but not committed; the caller owns the transaction.
    """
    keys = await get_vapid_keys(db)
    claims: dict[str, str | int] = {"sub": get_settings().vapid_subject}
    signer = signing_key(keys.private_key)
    data = payload.model_dump_json()
    sent = failed = 0
    subs = (await db.execute(select(PushSubscription).order_by(PushSubscription.created_at))).scalars().all()
    for sub in subs:
        info = {"endpoint": sub.endpoint, "keys": {"p256dh": sub.p256dh, "auth": sub.auth}}
        try:
            await asyncio.to_thread(deliver, info, data, signer, claims, ttl)
        except PushGone:
            log.info("push subscription %s is gone; removing it", sub.id)
            await db.delete(sub)
            failed += 1
        except Exception:
            log.warning("push to subscription %s failed", sub.id, exc_info=True)
            sub.failure_count += 1
            failed += 1
        else:
            sub.last_success_at = datetime.now(UTC)
            sub.failure_count = 0
            sent += 1
    await db.flush()
    return PushTestResult(sent=sent, failed=failed)


async def send_test(db: AsyncSession) -> PushTestResult:
    payload = PushPayload(
        title="quickR",
        body="Test notification: push is working.",
        url="/",
        tag="test",
        topic_slug=None,
    )
    result = await send_to_all(db, payload, ttl=3600)
    await db.commit()
    return result
