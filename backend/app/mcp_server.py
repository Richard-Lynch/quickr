"""FastMCP server exposing the same service layer as the HTTP API.

Tools return the same Pydantic models as the REST API, so MCP clients get the
identical, fully typed output schemas.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Annotated, Literal
from uuid import UUID, uuid4

import mcp_types as mt
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools import ToolResult
from pydantic import AwareDatetime, Field, ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.errors import DomainError, InvalidRequest
from app.models import Channel
from app.schemas.api import (
    AnswerMap,
    Bucket,
    CompatibilityReport,
    EntryCreate,
    EntryFilters,
    EntryOut,
    EntryPage,
    EntryUpdate,
    Meta,
    QuestionList,
    QuestionSeries,
    RunEventIn,
    RunEventResult,
    RunListStatus,
    RunOut,
    Schedule,
    StatusFilter,
    TimingEdit,
    TopicCreate,
    TopicDetail,
    TopicPage,
    TopicSort,
    TopicStats,
    TopicUpdate,
    TopicVersionOut,
    VersionCreate,
)
from app.schemas.base import describe_issues, issues_from
from app.schemas.questions import Timer
from app.services import entries as entry_svc
from app.services import runs as run_svc
from app.services import stats as stats_svc
from app.services import topics as topic_svc

INSTRUCTIONS = """\
quickR records structured answers ("entries") against config-driven "topics".
An entry is one set of answers for a topic. A topic has an ordered list of
questions; each question has a stable `key` and a `type` of int | double | str |
enum with constraints (min/max, length, options). Enum questions with
`multiple: true` take a list of option values.

Typical flow: `list_topics` (or `get_topic` by slug) to discover the question
keys and constraints, then `record_entry` with `answers` as {key: value}.
Topics may have a `schedule` (daily times or an interval); `due` tells you
whether an entry is expected now, and `list_due_topics` lists the ones waiting.
To change questions, call `check_topic_version` with the full new question list,
then `publish_topic_version` with `base_version` = the topic's current_version.
Question types can never change for a key and enum options can only be archived.
A topic is timed when its current version has a `timer` ({steps: [{key, label}]};
no steps is a plain stopwatch). `publish_topic_version` requires `timer`: pass the
current version's (from `list_topic_versions`) to keep it, or null for untimed.

Timing a timed topic: `start_run`, then `run_action` for each tap (next, lap, skip,
pause, resume, stop), acting on what is open now. A stop makes the entry, or leaves
the run `finishing` when required questions are unanswered: `run_action` finish with
the answers then makes it. `list_runs` shows open and finishing runs. A stopped
run's times are corrected with `edit_run_timing` on its entry (same id as the run);
`update_entry` can't change a timed entry's captured_at. `record_entry` on a timed
topic records an untimed entry.
"""


class DomainErrorMiddleware(Middleware):
    """Surface domain errors (with per-field issues) to the client verbatim.

    Everything else stays masked (``mask_error_details``) so unexpected
    exceptions never leak internals.
    """

    async def on_call_tool(
        self,
        context: MiddlewareContext[mt.CallToolRequestParams],
        call_next: CallNext[mt.CallToolRequestParams, ToolResult],
    ) -> ToolResult:
        try:
            return await call_next(context)
        except ValidationError as exc:  # arguments or a model built inside the tool
            raise ToolError(f"invalid arguments: {describe_issues(issues_from(exc))}") from exc
        except ToolError as exc:
            # FastMCP may wrap the original error more than once; find it.
            cause: BaseException | None = exc.__cause__
            while cause is not None and not isinstance(cause, DomainError | ValidationError):
                cause = cause.__cause__
            if isinstance(cause, DomainError):
                raise ToolError(cause.describe()) from cause
            if isinstance(cause, ValidationError):
                raise ToolError(f"invalid arguments: {describe_issues(issues_from(cause))}") from cause
            raise


mcp = FastMCP("quickr", instructions=INSTRUCTIONS, mask_error_details=True)
mcp.add_middleware(DomainErrorMiddleware())

TopicRef = Annotated[str, Field(description="Topic UUID or slug.")]


@asynccontextmanager
async def _db() -> AsyncIterator[AsyncSession]:
    async with get_sessionmaker()() as session:
        yield session


@mcp.tool
async def list_topics(
    query: Annotated[str | None, Field(description="Search text.")] = None,
    status: StatusFilter = "active",
    sort: Annotated[
        TopicSort, Field(description="'due' = due first, then by next due time, then by activity.")
    ] = "due",
    due_only: Annotated[bool, Field(description="Only topics waiting for an entry now.")] = False,
    limit: Annotated[int, Field(ge=1, le=200)] = 50,
    offset: Annotated[int, Field(ge=0)] = 0,
) -> TopicPage:
    """List/search topics (name, slug, description and question labels), with due status."""
    async with _db() as db:
        return await topic_svc.list_topics(
            db, q=query, status=status, sort=sort, due_only=due_only, limit=limit, offset=offset
        )


@mcp.tool
async def list_due_topics() -> TopicPage:
    """Active topics whose schedule says an entry is due now, longest overdue first."""
    async with _db() as db:
        return await topic_svc.list_topics(db, sort="due", due_only=True, limit=200)


@mcp.tool
async def get_topic(ref: TopicRef) -> TopicDetail:
    """Get a topic including its current question config."""
    async with _db() as db:
        topic = await topic_svc.resolve_topic(db, ref)
        return await topic_svc.topic_detail(db, topic.id)


@mcp.tool
async def create_topic(
    name: Annotated[str, Field(min_length=1, max_length=200)],
    questions: QuestionList,
    slug: Annotated[str | None, Field(pattern=r"^[a-z0-9][a-z0-9-]{0,63}$")] = None,
    description: str = "",
    schedule: Annotated[Schedule | None, Field(description="Optional daily or interval schedule.")] = None,
    timer: Annotated[Timer | None, Field(description="Optional: makes the topic timed.")] = None,
) -> TopicDetail:
    """Create a topic with an initial (version 1) question list. An empty list makes a single
    topic: logging it records an entry with no answers (record_entry with answers {})."""
    async with _db() as db:
        return await topic_svc.create_topic(
            db,
            TopicCreate(
                name=name,
                slug=slug,
                description=description,
                questions=questions,
                schedule=schedule,
                timer=timer,
            ),
        )


@mcp.tool
async def update_topic(
    ref: TopicRef,
    name: str | None = None,
    slug: str | None = None,
    description: str | None = None,
    schedule: Annotated[Schedule | None, Field(description="New schedule (replaces the old one).")] = None,
    clear_schedule: Annotated[bool, Field(description="Remove the topic's schedule.")] = False,
) -> TopicDetail:
    """Update topic metadata (name/slug/description/schedule). Questions change via versions."""
    fields: dict[str, object] = {"name": name, "slug": slug, "description": description}
    if schedule is not None or clear_schedule:
        fields["schedule"] = None if clear_schedule else schedule
    async with _db() as db:
        return await topic_svc.update_topic(db, ref, TopicUpdate.model_validate(fields))


@mcp.tool
async def set_topic_archived(ref: TopicRef, archived: bool) -> TopicDetail:
    """Archive (blocks new entries, hidden from default listings) or unarchive a topic."""
    async with _db() as db:
        return await topic_svc.set_archived(db, ref, archived=archived)


@mcp.tool
async def list_topic_versions(ref: TopicRef) -> list[TopicVersionOut]:
    """All versions of a topic's question config, newest first."""
    async with _db() as db:
        return await topic_svc.list_versions(db, ref)


@mcp.tool
async def check_topic_version(
    ref: TopicRef,
    questions: QuestionList,
    base_version: Annotated[int | None, Field(ge=1, description="Fail if the topic moved past this.")] = None,
) -> CompatibilityReport:
    """Dry-run a new question list: returns changes, warnings and blocking errors."""
    async with _db() as db:
        return await topic_svc.check_version(db, ref, questions, base_version)


@mcp.tool
async def publish_topic_version(
    ref: TopicRef,
    questions: QuestionList,
    base_version: Annotated[int, Field(ge=1, description="Must equal the topic's current_version.")],
    timer: Annotated[
        Timer | None,
        Field(
            description="The new version's timer, or null for untimed. Required: pass the current "
            "version's timer to keep timing as it is."
        ),
    ],
    change_note: str = "",
) -> TopicDetail:
    """Publish a new version of the topic's questions (full replacement list) and timer."""
    async with _db() as db:
        return await topic_svc.publish_version(
            db,
            ref,
            VersionCreate(
                questions=questions, base_version=base_version, timer=timer, change_note=change_note
            ),
        )


@mcp.tool
async def record_entry(
    ref: TopicRef,
    answers: AnswerMap,
    source: Annotated[str, Field(min_length=1, max_length=100)] = "mcp",
    captured_at: Annotated[AwareDatetime | None, Field(description="Defaults to now.")] = None,
    notes: str = "",
    meta: Meta | None = None,
    id: Annotated[
        UUID | None,
        Field(description="Optional client id: re-sending the same id returns the existing entry."),
    ] = None,
) -> EntryOut:
    """Record one set of answers for a topic against its current version."""
    async with _db() as db:
        body = EntryCreate(
            id=id, answers=answers, source=source, captured_at=captured_at, notes=notes, meta=meta or {}
        )
        return await entry_svc.create_entry(db, ref, body, Channel.mcp)


@mcp.tool
async def list_entries(
    ref: TopicRef,
    captured_from: AwareDatetime | None = None,
    captured_to: AwareDatetime | None = None,
    source: str | None = None,
    limit: Annotated[int, Field(ge=1, le=500)] = 50,
    offset: Annotated[int, Field(ge=0)] = 0,
) -> EntryPage:
    """List entries for a topic, newest first."""
    async with _db() as db:
        filters = EntryFilters(captured_from=captured_from, captured_to=captured_to, source=source)
        return await entry_svc.list_entries(db, ref, filters, limit=limit, offset=offset)


@mcp.tool
async def update_entry(
    entry_id: UUID,
    answers: AnswerMap | None = None,
    captured_at: AwareDatetime | None = None,
    notes: str | None = None,
) -> EntryOut:
    """Correct an entry. `answers` merges; a null value clears that answer. A timed entry's
    captured_at is its run's end: change it with edit_run_timing."""
    async with _db() as db:
        return await entry_svc.update_entry(
            db, entry_id, EntryUpdate(answers=answers, captured_at=captured_at, notes=notes)
        )


@mcp.tool
async def delete_entry(entry_id: UUID) -> str:
    """Permanently delete an entry."""
    async with _db() as db:
        await entry_svc.delete_entry(db, entry_id)
        return "deleted"


@mcp.tool
async def topic_stats(
    ref: TopicRef,
    captured_from: AwareDatetime | None = None,
    captured_to: AwareDatetime | None = None,
) -> TopicStats:
    """Aggregate answers per question (numeric summary/histogram, enum counts, text samples)."""
    async with _db() as db:
        return await stats_svc.topic_stats(
            db, ref, EntryFilters(captured_from=captured_from, captured_to=captured_to)
        )


@mcp.tool
async def question_series(
    ref: TopicRef,
    key: str,
    bucket: Bucket = "day",
    tz: str = "UTC",
) -> QuestionSeries:
    """Time series of one question bucketed by day/week/month."""
    async with _db() as db:
        return await stats_svc.question_series(db, ref, key, EntryFilters(), bucket=bucket, tz=tz)


# --- runs (docs/specs/timers.md §11.6) ----------------------------------------------------

RunAction = Literal["next", "lap", "skip", "pause", "resume", "stop", "finish", "discard"]
TapAt = Annotated[
    AwareDatetime | None,
    Field(description="When it happened; defaults to now (server clock). At most 7 days back for a start."),
]


async def _record(db: AsyncSession, run_id: UUID, body: RunEventIn) -> RunEventResult:
    recorded = await run_svc.record_event(db, run_id, body, Channel.mcp)
    await run_svc.after_run_event(recorded.result.run.id, None)  # after the commit, as the route does
    return recorded.result


@mcp.tool
async def start_run(ref: TopicRef, at: TapAt = None) -> RunEventResult:
    """Start timing a timed topic, on its current version. If the topic already has an open
    run, this start merges into it (effect void, reason merged) and `run` is that run."""
    async with _db() as db:
        topic = await topic_svc.resolve_topic(db, ref)
        topic_id, version = topic.id, topic.current_version
        await db.rollback()  # the writer needs an idle session
        run_id = uuid4()
        body = RunEventIn(id=run_id, type="start", at=at or run_svc.now(), topic_id=topic_id, version=version)
        return await _record(db, run_id, body)


def _open_pause(run: RunOut) -> UUID | None:
    """The pause event the run's open pause began with: the last applied pause in time order."""
    pauses = [e for e in run.events if e.type == "pause" and e.effect == "applied"]
    last = max(pauses, key=lambda e: (e.at, str(e.id)), default=None)
    return None if run.state.paused_since is None or last is None else last.id


@mcp.tool
async def run_action(
    run_id: UUID,
    action: RunAction,
    at: TapAt = None,
    answers: Annotated[AnswerMap | None, Field(description="stop and finish only.")] = None,
    notes: Annotated[str | None, Field(description="stop and finish only.")] = None,
) -> RunEventResult:
    """One tap on a run, against what is open now: next (the next step, or a lap after the
    last), lap, skip (the open step, or the next one during a lap), pause, resume, stop,
    finish (the answers of a stopped or finishing run) or discard. A next, lap or skip with
    nothing open, or a resume while not paused, is refused; other taps the run can't take
    (a pause while paused, a second stop) are recorded with effect void."""
    async with _db() as db:
        run = await run_svc.get_run(db, run_id)  # ends its read snapshot: the session is idle
        opened = run.state.open
        seg: int | None = None
        step: str | None = None
        pause_id: UUID | None = None
        if action in ("next", "lap", "skip"):
            if opened is None:
                raise InvalidRequest(f"the run is {run.status}: nothing is open to {action}")
            seg = opened.index
        if action == "skip":
            assert opened is not None
            step = opened.step or run.state.next_step  # during a lap, the next step
            if step is None:
                raise InvalidRequest("there is no step left to skip")
        if action == "resume":
            pause_id = _open_pause(run)
            if pause_id is None:
                raise InvalidRequest("the run isn't paused")
        if at is None:  # monotonic, as every client stamps its taps (timers.md §5.1)
            latest = max(e.at for e in run.events)
            at = max(run_svc.now(), latest + timedelta(milliseconds=1))
        body = RunEventIn(
            id=uuid4(),
            type=action,
            at=at,
            seg=seg,
            step=step,
            pause_id=pause_id,
            answers=answers,
            notes=notes,
        )
        return await _record(db, run.id, body)


@mcp.tool
async def list_runs(
    status: Annotated[
        RunListStatus | None,
        Field(description="open (running or paused) or finishing; default both."),
    ] = None,
) -> list[RunOut]:
    """Open and finishing runs with their state, oldest start first. Stopped runs are entries."""
    async with _db() as db:
        return await run_svc.list_runs(db, [status] if status is not None else ["open", "finishing"])


@mcp.tool
async def edit_run_timing(
    entry_id: UUID,
    timing: Annotated[
        TimingEdit,
        Field(
            description="The run's times, replaced as a whole: started_at, every segment (kind, "
            "step, ended_at) in order, skipped step keys and pauses. The last segment's ended_at "
            "becomes the entry's captured_at."
        ),
    ],
    expected_revision: Annotated[int, Field(ge=1, description="The entry's current revision.")],
) -> EntryOut:
    """Correct a stopped run's times on its entry. The run is then frozen: taps that arrive
    later from other devices are void (run_edited); answers still apply."""
    async with _db() as db:
        return await entry_svc.update_entry(
            db, entry_id, EntryUpdate(timing=timing, expected_revision=expected_revision)
        )
