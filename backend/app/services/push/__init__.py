"""Push notifications over every channel: Web Push (browsers) and APNs (the iOS app).

A :class:`~app.services.push.base.Sender` per channel lists its targets and delivers
one :class:`~app.services.push.base.Notification` to one target. :func:`deliver` sends
a notification to a list of ``(sender, target)`` pairs, at most ``MAX_CONCURRENT_SENDS``
at a time and optionally until a deadline, then records the outcomes on the target
rows in memory: no SQL runs, so no row is locked during the network calls, and the
caller flushes once at the end (:func:`send_to_all` does both):

- success: ``last_success_at = now``, ``failure_count = 0``;
- :class:`PushGone` (the push service dropped the target): the target is deleted;
- any other failure: ``failure_count += 1``, and a target that has failed
  ``PRUNE_AFTER_FAILURES`` times in a row with no success for ``PRUNE_AFTER_SILENCE``
  (counting from registration when it never succeeded) is deleted.

A send cut off by the deadline is neither a success nor a failure: it is left out of
the bookkeeping and the delivery is reported incomplete.

Delivery is best-effort per target, with no retry ledger: the scheduler sends a due
slot once, then marks it, so a slot reaches every target that accepted it, at least
once overall (an incomplete delivery or a failed commit leaves the slot unmarked, and
the next tick sends it again; the shared tag collapses the duplicate on the device).
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Sequence
from dataclasses import dataclass
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
    "Delivery",
    "Notification",
    "Pair",
    "PushFailed",
    "PushGone",
    "PushTarget",
    "Sender",
    "VapidKeys",
    "apns_enabled",
    "deliver",
    "generate_vapid_keys",
    "get_vapid_keys",
    "register_device",
    "send_test",
    "send_test_to_device",
    "send_to_all",
    "senders",
    "subscribe",
    "targets",
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


type Pair = tuple[Sender[Any], PushTarget]


@dataclass(frozen=True, slots=True)
class Delivery:
    sent: int
    failed: int
    complete: bool  # False: the deadline cut some sends off (they are not counted)
    # The pairs whose send finished (sent, failed or gone): not cut off.
    finished: tuple[Pair, ...] = ()


async def senders(db: AsyncSession) -> list[Sender[Any]]:
    """Every enabled channel: Web Push always, APNs when configured."""
    enabled: list[Sender[Any]] = [await web.WebPushSender.create(db)]
    if (sender := apns.get_sender()) is not None:
        enabled.append(sender)
    return enabled


async def targets(db: AsyncSession) -> list[Pair]:
    """Every target of every enabled channel, with its sender."""
    return [(sender, target) for sender in await senders(db) for target in await sender.targets(db)]


async def send_to_all(db: AsyncSession, n: Notification, *, ttl: int = DEFAULT_TTL_SECONDS) -> PushTestResult:
    """Send ``n`` to every target of every channel, and flush the bookkeeping.

    The caller owns the transaction.
    """
    delivery = await deliver(db, await targets(db), n, ttl)
    await db.flush()
    return PushTestResult(sent=delivery.sent, failed=delivery.failed)


_CUT_OFF = object()


async def deliver(
    db: AsyncSession, pairs: Sequence[Pair], n: Notification, ttl: int, *, deadline: float | None = None
) -> Delivery:
    """Send ``n`` to each live ``(sender, target)`` concurrently, then record the outcomes.

    ``deadline`` is an event-loop time (``loop.time()``): sends still waiting or in
    flight then are cancelled and left out. Targets already deleted in this session
    (gone or pruned by an earlier delivery) are skipped. The outcomes are applied to the
    ORM rows without flushing.
    """
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_SENDS)
    live = [(sender, target) for sender, target in pairs if target not in db.deleted]
    if live and deadline is not None and asyncio.get_running_loop().time() >= deadline:
        # Already past: a send that never awaits would otherwise finish before the timeout fires.
        log.warning("push of %r: past the deadline, %d sends not started", n.tag, len(live))
        return Delivery(sent=0, failed=0, complete=False)

    async def attempt(sender: Sender[Any], target: PushTarget) -> object:
        budget = asyncio.timeout_at(deadline)
        try:
            async with budget, semaphore:
                await sender.send(target, n, ttl)
        except TimeoutError as exc:
            return _CUT_OFF if budget.expired() else exc
        except Exception as exc:
            return exc
        return None

    outcomes = await asyncio.gather(*(attempt(sender, target) for sender, target in live))
    now = datetime.now(UTC)
    sent = failed = 0
    finished: list[Pair] = []
    for (sender, target), outcome in zip(live, outcomes, strict=True):
        if outcome is _CUT_OFF:
            continue
        finished.append((sender, target))
        if outcome is None:
            target.last_success_at = now
            target.failure_count = 0
            sent += 1
            continue
        failed += 1
        if isinstance(outcome, PushGone):
            log.info("%s push target %s is gone; removing it: %s", sender.kind, target.id, outcome)
            # An ORM delete, not a DELETE statement: an APNs device's Live Activity tokens go
            # with it through apns's after_delete listener.
            await db.delete(target)
            continue
        if isinstance(outcome, PushFailed):
            # The message is safe to log; the chain may not be (URLs hold tokens).
            log.warning("%s push to %s failed: %s", sender.kind, target.id, outcome)
        else:
            assert isinstance(outcome, Exception)
            log.error("%s push to %s failed unexpectedly", sender.kind, target.id, exc_info=outcome)
        target.failure_count += 1
        if _dead(target, now):
            log.info("%s push target %s keeps failing; removing it", sender.kind, target.id)
            await db.delete(target)  # an ORM delete, for the listener (as above)
    cut_off = sum(outcome is _CUT_OFF for outcome in outcomes)
    if cut_off:
        log.warning("push of %r: the deadline cut off %d of %d sends", n.tag, cut_off, len(live))
    return Delivery(sent=sent, failed=failed, complete=not cut_off, finished=tuple(finished))


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
    delivery = await deliver(db, [(sender, device)], TEST_NOTIFICATION, TEST_TTL_SECONDS)
    await db.flush()
    return PushTestResult(sent=delivery.sent, failed=delivery.failed)
