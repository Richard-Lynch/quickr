"""Push notifications over every channel: Web Push (browsers) and APNs (the iOS app).

A :class:`~app.services.push.base.Sender` per channel lists its targets and delivers
one :class:`~app.services.push.base.Notification` to one target; :func:`send_to_all`
fans a notification out to every target of every enabled channel, at most
``MAX_CONCURRENT_SENDS`` at a time, and then does the bookkeeping in the caller's
transaction:

- success: ``last_success_at = now``, ``failure_count = 0``;
- :class:`PushGone` (the push service dropped the target): the target is deleted;
- any other failure: ``failure_count += 1``, and a target that has failed
  ``PRUNE_AFTER_FAILURES`` times in a row with no success for ``PRUNE_AFTER_SILENCE``
  (counting from registration when it never succeeded) is deleted.

Delivery is best-effort per target, with no retry ledger: the scheduler sends a due
slot once, then marks it, so a slot reaches every target that accepted it, at least
once overall (a failed commit resends it on the next tick; the shared tag collapses
the duplicate on the device).
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ApnsDisabled, NotFound
from app.schemas.api import PushTestResult
from app.services.feed import writer_once
from app.services.push import apns, web
from app.services.push.apns import register_device, unregister_device
from app.services.push.base import (
    DEFAULT_TTL_SECONDS,
    Notification,
    PushFailed,
    PushGone,
    PushTarget,
    Sender,
)
from app.services.push.web import VapidKeys, generate_vapid_keys, get_vapid_keys, subscribe, unsubscribe

__all__ = [
    "DEFAULT_TTL_SECONDS",
    "Notification",
    "PushFailed",
    "PushGone",
    "PushTarget",
    "Sender",
    "VapidKeys",
    "apns_enabled",
    "deliver_to",
    "generate_vapid_keys",
    "get_vapid_keys",
    "register_device",
    "send_test",
    "send_test_to_device",
    "send_to_all",
    "senders",
    "subscribe",
    "unregister_device",
    "unsubscribe",
]

log = logging.getLogger(__name__)

MAX_CONCURRENT_SENDS = 8
PRUNE_AFTER_FAILURES = 20
PRUNE_AFTER_SILENCE = timedelta(days=30)
TEST_TTL_SECONDS = 3600
TEST_NOTIFICATION = Notification(
    kind="test", title="quickR", body="Test notification: push is working.", url="/", tag="test"
)


def apns_enabled() -> bool:
    return apns.get_sender() is not None


async def senders(db: AsyncSession) -> list[Sender[Any]]:
    """Every enabled channel: Web Push always, APNs when configured."""
    enabled: list[Sender[Any]] = [await web.WebPushSender.create(db)]
    if (sender := apns.get_sender()) is not None:
        enabled.append(sender)
    return enabled


async def send_to_all(db: AsyncSession, n: Notification, *, ttl: int = DEFAULT_TTL_SECONDS) -> PushTestResult:
    """Send ``n`` to every target of every channel. See the module docstring.

    Changes are flushed but not committed; the caller owns the transaction.
    """
    pairs = [(sender, target) for sender in await senders(db) for target in await sender.targets(db)]
    return await deliver_to(db, pairs, n, ttl)


async def deliver_to(
    db: AsyncSession, pairs: Sequence[tuple[Sender[Any], PushTarget]], n: Notification, ttl: int
) -> PushTestResult:
    """Send ``n`` to each ``(sender, target)`` concurrently, then record the outcomes (flushed)."""
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_SENDS)

    async def attempt(sender: Sender[Any], target: PushTarget) -> Exception | None:
        async with semaphore:
            try:
                await sender.send(target, n, ttl)
            except Exception as exc:
                return exc
        return None

    errors = await asyncio.gather(*(attempt(sender, target) for sender, target in pairs))
    now = datetime.now(UTC)
    sent = failed = 0
    for (sender, target), error in zip(pairs, errors, strict=True):
        if error is None:
            target.last_success_at = now
            target.failure_count = 0
            sent += 1
            continue
        failed += 1
        if isinstance(error, PushGone):
            log.info("%s push target %s is gone; removing it: %s", sender.kind, target.id, error)
            await db.delete(target)
            continue
        log.warning("%s push to %s failed", sender.kind, target.id, exc_info=error)
        target.failure_count += 1
        if _dead(target, now):
            log.info("%s push target %s keeps failing; removing it", sender.kind, target.id)
            await db.delete(target)
    await db.flush()
    return PushTestResult(sent=sent, failed=failed)


def _dead(target: PushTarget, now: datetime) -> bool:
    last_alive = target.last_success_at or target.created_at
    return target.failure_count >= PRUNE_AFTER_FAILURES and last_alive < now - PRUNE_AFTER_SILENCE


@writer_once
async def send_test(db: AsyncSession) -> PushTestResult:
    """Send a test notification to every target of every channel, all under the feed lock.

    The writer checks the request's preconditions right after taking the lock, so a
    mismatch sends nothing and changes nothing, and no epoch rotation can land between
    the check and the sends: the lock is held through delivery and bookkeeping until the
    commit. Deliveries run ``MAX_CONCURRENT_SENDS`` at a time, so the lock is held for
    about one per-send timeout per batch in the worst case (it scales with the number of
    targets and with network/DNS latency) and blocks every feed writer meanwhile. That
    is acceptable for a manual action on a single-user server. It never retries: a
    failure rolls back the bookkeeping and propagates rather than sending twice.
    """
    return await send_to_all(db, TEST_NOTIFICATION, ttl=TEST_TTL_SECONDS)


@writer_once
async def send_test_to_device(db: AsyncSession, token: str) -> PushTestResult:
    """Send a test notification to one APNs device ("Test this device"), like :func:`send_test`."""
    sender = apns.get_sender()
    if sender is None:
        raise ApnsDisabled("APNs is not configured on this server")
    device = await apns.find_device(db, token)
    if device is None:
        raise NotFound("no APNs device has this token; register it first")
    return await deliver_to(db, [(sender, device)], TEST_NOTIFICATION, TEST_TTL_SECONDS)
