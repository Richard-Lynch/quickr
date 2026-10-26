"""Send a topic's real reminder now, as the scheduler would (manual testing of notifications).

    uv run python scripts/send_reminder.py <slug or id> [--due-since ISO]
        [--channel apns|webpush|all] [--dry-run]

The notification is built and delivered by the scheduler's own code (``scheduler.reminder``,
``prepare_quick_logs``, ``push.deliver``), so its payload, category and actions (a log
topic's quick actions, a timed topic's Start) are those of a scheduled reminder. It is a
test send only: the topic's slot is not marked (``last_notified_due_since``), no slot
progress is recorded, and the topic's due state doesn't change.

``--due-since`` (default: now, to the second) is the reminder's slot. The action entry id,
which a timed topic's Start also uses as its run id, derives from it: give each test a
new one to act on the same reminder again. Delivery runs under the feed lock, like the
test push (``push.send_test``), and its outcomes are recorded on the targets as usual.
``--dry-run`` prints the rendered payloads and sends nothing.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_engine, get_sessionmaker
from app.errors import NotFound
from app.services import push as push_svc
from app.services.feed import feed_identity, writer_once
from app.services.notification import action_entry_id, actions, canonical_instant, category_id
from app.services.push import apns, web
from app.services.push.base import Notification
from app.services.schedule import due_message, parse_schedule
from app.services.scheduler import prepare_quick_logs, reminder, version_questions
from app.services.topics import resolve_topic

# --channel -> the senders' kinds, in delivery order.
CHANNELS = {"apns": ["apns"], "webpush": ["web"], "all": ["apns", "web"]}


@dataclass(frozen=True, slots=True)
class ChannelResult:
    kind: str
    targets: int
    sent: int
    failed: int


def parse_instant(text: str) -> datetime:
    """An ISO 8601 instant with a timezone (``Z`` or an offset), truncated to the second."""
    at = datetime.fromisoformat(text)
    if at.tzinfo is None:
        raise argparse.ArgumentTypeError(f"{text!r} has no timezone: add Z or an offset")
    return at.astimezone(UTC).replace(microsecond=0)


async def build(db: AsyncSession, ref: str, due_since: datetime, now: datetime) -> Notification:
    """The reminder the scheduler would send for ``ref``'s current version and this slot."""
    server_id = (await feed_identity(db)).server_id
    topic = await resolve_topic(db, ref)
    questions, timed = await version_questions(db, [(topic.id, topic.current_version)])
    quick_log = (await prepare_quick_logs(db, questions, timed=timed)).get(topic.id)
    schedule = parse_schedule(topic.schedule)
    n = reminder(
        server_id=server_id,
        topic_id=topic.id,
        slug=topic.slug,
        name=topic.name,
        version=topic.current_version,
        due_since=due_since,
        message=due_message(schedule, due_since, now) if schedule else "Time to log",
        quick_log=quick_log,
    )
    await db.rollback()  # reads only: leave the session idle for the writer
    return n


@writer_once
async def send(db: AsyncSession, n: Notification, kinds: list[str]) -> list[ChannelResult]:
    """Deliver ``n`` to every target of the ``kinds`` channels, under the feed lock."""
    pairs = await push_svc.targets(db)
    results = []
    for kind in kinds:
        chosen = [(s, t) for s, t in pairs if s.kind == kind]
        delivery = await push_svc.deliver(db, chosen, n, push_svc.DEFAULT_TTL_SECONDS)
        results.append(ChannelResult(kind, len(chosen), delivery.sent, delivery.failed))
    await db.flush()
    return results


def describe(n: Notification) -> list[str]:
    assert n.server_id is not None
    assert n.topic_id is not None
    assert n.due_since is not None
    assert n.version is not None
    topic_id = str(n.topic_id)
    due_since = canonical_instant(n.due_since)
    lines = [
        f"topic {n.topic_slug} ({n.title}), version {n.version}, due_since {due_since}",
        f"body: {n.body}",
    ]
    if n.quick_log is None:
        lines.append("quick_log: none (the topic can't be logged from a notification): no category")
    else:
        rendered = actions(n.server_id, topic_id, n.version, n.quick_log)
        lines.append(f"quick_log: {n.quick_log.type}; category {category_id(topic_id, rendered)}")
        lines.append("actions: " + ", ".join(f"{a.title} ({a.kind})" for a in rendered))
    entry_id = action_entry_id(n.server_id, topic_id, due_since)
    run = " (also the run id a Start makes)" if n.quick_log and n.quick_log.type == "timed" else ""
    lines.append(f"action entry id{run}: {entry_id}")
    return lines


def payloads(n: Notification, kinds: list[str]) -> dict[str, Any]:
    rendered: dict[str, Any] = {}
    if "apns" in kinds:
        rendered["apns"] = apns.render(n)
    if "web" in kinds:
        rendered["web"] = web.render(n).model_dump(mode="json")
    return rendered


async def main(args: argparse.Namespace) -> int:
    kinds = CHANNELS[args.channel]
    now = datetime.now(UTC)
    due_since: datetime = args.due_since or now.replace(microsecond=0)
    async with get_sessionmaker()() as db:
        try:
            n = await build(db, args.ref, due_since, now)
        except NotFound as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        for line in describe(n):
            print(line)
        if args.dry_run:
            print(json.dumps(payloads(n, kinds), indent=2, ensure_ascii=False))
            print("dry run: nothing sent")
            return 0
        if "apns" in kinds and not push_svc.apns_enabled():
            if args.channel == "apns":
                print("error: APNs is not configured on this server", file=sys.stderr)
                return 2
            print("note: APNs is not configured on this server: Web Push only")
            kinds = [k for k in kinds if k != "apns"]
        results = await send(db, n, kinds)
    sent = sum(r.sent for r in results)
    failed = sum(r.failed for r in results)
    total = sum(r.targets for r in results)
    detail = ", ".join(f"{r.kind}: {r.sent} sent, {r.failed} failed of {r.targets}" for r in results)
    print(f"sent the reminder to {sent} of {total} targets ({detail})")
    if not total:
        print("no targets: register the app (it does on launch) or turn reminders on in a browser")
    print("the topic's slot was not marked: the scheduler's state is unchanged")
    return 0 if sent and not failed else 1


async def run(args: argparse.Namespace) -> int:
    """:func:`main`, then close the APNs connections and the database pool."""
    try:
        return await main(args)
    finally:
        if (sender := apns.get_sender()) is not None:
            await sender.aclose()
        await get_engine().dispose()


def configure_logging() -> None:
    """Warnings and up: a failed send logs its reason (``app.services.push`` redacts tokens)."""
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    p.add_argument("ref", help="the topic's slug or id")
    p.add_argument(
        "--due-since",
        type=parse_instant,
        help="the reminder's slot, ISO 8601 with a timezone (default: now, to the second)",
    )
    p.add_argument("--channel", choices=sorted(CHANNELS), default="all")
    p.add_argument("--dry-run", action="store_true", help="print the rendered payloads; send nothing")
    return p


if __name__ == "__main__":
    configure_logging()
    sys.exit(asyncio.run(run(parser().parse_args())))
