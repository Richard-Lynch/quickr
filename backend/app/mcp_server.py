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
from pydantic import AwareDatetime, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_sessionmaker
from app.errors import DomainError
from app.models import Channel
from app.schemas.api import (
    AnswerMap,
    Bucket,
    CompatibilityReport,
    Meta,
    QuestionList,
    QuestionSeries,
    SessionCreate,
    SessionFilters,
    SessionOut,
    SessionPage,
    SessionUpdate,
    StatusFilter,
    TopicCreate,
    TopicDetail,
    TopicPage,
    TopicStats,
    TopicUpdate,
    TopicVersionOut,
    VersionCreate,
)
from app.services import sessions as session_svc
from app.services import stats as stats_svc
from app.services import topics as topic_svc

INSTRUCTIONS = """\
Quicker records structured answers ("sessions") against config-driven "topics".
A topic has an ordered list of questions; each question has a stable `key` and a
`type` of int | double | str | enum with constraints (min/max, length, options).

Typical flow: `list_topics` (or `get_topic` by slug) to discover the question
keys and constraints, then `record_session` with `answers` as {key: value}.
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
        except ToolError as exc:
            if isinstance(exc.__cause__, DomainError):
                raise ToolError(exc.__cause__.describe()) from exc.__cause__
            raise


mcp = FastMCP("quicker", instructions=INSTRUCTIONS, mask_error_details=True)
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
    limit: Annotated[int, Field(ge=1, le=200)] = 50,
    offset: Annotated[int, Field(ge=0)] = 0,
) -> TopicPage:
    """List/search topics (name, slug, description and question labels)."""
    async with _db() as db:
        return await topic_svc.list_topics(db, q=query, status=status, limit=limit, offset=offset)


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
) -> TopicDetail:
    """Create a topic with an initial (version 1) question list."""
    async with _db() as db:
        return await topic_svc.create_topic(
            db, TopicCreate(name=name, slug=slug, description=description, questions=questions)
        )


@mcp.tool
async def update_topic(
    ref: TopicRef,
    name: str | None = None,
    slug: str | None = None,
    description: str | None = None,
) -> TopicDetail:
    """Update topic metadata (name/slug/description). Questions change via versions."""
    async with _db() as db:
        return await topic_svc.update_topic(
            db, ref, TopicUpdate(name=name, slug=slug, description=description)
        )


@mcp.tool
async def set_topic_archived(ref: TopicRef, archived: bool) -> TopicDetail:
    """Archive (read-only, hidden by default) or unarchive a topic."""
    async with _db() as db:
        return await topic_svc.set_archived(db, ref, archived=archived)


@mcp.tool
async def list_topic_versions(ref: TopicRef) -> list[TopicVersionOut]:
    """All versions of a topic's question config, newest first."""
    async with _db() as db:
        return await topic_svc.list_versions(db, ref)


@mcp.tool
async def check_topic_version(ref: TopicRef, questions: QuestionList) -> CompatibilityReport:
    """Dry-run a new question list: returns changes, warnings and blocking errors."""
    async with _db() as db:
        return await topic_svc.check_version(db, ref, questions)


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
async def record_session(
    ref: TopicRef,
    answers: AnswerMap,
    source: Annotated[str, Field(min_length=1, max_length=100)] = "mcp",
    captured_at: Annotated[AwareDatetime | None, Field(description="Defaults to now.")] = None,
    notes: str = "",
    meta: Meta | None = None,
) -> SessionOut:
    """Record one set of answers for a topic against its current version."""
    async with _db() as db:
        body = SessionCreate(
            answers=answers, source=source, captured_at=captured_at, notes=notes, meta=meta or {}
        )
        return await session_svc.create_session(db, ref, body, Channel.mcp)


@mcp.tool
async def list_sessions(
    ref: TopicRef,
    captured_from: AwareDatetime | None = None,
    captured_to: AwareDatetime | None = None,
    source: str | None = None,
    limit: Annotated[int, Field(ge=1, le=500)] = 50,
    offset: Annotated[int, Field(ge=0)] = 0,
) -> SessionPage:
    """List sessions for a topic, newest first."""
    async with _db() as db:
        filters = SessionFilters(captured_from=captured_from, captured_to=captured_to, source=source)
        return await session_svc.list_sessions(db, ref, filters, limit=limit, offset=offset)


@mcp.tool
async def update_session(
    session_id: UUID,
    answers: AnswerMap | None = None,
    captured_at: AwareDatetime | None = None,
    notes: str | None = None,
) -> SessionOut:
    """Correct a session. `answers` merges; a null value clears that answer."""
    async with _db() as db:
        return await session_svc.update_session(
            db, session_id, SessionUpdate(answers=answers, captured_at=captured_at, notes=notes)
        )


@mcp.tool
async def delete_session(session_id: UUID) -> str:
    """Permanently delete a session."""
    async with _db() as db:
        await session_svc.delete_session(db, session_id)
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
            db, ref, SessionFilters(captured_from=captured_from, captured_to=captured_to)
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
        return await stats_svc.question_series(db, ref, key, SessionFilters(), bucket=bucket, tz=tz)
