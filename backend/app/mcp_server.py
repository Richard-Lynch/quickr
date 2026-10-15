"""FastMCP server exposing the same service layer as the HTTP API.

Tools return the same Pydantic models as the REST API, so MCP clients get the
identical, fully typed output schemas.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import UUID

import mcp_types as mt
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from fastmcp.tools import ToolResult
from pydantic import AwareDatetime, Field, ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.errors import DomainError
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
    Schedule,
    StatusFilter,
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
from app.services import entries as entry_svc
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
) -> TopicDetail:
    """Create a topic with an initial (version 1) question list."""
    async with _db() as db:
        return await topic_svc.create_topic(
            db,
            TopicCreate(
                name=name, slug=slug, description=description, questions=questions, schedule=schedule
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
    change_note: str = "",
) -> TopicDetail:
    """Publish a new version of the topic's questions (full replacement list)."""
    async with _db() as db:
        return await topic_svc.publish_version(
            db, ref, VersionCreate(questions=questions, base_version=base_version, change_note=change_note)
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
    """Correct an entry. `answers` merges; a null value clears that answer."""
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
