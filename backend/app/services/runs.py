"""Runs: ``recordRunEvent``, ``getRun`` and ``listRuns`` (docs/specs/timers.md §3, §4.4, §4.5, §6).

A run is a server entity while it is open (``running``, ``paused``) or ``finishing``; it
becomes an entry with the same id when it is finished. Every tap is one event, stored as it
arrives and folded with :func:`app.services.run_fold.fold`, the pure reference that the PWA
and iOS ports match.

Every event runs inside the feed writer, so two devices' taps on one run never interleave:
resolve an alias, insert the event (or replay it), decide its effect, fold, update the run,
create or update the entry, write the change log. Most effects come from the fold. The
server decides the rest itself and records them in the event's ``payload["effect"]``, so a
later refold keeps them:

- ``finish`` (§3.6), and a second ``stop`` that carries answers, which is applied as one;
- the discard of a ``finishing`` run (§3.7);
- every event on a run that can no longer change: discarded (``already_closed``), its
  entry deleted (``entry_deleted``) or its times edited (``run_edited``). Such a run is
  never folded again, which is the fold's ``frozen`` cut-off at the first such event.

Change log (§2.4): a run upsert while it is open or finishing; on close the stop's entry
upsert (if any) first, then the run's delete and its tombstone. A late merge into a
stopped run changes the entry, never the run item.

Push work (Live Activities, T-LAPUSH) never runs in the writer: the route schedules
:func:`after_run_event` as a background task once the response is sent.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import read_snapshot
from app.errors import (
    BeforeStart,
    EventConflict,
    IdConflict,
    InvalidRequest,
    NotFound,
    RunDeleted,
    RunOpen,
    RunTooLong,
    RunTooManyEvents,
    TopicArchived,
    TopicNotTimed,
)
from app.models import (
    Channel,
    Entry,
    FeedKind,
    FeedOp,
    Run,
    RunAlias,
    RunEvent,
    RunEventType,
    RunStatus,
    Topic,
    TopicStatus,
    TopicVersion,
)
from app.schemas.api import (
    EntryUpdate,
    FieldIssue,
    RunDevice,
    RunEventIn,
    RunEventOut,
    RunEventResult,
    RunEventResultEvent,
    RunListStatus,
    RunOut,
    RunState,
)
from app.schemas.limits import MAX_RUN_EVENTS, RUN_START_MAX_AGE_DAYS
from app.services import entries as entry_svc
from app.services import run_fold
from app.services.answers import validate_answers
from app.services.feed import is_deleted, log_change, tombstone, writer
from app.services.topics import parse_questions, resolve_topic

OPEN = (RunStatus.running, RunStatus.paused)
type Effect = tuple[Literal["applied", "void"], str | None]
APPLIED: Effect = ("applied", None)


def now() -> datetime:
    """The server clock for the start-age bound (tests replace it)."""
    return datetime.now(UTC)


def _ms(at: datetime) -> datetime:
    """``at`` truncated to whole milliseconds (§2.3)."""
    return run_fold.from_ms(run_fold.to_ms(at))


@dataclass(frozen=True, slots=True)
class Recorded:
    result: RunEventResult
    created: bool  # the call created the run (or merged its start): 201


# --- reads ------------------------------------------------------------------------------


async def _resolve(db: AsyncSession, run_id: UUID) -> Run | None:
    """The run with this id, or the run this alias was merged into."""
    run = await db.get(Run, run_id, populate_existing=True)
    if run is not None:
        return run
    target = await db.scalar(select(RunAlias.run_id).where(RunAlias.id == run_id))
    return None if target is None else await db.get(Run, target, populate_existing=True)


async def _events(db: AsyncSession, run_id: UUID) -> list[RunEvent]:
    stmt = select(RunEvent).where(RunEvent.run_id == run_id).order_by(RunEvent.arrival)
    return list((await db.execute(stmt.execution_options(populate_existing=True))).scalars())


async def run_out(db: AsyncSession, run: Run) -> RunOut:
    effects: Mapping[str, Mapping[str, Any]] = run.state["effects"]
    aliases = (await db.execute(select(RunAlias.id).where(RunAlias.run_id == run.id))).scalars()
    return RunOut(
        id=run.id,
        topic_id=run.topic_id,
        version=run.version,
        status=run.status.value,
        revision=run.revision,
        started_at=run.started_at,
        ended_at=run.ended_at,
        edited=run.edited,
        events=[
            RunEventOut(
                id=e.id,
                type=e.type.value,
                at=e.at,
                seg=e.seg,
                step=e.step,
                pause_id=e.pause_id,
                arrival=e.arrival,
                effect=effects[str(e.id)]["effect"],
                reason=effects[str(e.id)]["reason"],
                source=e.source,
            )
            for e in await _events(db, run.id)
        ],
        state=RunState.model_validate(run.state),
        aliases=sorted(aliases, key=str),
    )


async def get_run(db: AsyncSession, run_id: UUID) -> RunOut:
    await read_snapshot(db)
    try:
        run = await _resolve(db, run_id)
        if run is None:
            raise NotFound(f"run '{run_id}' not found")
        return await run_out(db, run)
    finally:
        await db.rollback()  # ends the snapshot


async def list_runs(
    db: AsyncSession, statuses: Sequence[RunListStatus], topic_ref: str | None = None
) -> list[RunOut]:
    """Open (``running``, ``paused``) and/or ``finishing`` runs, oldest start first."""
    wanted = [s for name in set(statuses) for s in (OPEN if name == "open" else (RunStatus.finishing,))]
    stmt = select(Run).where(Run.status.in_(wanted))
    await read_snapshot(db)
    try:
        if topic_ref is not None:
            stmt = stmt.where(Run.topic_id == (await resolve_topic(db, topic_ref)).id)
        runs = (await db.execute(stmt.order_by(Run.started_at, Run.id))).scalars().all()
        return [await run_out(db, r) for r in runs]
    finally:
        await db.rollback()  # ends the snapshot


async def _result(db: AsyncSession, run: Run, event_id: UUID) -> RunEventResult:
    out = await run_out(db, run)
    effect = out.state.effects[str(event_id)]
    entry = None
    if run.status == RunStatus.stopped and run.entry_id is not None:
        entry = await entry_svc.get_entry(db, run.entry_id)
    return RunEventResult(
        event=RunEventResultEvent(id=event_id, effect=effect.effect, reason=effect.reason),
        run=out,
        entry=entry,
    )


# --- recordRunEvent ---------------------------------------------------------------------


@writer
async def record_event(db: AsyncSession, run_id: UUID, body: RunEventIn, channel: Channel) -> Recorded:
    at = _ms(body.at)
    run = await _resolve(db, run_id)
    if body.type == "start":
        if body.id != run_id:
            raise InvalidRequest(
                "a start's id is the run id",
                [FieldIssue(loc=["id"], message="must equal the run id in the path")],
            )
        if run is not None:
            return Recorded(await _replay(db, run, body, at), created=False)
        return await _start(db, run_id, body, at, channel)
    if run is None:
        if await is_deleted(db, FeedKind.run, run_id):
            raise RunDeleted(f"run '{run_id}' was deleted with its topic")
        raise NotFound(f"run '{run_id}' not found")
    if await db.get(RunEvent, body.id) is not None:
        return Recorded(await _replay(db, run, body, at), created=False)
    await _check_capacity(db, run)
    if body.type == "stop":
        _check_stop_at(run, at)

    effect = _decide(run, body)
    event = _new_event(run.id, body, at, channel, decided=effect)
    db.add(event)
    await db.flush()
    run.revision += 1
    if effect is not None:
        await _apply_decided(db, run, body, event, effect)
    else:
        await _apply_folded(db, run, body)
    await db.flush()
    return Recorded(await _result(db, run, body.id), created=False)


async def _replay(db: AsyncSession, run: Run, body: RunEventIn, at: datetime) -> RunEventResult:
    """The same event again: the current result, unless its content differs (§3.2)."""
    stored = await db.get(RunEvent, body.id, populate_existing=True)
    same = (
        stored is not None
        and stored.run_id == run.id
        and stored.type.value == body.type
        and run_fold.to_ms(stored.at) == run_fold.to_ms(at)
        and stored.seg == body.seg
        and stored.step == body.step
        and stored.pause_id == body.pause_id
        and (body.type != "start" or body.topic_id == run.topic_id)
    )
    if not same:
        raise EventConflict(
            f"event '{body.id}' was already recorded with different content",
            [FieldIssue(loc=["id"], message="already used by another event")],
        )
    return await _result(db, run, body.id)


async def _check_capacity(db: AsyncSession, run: Run) -> None:
    count = await db.scalar(select(func.count()).select_from(RunEvent).where(RunEvent.run_id == run.id))
    if (count or 0) >= MAX_RUN_EVENTS:
        raise RunTooManyEvents(f"the run already has {MAX_RUN_EVENTS} events")


def _check_stop_at(run: Run, at: datetime) -> None:
    """A stop before the start, or more than 7 days after it, is refused (§3.5, §5)."""
    if at < run.started_at:
        raise BeforeStart(
            "a stop can't be before the run's start",
            [FieldIssue(loc=["at"], message=f"must not be before {run.started_at.isoformat()}")],
        )
    if run_fold.to_ms(at) > run_fold.to_ms(run.started_at) + run_fold.MAX_RUN_MS:
        raise RunTooLong(
            "a run is at most 7 days long: discard it, or stop it earlier",
            [FieldIssue(loc=["at"], message="more than 7 days after the run's start")],
        )


def _new_event(
    run_id: UUID, body: RunEventIn, at: datetime, channel: Channel, *, decided: Effect | None = None
) -> RunEvent:
    payload: dict[str, Any] = {}
    if body.type == "start":
        payload["version"] = body.version
    for name in ("answers", "notes", "meta"):
        if (value := getattr(body, name)) is not None:
            payload[name] = value
    if decided is not None:
        payload["effect"] = {"effect": decided[0], "reason": decided[1]}
    return RunEvent(
        id=body.id,
        run_id=run_id,
        type=RunEventType(body.type),
        at=at,
        seg=body.seg,
        step=body.step,
        pause_id=body.pause_id,
        payload=payload,
        source=body.source or channel.value,
    )


# --- start and merge (§3.3, §4.5) ---------------------------------------------------------


async def _start(
    db: AsyncSession, run_id: UUID, body: RunEventIn, at: datetime, channel: Channel
) -> Recorded:
    assert body.topic_id is not None  # RunEventIn requires both for a start
    assert body.version is not None
    if await is_deleted(db, FeedKind.run, run_id):
        raise RunDeleted(f"run '{run_id}' was deleted with its topic")
    if await db.get(RunEvent, run_id) is not None:  # another run's tap already has this id
        raise EventConflict(
            f"event '{run_id}' was already recorded with different content",
            [FieldIssue(loc=["id"], message="already used by another event")],
        )
    if await db.get(Entry, run_id) is not None or await is_deleted(db, FeedKind.entry, run_id):
        raise IdConflict(
            f"'{run_id}' is the id of an entry", [FieldIssue(loc=["id"], message="already used by an entry")]
        )
    topic = await db.get(Topic, body.topic_id)
    if topic is None:
        raise NotFound(f"topic '{body.topic_id}' not found")
    if topic.status == TopicStatus.archived:
        raise TopicArchived(f"topic '{topic.slug}' is archived; unarchive it to start a run")
    version = await db.scalar(
        select(TopicVersion).where(TopicVersion.topic_id == topic.id, TopicVersion.version == body.version)
    )
    if version is None or version.timer is None:
        raise TopicNotTimed(
            f"version {body.version} of topic '{topic.slug}' is not timed",
            [FieldIssue(loc=["version"], message="not a timed version of the topic")],
        )
    if at < now() - timedelta(days=RUN_START_MAX_AGE_DAYS):
        raise InvalidRequest(
            "a run can't start more than 7 days ago",
            [FieldIssue(loc=["at"], message=f"must not be more than {RUN_START_MAX_AGE_DAYS} days ago")],
        )

    open_run = await db.scalar(select(Run).where(Run.topic_id == topic.id, Run.status.in_(OPEN)))
    if open_run is not None:  # merge: the new id becomes an alias of the open run
        await _check_capacity(db, open_run)
        db.add(RunAlias(id=run_id, run_id=open_run.id))
        db.add(_new_event(open_run.id, body, at, channel))
        await db.flush()
        open_run.revision += 1
        await _apply_folded(db, open_run, body)
        await db.flush()
        return Recorded(await _result(db, open_run, run_id), created=True)

    run = Run(
        id=run_id,
        topic_id=topic.id,
        topic_version_id=version.id,
        version=version.version,
        status=RunStatus.running,
        started_at=at,
        state={},
        source=body.source or channel.value,
        channel=channel,
        revision=1,
    )
    db.add(run)
    await db.flush()
    db.add(_new_event(run.id, body, at, channel))
    await db.flush()
    await _apply_folded(db, run, body)
    await db.flush()
    return Recorded(await _result(db, run, run_id), created=True)


# --- effects the server decides (§3.5 to §3.7, §4.4) --------------------------------------


def _carries_answers(body: RunEventIn) -> bool:
    return body.type == "finish" or (body.type == "stop" and body.answers is not None)


def _decide(run: Run, body: RunEventIn) -> Effect | None:
    """The effect of an event the fold doesn't decide; None when the fold does.

    Raises (nothing stored) when a finish's answers are invalid, or a finish reaches a run
    that hasn't stopped yet.
    """
    status = run.status
    if status == RunStatus.discarded:
        return ("void", "already_closed")
    if status == RunStatus.stopped and run.entry_id is None:
        return ("void", "entry_deleted")
    if status == RunStatus.stopped and run.edited:
        # The edit owns the times; answers are not times, so a finish still lands.
        return APPLIED if _carries_answers(body) else ("void", "run_edited")
    if body.type == "finish" and status in OPEN:
        raise RunOpen("the run hasn't stopped yet: send its stop first, then the answers")
    if _carries_answers(body) and status in (RunStatus.finishing, RunStatus.stopped):
        return APPLIED  # a second stop with answers is applied as a finish (§3.5)
    if body.type == "discard" and status == RunStatus.finishing:
        return APPLIED  # the stop was the fold's terminal; the server discards it (§3.7)
    return None


async def _apply_decided(
    db: AsyncSession, run: Run, body: RunEventIn, event: RunEvent, effect: Effect
) -> None:
    """Record a server-decided effect, and do what an applied one does. No refold."""
    run.state = {**run.state, "effects": {**run.state["effects"], str(event.id): _effect_json(effect)}}
    if effect != APPLIED:
        return
    if body.type == "discard":
        run.status = RunStatus.discarded
        run.state = {**run.state, "status": RunStatus.discarded.value}
        await _close(db, run)
    elif run.status == RunStatus.finishing:
        version = await db.get_one(TopicVersion, run.topic_version_id)
        state = _fold(run, version, await _events(db, run.id))
        await _create_entry(db, run, version, state, body)
    else:  # stopped: patch the entry's answers, notes and meta (both maps merge by key)
        assert run.entry_id is not None
        meta = None
        if body.meta is not None:
            meta = {**(await db.get_one(Entry, run.entry_id, populate_existing=True)).meta, **body.meta}
        await entry_svc.update_entry(
            db, run.entry_id, EntryUpdate(answers=body.answers or {}, notes=body.notes, meta=meta)
        )


# --- the fold -----------------------------------------------------------------------------


def _effect_json(effect: Effect) -> dict[str, Any]:
    return {"effect": effect[0], "reason": effect[1]}


def _fold(run: Run, version: TopicVersion, events: Sequence[RunEvent]) -> run_fold.RunState:
    return run_fold.fold(
        str(run.id),
        entry_svc.version_steps(version),
        [
            run_fold.Event(
                id=str(e.id),
                type=e.type.value,
                at=run_fold.to_ms(e.at),
                seg=e.seg,
                step=e.step,
                pause_id=None if e.pause_id is None else str(e.pause_id),
            )
            for e in events
        ],
    )


def _state_json(run: Run, state: run_fold.RunState, events: Sequence[RunEvent]) -> dict[str, Any]:
    """The fold's state as stored and served: the run's status, and the server-decided
    effects over the fold's."""
    out = run_fold.state_json(state)
    out["status"] = run.status.value
    for e in events:
        if (decided := e.payload.get("effect")) is not None:
            out["effects"][str(e.id)] = decided
    return out


async def _apply_folded(db: AsyncSession, run: Run, body: RunEventIn) -> None:
    """Fold the run again with the new event, then follow its status (§4.4)."""
    version = await db.get_one(TopicVersion, run.topic_version_id)
    events = await _events(db, run.id)
    state = _fold(run, version, events)
    before = run.status
    if before in OPEN and state.status in ("running", "paused"):
        run.status = RunStatus(state.status)
    run.state = _state_json(run, state, events)
    if before in OPEN and state.status == "stopped":
        await _stopped(db, run, version, state, body)
    elif before in OPEN and state.status == "discarded":
        run.status = RunStatus.discarded
        run.state = _state_json(run, state, events)
        await _close(db, run)
    elif before == RunStatus.stopped:
        await _merge_into_entry(db, run, version, state)
    else:  # still open, or finishing: the run item changed
        await log_change(db, FeedKind.run, FeedOp.upsert, run.id, run.topic_id)


async def _stopped(
    db: AsyncSession, run: Run, version: TopicVersion, state: run_fold.RunState, stop: RunEventIn
) -> None:
    """The open run's first stop (§3.5): an entry, or ``finishing`` when required answers
    are missing."""
    assert state.ended_at is not None
    run.ended_at = run_fold.from_ms(state.ended_at)
    questions = parse_questions(version.questions)
    if stop.answers is None and any(q.required for q in questions):
        run.status = RunStatus.finishing
        run.state = {**run.state, "status": run.status.value}
        await log_change(db, FeedKind.run, FeedOp.upsert, run.id, run.topic_id)
        return
    await _create_entry(db, run, version, state, stop)


async def _create_entry(
    db: AsyncSession, run: Run, version: TopicVersion, state: run_fold.RunState, body: RunEventIn
) -> None:
    """The run's entry (§3.5): checked as ``createEntry`` checks one, except that an archived
    topic doesn't block it. Then the run is closed."""
    typed = validate_answers(parse_questions(version.questions), body.answers or {})
    timing = run_fold.project_timing(state, entry_svc.version_steps(version))
    assert state.ended_at is not None
    run_fold.check_timing(timing, captured_at=state.ended_at)  # T1 to T5: a guard on the fold
    stop = await _terminal_stop(db, run)
    db.add(
        Entry(
            id=run.id,
            topic_id=run.topic_id,
            topic_version_id=run.topic_version_id,
            version=run.version,
            source=run.source,
            channel=run.channel,
            captured_at=run_fold.from_ms(state.ended_at),
            notes=body.notes if body.notes is not None else stop.payload.get("notes", ""),
            meta=body.meta if body.meta is not None else stop.payload.get("meta", {}),
            timing=run_fold.timing_json(timing),
            answers=entry_svc.answer_rows(run.topic_id, typed),
        )
    )
    await db.flush()
    run.status = RunStatus.stopped
    run.entry_id = run.id
    run.ended_at = run_fold.from_ms(state.ended_at)
    run.state = {**run.state, "status": run.status.value}
    await log_change(db, FeedKind.entry, FeedOp.upsert, run.id, run.topic_id)  # before the run's delete
    await _close(db, run)


async def _terminal_stop(db: AsyncSession, run: Run) -> RunEvent:
    """The stop that closed the run (the first applied one by arrival)."""
    effects = run.state["effects"]
    for e in await _events(db, run.id):
        if e.type == RunEventType.stop and effects.get(str(e.id), {}).get("effect") == "applied":
            return e
    raise AssertionError("a stopped run has no applied stop")


async def _close(db: AsyncSession, run: Run) -> None:
    """The run left the feed: it is stopped (its entry carries it on) or discarded (§2.4)."""
    await log_change(db, FeedKind.run, FeedOp.delete, run.id, run.topic_id)
    await tombstone(db, FeedKind.run, run.id, run.topic_id)


async def _merge_into_entry(
    db: AsyncSession, run: Run, version: TopicVersion, state: run_fold.RunState
) -> None:
    """A late event on a stopped run (§4.4): when it changes the times, the entry gets them."""
    projected = run_fold.project_timing(state, entry_svc.version_steps(version))
    run_fold.check_timing(projected, captured_at=state.ended_at)  # T1 to T5: a guard on the fold
    timing = run_fold.timing_json(projected)
    entry = await db.get_one(Entry, run.id, populate_existing=True)
    if entry.timing == timing:
        return
    entry.timing = timing
    entry.revision += 1
    entry.updated_at = func.now()
    await log_change(db, FeedKind.entry, FeedOp.upsert, entry.id, entry.topic_id)


# --- after the response -------------------------------------------------------------------


async def after_run_event(run_id: UUID, device: RunDevice | None) -> None:
    """Runs once the response is sent, outside the writer (§6): the Live Activity pushes
    (T-LAPUSH) go here. Nothing yet."""
