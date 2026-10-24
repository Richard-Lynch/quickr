"""Live Activity pushes: the run's activity on the user's other iPhones (docs/specs/timers.md
§6, §10.3, §10.4).

The app registers two kinds of token (:func:`register`): a device's push-to-start token, and
each activity's update token with the topic and the run it shows. After every committed run
event, :func:`notify` (from :func:`app.services.runs.after_run_event`, a post-response
background task, never inside the feed writer) pushes to them:

- ``start`` to every push-to-start token when the event created the run, except the
  originating device's when it started an activity itself (``device.live_activity``);
- ``update`` with the content state while the run is open, ``end`` with a final state and a
  dismissal date once it is ``finishing``, ``stopped`` or ``discarded``, to the update tokens
  registered for the run (or for a run id merged into it), except the originating device's:
  that device already updated locally.

Sends are serialised per topic, in this process: one in flight at a time, and a newer change
replaces a queued one for the same run, merging what it owes (a push-to-start is never lost;
a device is excluded only when every merged change came from it).
Every send reads the run's **latest** state when it goes out, so a later state never goes out
before an earlier one. The read and the token bookkeeping each run in their own short
transaction, and no transaction is open during the network calls.

Failures touch only the token row: a 410 or ``BadDeviceToken`` deletes that token, and
nothing else. This never goes through :func:`app.services.push.deliver`, which would delete
the APNs device (``apns_devices``) or count against its ``failure_count``. After ``end``, the
update tokens registered for that run (and its aliases) are dropped; a token registered for
a newer run of the topic is kept.

The payloads (:func:`content_state`, :func:`payload`) are pinned by
``shared/fixtures/live-activity-vectors.json`` (``tests/test_live_activity_vectors.py``).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.models import LiveActivityToken, Run, RunAlias, RunStatus, Topic, TopicVersion
from app.schemas.api import ApnsEnvironment, LiveActivityIn, LiveActivityOut, RunDevice
from app.services import run_fold
from app.services.feed import feed_identity, writer
from app.services.notification import truncate
from app.services.push import apns
from app.services.push.apns import MAX_PAYLOAD_BYTES
from app.services.push.base import PushFailed, PushGone
from app.services.topics import parse_timer

log = logging.getLogger(__name__)

ATTRIBUTES_TYPE = "RunActivityAttributes"  # the app's ActivityAttributes type
CONTENT_STATE_VERSION = 1
MAX_LABEL_LENGTH = 64  # the topic name and step labels in a payload (§10.3)
STALE_SECONDS = 4 * 3600  # as the app's local updates (§10.3)
DISMISS_SECONDS = 15 * 60  # an ended activity stays this long (§10.3)
EXPIRATION_SECONDS = 4 * 3600  # how long APNs keeps an undelivered push
MAX_CONCURRENT_SENDS = 8
CLOSED = frozenset({RunStatus.finishing, RunStatus.stopped, RunStatus.discarded})

type Event = Literal["start", "update", "end"]


# --- payloads (pure) ------------------------------------------------------------------------


def _seconds(ms: int) -> float:
    """Unix seconds as a Double: ActivityKit decodes ``Date`` from 2001, so instants never are one."""
    return ms / 1000


def _instant(text: str | None) -> int | None:
    return None if text is None else run_fold.parse_instant(text)


def content_state(
    run_id: UUID | str, revision: int, state: Mapping[str, Any], steps: Sequence[run_fold.Step]
) -> dict[str, Any]:
    """``RunActivityState`` (§10.3) from a run's stored state (``RunOut.state``) and its version's
    steps.

    While the run is open, the segment fields describe the open segment. Once it closed, they
    describe its last segment (none for a run discarded before Next: segment 0 from the start),
    ``status`` is the run's final status, and ``ended_at`` and ``active_ms`` say what was saved
    (null when discarded). ``step_index`` is the open step's 0-based position in the version's
    steps (null in a lap). The paused fields count ended pauses only, split at the segment's
    start; an open pause is ``paused_at``, and the timers freeze there.
    """
    started_at = run_fold.parse_instant(state["started_at"])
    pauses = [(run_fold.parse_instant(p["start"]), run_fold.parse_instant(p["end"])) for p in state["pauses"]]
    keys = [s.key for s in steps]
    open_seg = state["open"]
    segments = state["segments"]
    if open_seg is not None:
        seg, kind, step, label = open_seg["index"], open_seg["kind"], open_seg["step"], open_seg["label"]
        seg_started_at = run_fold.parse_instant(open_seg["started_at"])
    elif segments:
        last = segments[-1]
        seg, kind, step, label = len(segments) - 1, last["kind"], last["step"], last["label"]
        seg_started_at = run_fold.parse_instant(last["started_at"])
    else:
        seg, kind, step, label, seg_started_at = 0, "lap", None, "", started_at
    next_label = None
    if open_seg is not None and state["next_step"] is not None:
        next_label = truncate(steps[keys.index(state["next_step"])].label, MAX_LABEL_LENGTH)
    paused_at = _instant(state["paused_since"])
    ended_at = _instant(state["ended_at"])
    closed = state["status"] in ("finishing", "stopped", "discarded")
    return {
        "v": CONTENT_STATE_VERSION,
        "run_id": str(run_id),
        "revision": revision,
        "status": state["status"],
        "started_at": _seconds(started_at),
        "seg": seg,
        "seg_started_at": _seconds(seg_started_at),
        "label": truncate(label, MAX_LABEL_LENGTH),
        "step_index": keys.index(step) if kind == "step" and step in keys else None,
        "step_count": len(steps),
        "next_label": next_label,
        "paused_at": None if paused_at is None else _seconds(paused_at),
        "paused_ms_before_seg": sum(max(0, min(end, seg_started_at) - start) for start, end in pauses),
        "paused_ms_in_seg": sum(max(0, end - max(start, seg_started_at)) for start, end in pauses),
        "ended_at": None if ended_at is None else _seconds(ended_at),
        "active_ms": sum(s["active_ms"] for s in segments) if closed and ended_at is not None else None,
    }


def attributes(server_id: str, topic_id: UUID | str, topic_name: str) -> dict[str, Any]:
    """``RunActivityAttributes``: one activity per (server, topic), and no step list (§10.3)."""
    return {
        "server_id": server_id,
        "topic_id": str(topic_id),
        "topic_name": truncate(topic_name, MAX_LABEL_LENGTH),
    }


def payload(
    event: Event, state: dict[str, Any], *, timestamp: int, attrs: dict[str, Any] | None = None
) -> dict[str, Any]:
    """The APNs body for one Live Activity push (§10.4). Every ``aps`` key is Apple's
    ("Starting and updating Live Activities with ActivityKit push notifications",
    developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-
    activitykit-push-notifications):

    - ``timestamp``: now, in seconds since 1970, so the system shows the most recent push;
    - ``event``: ``start``, ``update`` or ``end``; ``content-state``: the ``ContentState``,
      encoded with default strategies (instants are Doubles);
    - ``stale-date`` (start, update): when the activity shows as outdated without updates;
    - ``dismissal-date`` (end): when the system removes the ended activity, within four hours;
      a date in the past removes it at once (a discarded run);
    - start only: ``attributes-type`` and ``attributes`` (required), an ``alert`` (required, so
      the person isn't surprised), and ``input-push-token: 1`` (iOS 18: the new activity gets
      an update token, which the app registers).
    """
    aps: dict[str, Any] = {"timestamp": timestamp, "event": event, "content-state": state}
    if event == "end":
        dismiss_in = 0 if state["status"] == "discarded" else DISMISS_SECONDS
        aps["dismissal-date"] = timestamp + dismiss_in
    else:
        aps["stale-date"] = timestamp + STALE_SECONDS
    if event == "start":
        assert attrs is not None
        aps["attributes-type"] = ATTRIBUTES_TYPE
        aps["attributes"] = attrs
        aps["alert"] = {"title": attrs["topic_name"], "body": state["label"] or attrs["topic_name"]}
        aps["input-push-token"] = 1
    return {"aps": aps}


def encode(body: dict[str, Any]) -> bytes:
    """The request body. Raises :class:`PushFailed` (our bug) above Apple's 4 KB limit."""
    data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    if len(data) > MAX_PAYLOAD_BYTES:
        log.error("Live Activity payload is %d bytes, over the %d limit", len(data), MAX_PAYLOAD_BYTES)
        raise PushFailed(f"payload too large ({len(data)} bytes)")
    return data


# --- tokens ---------------------------------------------------------------------------------


@writer
async def register(db: AsyncSession, body: LiveActivityIn) -> LiveActivityOut:
    """Create or refresh (by token) a Live Activity token. A device has one push-to-start token:
    a new one replaces its older ones, so a start never reaches the device twice."""
    if body.kind == "start":
        await db.execute(
            delete(LiveActivityToken).where(
                LiveActivityToken.kind == "start",
                LiveActivityToken.device_token == body.device_token,
                LiveActivityToken.token != body.token,
            )
        )
    values = body.model_dump(exclude={"token"})
    stmt = (
        insert(LiveActivityToken)
        .values(token=body.token, **values)
        .on_conflict_do_update(index_elements=["token"], set_=values)
        .returning(LiveActivityToken)
        .execution_options(populate_existing=True)
    )
    row = (await db.execute(stmt)).scalar_one()
    return LiveActivityOut.model_validate(row, from_attributes=True)


@writer
async def unregister(db: AsyncSession, token: str) -> None:
    """Remove a token. Unknown tokens are ignored (idempotent)."""
    await db.execute(delete(LiveActivityToken).where(LiveActivityToken.token == token))


# --- sending --------------------------------------------------------------------------------


@dataclass(slots=True)
class _Job:
    """What one run owes its tokens. A newer change merges into a queued job."""

    run_id: UUID
    start: bool = False  # the run was created: push-to-start owed
    start_except: str | None = None  # the device that started its own activity
    except_device: str | None = None  # the device every merged change came from, if one did


@dataclass(slots=True)
class _Queue:
    jobs: dict[UUID, _Job] = field(default_factory=dict)  # by run, oldest first


_queues: dict[UUID, _Queue] = {}  # by topic; present while a worker drains it


@dataclass(frozen=True, slots=True)
class _Send:
    token: str
    environment: ApnsEnvironment
    event: Event
    body: bytes


async def notify(run_id: UUID, topic_id: UUID, device: RunDevice | None, *, created: bool) -> None:
    """Push the run's change to its Live Activities. The first call for a topic drains its
    queue, so it returns once every queued change is sent; a call while one drains only queues."""
    sender = apns.get_sender()
    if sender is None:
        return
    queue = _queues.get(topic_id)
    owner = queue is None
    if queue is None:
        queue = _queues[topic_id] = _Queue()
    origin = device.apns_token if device else None
    if (job := queue.jobs.get(run_id)) is None:
        job = queue.jobs[run_id] = _Job(run_id, except_device=origin)
    elif job.except_device != origin:  # it also carries another device's change
        job.except_device = None
    if created:
        job.start = True
        job.start_except = device.apns_token if device and device.live_activity else None
    if not owner:
        return
    try:
        while queue.jobs:
            job = queue.jobs.pop(next(iter(queue.jobs)))
            try:
                await _push(sender, job)
            except Exception:
                log.exception("Live Activity push for run %s failed", job.run_id)
    finally:
        del _queues[topic_id]


async def _push(sender: apns.ApnsSender, job: _Job) -> None:
    async with get_sessionmaker()() as db:
        sends, ids, ended = await _plan(db, sender, job)
        await db.rollback()
    gone = await _send_all(sender, sends)
    if not (gone or ended):
        return
    async with get_sessionmaker()() as db, db.begin():
        if gone:
            await db.execute(delete(LiveActivityToken).where(LiveActivityToken.token.in_(gone)))
        if ended:
            await db.execute(
                delete(LiveActivityToken).where(
                    LiveActivityToken.kind == "update", LiveActivityToken.run_id.in_(ids)
                )
            )


async def _plan(db: AsyncSession, sender: apns.ApnsSender, job: _Job) -> tuple[list[_Send], list[UUID], bool]:
    """The sends for ``job`` from the run's latest state, the run ids its update tokens may be
    registered for, and whether it ended. Read only."""
    server_id = (await feed_identity(db)).server_id
    run = await db.get(Run, job.run_id)
    if run is None:  # deleted with its topic
        return [], [], False
    version = await db.get_one(TopicVersion, run.topic_version_id)
    topic = await db.get_one(Topic, run.topic_id)
    timer = parse_timer(version.timer)
    steps = [] if timer is None else [run_fold.Step(s.key, s.label) for s in timer.steps]
    aliases = (await db.execute(select(RunAlias.id).where(RunAlias.run_id == run.id))).scalars()
    ids = [run.id, *aliases]
    ended = run.status in CLOSED
    state = content_state(run.id, run.revision, run.state, steps)
    now = sender.now()

    sends: list[_Send] = []
    update = encode(payload("end" if ended else "update", state, timestamp=now))
    stmt = select(LiveActivityToken).where(
        LiveActivityToken.kind == "update", LiveActivityToken.run_id.in_(ids)
    )
    for t in (await db.execute(stmt)).scalars():
        if t.device_token != job.except_device:
            sends.append(_Send(t.token, _environment(t.environment), "end" if ended else "update", update))
    if job.start and not ended:
        attrs = attributes(server_id, topic.id, topic.name)
        start = encode(payload("start", state, timestamp=now, attrs=attrs))
        stmt = select(LiveActivityToken).where(LiveActivityToken.kind == "start")
        for t in (await db.execute(stmt)).scalars():
            if t.device_token != job.start_except:
                sends.append(_Send(t.token, _environment(t.environment), "start", start))
    return sends, ids, ended


def _environment(value: str) -> ApnsEnvironment:
    return "sandbox" if value == "sandbox" else "production"


async def _send_all(sender: apns.ApnsSender, sends: Sequence[_Send]) -> list[str]:
    """Send each, ``MAX_CONCURRENT_SENDS`` at a time. Returns the tokens APNs says are gone."""
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_SENDS)
    expiration = sender.now() + EXPIRATION_SECONDS

    async def one(s: _Send) -> str | None:
        async with semaphore:
            try:
                await sender.post_live_activity(
                    s.token, s.environment, s.body, expiration=expiration, what=f"live activity {s.event}"
                )
            except PushGone as exc:
                log.info("Live Activity token is gone; removing it: %s", exc)
                return s.token
            except PushFailed as exc:
                log.warning("Live Activity %s push failed: %s", s.event, exc)
            return None

    return [token for token in await asyncio.gather(*(one(s) for s in sends)) if token is not None]
