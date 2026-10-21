"""What every push channel shares: the notification, the sender protocol and its outcomes."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Protocol
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.schemas.api import QuickLogDescriptor

# How long a push service keeps an undelivered message (e.g. phone offline).
DEFAULT_TTL_SECONDS = 12 * 3600


class PushGone(Exception):
    """The push service says the target no longer exists: delete it."""


class PushFailed(Exception):
    """Any other delivery failure: count it against the target."""


@dataclass(frozen=True, slots=True, kw_only=True)
class Notification:
    """One notification, before any channel renders it (Web Push JSON, APNs payload).

    ``tag`` identifies what the notification is about (``due-{topic_id}``, ``test``): a
    newer one with the same tag replaces the older on the device (the Web Push tag, the
    APNs collapse id). A due notification also carries what an action needs to log it:
    the server, the topic and its version, the slot (``due_since``) and the ``quick_log``
    descriptor (None when the topic can't be logged from a notification). ``single`` marks a
    topic with no questions, which a Web Push reminder logs with one action. A test
    notification leaves them None. ``web.render`` and ``apns.render`` lay them out.
    """

    kind: Literal["due", "test"]
    title: str
    body: str
    url: str
    tag: str
    topic_slug: str | None = None
    server_id: str | None = None
    topic_id: UUID | None = None
    version: int | None = None
    due_since: datetime | None = None
    quick_log: QuickLogDescriptor | None = None
    single: bool = False


class PushTarget(Protocol):
    """A stored delivery target (a browser subscription, an APNs device)."""

    id: UUID
    created_at: datetime
    last_success_at: datetime | None
    failure_count: int


class Sender[T: PushTarget](Protocol):
    """One push channel. ``send`` talks to the network only, never to the database."""

    kind: str  # "web" | "apns"

    async def targets(self, db: AsyncSession) -> Sequence[T]:
        """Every target of this channel, oldest first."""
        ...

    async def send(self, target: T, n: Notification, ttl: int) -> None:
        """Deliver ``n`` to ``target``. Raises :class:`PushGone` or :class:`PushFailed`."""
        ...
