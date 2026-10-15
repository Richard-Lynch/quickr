from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Path, Query, Response, status
from fastapi.responses import StreamingResponse
from pydantic import AwareDatetime, TypeAdapter
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Channel
from app.schemas.api import (
    Bucket,
    CompatibilityReport,
    EntryCreate,
    EntryFilters,
    EntryOrder,
    EntryOut,
    EntryPage,
    EntryUpdate,
    Problem,
    QuestionSeries,
    QuestionTypeInfo,
    StatusFilter,
    TopicCreate,
    TopicDetail,
    TopicPage,
    TopicSort,
    TopicStats,
    TopicUpdate,
    TopicVersionOut,
    VersionCreate,
    VersionDraft,
)
from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, StrQuestion
from app.services import entries as entry_svc
from app.services import stats as stats_svc
from app.services import topics as topic_svc

Db = Annotated[AsyncSession, Depends(get_db)]
TopicRef = Annotated[str, Path(description="Topic UUID or slug.", examples=["sleep-log"])]
ChannelHeader = Annotated[
    Channel | None,
    Header(alias="X-QuickR-Channel", description="Client channel; defaults to 'api'."),
]

ERRORS: dict[int | str, dict[str, object]] = {
    400: {"model": Problem},
    404: {"model": Problem},
    409: {"model": Problem},
    # Replaces FastAPI's default HTTPValidationError: every error uses one envelope.
    422: {"model": Problem},
}

router = APIRouter(responses=ERRORS)


def entry_filters(
    captured_from: Annotated[AwareDatetime | None, Query(description="Inclusive lower bound.")] = None,
    captured_to: Annotated[AwareDatetime | None, Query(description="Exclusive upper bound.")] = None,
    version: Annotated[int | None, Query(ge=1)] = None,
    source: Annotated[str | None, Query(max_length=100)] = None,
    channel: Channel | None = None,
) -> EntryFilters:
    return EntryFilters(
        captured_from=captured_from,
        captured_to=captured_to,
        version=version,
        source=source,
        channel=channel,
    )


Filters = Annotated[EntryFilters, Depends(entry_filters)]


# --- meta -------------------------------------------------------------------


@router.get("/health", tags=["meta"], operation_id="health")
async def health(db: Db) -> dict[str, str]:
    await db.execute(text("select 1"))
    return {"status": "ok"}


@router.get("/question-types", tags=["meta"], operation_id="listQuestionTypes")
async def question_types() -> list[QuestionTypeInfo]:
    """Describe every supported question type and its constraint schema."""
    specs = [
        ("int", IntQuestion, "Whole number, optional inclusive min/max and unit."),
        ("double", DoubleQuestion, "Decimal number, optional inclusive min/max, decimals hint and unit."),
        ("str", StrQuestion, "Free text with min/max length; multiline renders a textarea."),
        (
            "enum",
            EnumQuestion,
            "One of a configured list of options. Options can be archived, never removed.",
        ),
    ]
    return [
        QuestionTypeInfo(type=t, description=d, json_schema=TypeAdapter(m).json_schema())  # type: ignore[arg-type]
        for t, m, d in specs
    ]


# --- topics -----------------------------------------------------------------


@router.get("/topics", tags=["topics"], operation_id="listTopics")
async def list_topics(
    db: Db,
    q: Annotated[
        str | None, Query(max_length=200, description="Search name, slug, description, questions.")
    ] = None,
    status_: Annotated[StatusFilter, Query(alias="status")] = "active",
    sort: TopicSort = "-activity",
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TopicPage:
    return await topic_svc.list_topics(db, q=q, status=status_, sort=sort, limit=limit, offset=offset)


@router.post("/topics", tags=["topics"], operation_id="createTopic", status_code=status.HTTP_201_CREATED)
async def create_topic(db: Db, body: TopicCreate) -> TopicDetail:
    return await topic_svc.create_topic(db, body)


@router.get("/topics/{ref}", tags=["topics"], operation_id="getTopic")
async def get_topic(db: Db, ref: TopicRef) -> TopicDetail:
    topic = await topic_svc.resolve_topic(db, ref)
    return await topic_svc.topic_detail(db, topic.id)


@router.patch("/topics/{ref}", tags=["topics"], operation_id="updateTopic")
async def update_topic(db: Db, ref: TopicRef, body: TopicUpdate) -> TopicDetail:
    return await topic_svc.update_topic(db, ref, body)


@router.post("/topics/{ref}/archive", tags=["topics"], operation_id="archiveTopic")
async def archive_topic(db: Db, ref: TopicRef) -> TopicDetail:
    return await topic_svc.set_archived(db, ref, archived=True)


@router.post("/topics/{ref}/unarchive", tags=["topics"], operation_id="unarchiveTopic")
async def unarchive_topic(db: Db, ref: TopicRef) -> TopicDetail:
    return await topic_svc.set_archived(db, ref, archived=False)


@router.delete(
    "/topics/{ref}", tags=["topics"], operation_id="deleteTopic", status_code=status.HTTP_204_NO_CONTENT
)
async def delete_topic(db: Db, ref: TopicRef) -> Response:
    """Permanently delete an archived topic and all its data."""
    await topic_svc.delete_topic(db, ref)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- versions ---------------------------------------------------------------


@router.get("/topics/{ref}/versions", tags=["versions"], operation_id="listTopicVersions")
async def list_versions(db: Db, ref: TopicRef) -> list[TopicVersionOut]:
    return await topic_svc.list_versions(db, ref)


@router.post("/topics/{ref}/versions/check", tags=["versions"], operation_id="checkTopicVersion")
async def check_version(db: Db, ref: TopicRef, body: VersionDraft) -> CompatibilityReport:
    """Dry-run: report what publishing these questions would change, and whether it is allowed."""
    return await topic_svc.check_version(db, ref, body.questions, body.base_version)


@router.post(
    "/topics/{ref}/versions",
    tags=["versions"],
    operation_id="publishTopicVersion",
    status_code=status.HTTP_201_CREATED,
)
async def publish_version(db: Db, ref: TopicRef, body: VersionCreate) -> TopicDetail:
    return await topic_svc.publish_version(db, ref, body)


# --- entries ---------------------------------------------------------------


@router.get("/topics/{ref}/entries", tags=["entries"], operation_id="listEntries")
async def list_entries(
    db: Db,
    ref: TopicRef,
    filters: Filters,
    order: EntryOrder = "-captured_at",
    limit: Annotated[int, Query(ge=1, le=500)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> EntryPage:
    return await entry_svc.list_entries(db, ref, filters, order=order, limit=limit, offset=offset)


@router.post(
    "/topics/{ref}/entries",
    tags=["entries"],
    operation_id="createEntry",
    status_code=status.HTTP_201_CREATED,
)
async def create_entry(db: Db, ref: TopicRef, body: EntryCreate, channel: ChannelHeader = None) -> EntryOut:
    return await entry_svc.create_entry(db, ref, body, channel or Channel.api)


@router.get(
    "/topics/{ref}/entries.csv",
    tags=["entries"],
    operation_id="exportEntriesCsv",
    response_class=StreamingResponse,
    responses={200: {"content": {"text/csv": {"schema": {"type": "string"}}}}},
)
async def export_entries(db: Db, ref: TopicRef, filters: Filters) -> StreamingResponse:
    gen = await entry_svc.export_csv(db, ref, filters)
    stamp = datetime.now().strftime("%Y%m%d")
    return StreamingResponse(
        gen,
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{ref}-{stamp}.csv"'},
    )


@router.get("/entries/{entry_id}", tags=["entries"], operation_id="getEntry")
async def get_entry(db: Db, entry_id: UUID) -> EntryOut:
    return await entry_svc.get_entry(db, entry_id)


@router.patch(
    "/entries/{entry_id}",
    tags=["entries"],
    operation_id="updateEntry",
)
async def update_entry(db: Db, entry_id: UUID, body: EntryUpdate) -> EntryOut:
    return await entry_svc.update_entry(db, entry_id, body)


@router.delete(
    "/entries/{entry_id}",
    tags=["entries"],
    operation_id="deleteEntry",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_entry(db: Db, entry_id: UUID) -> Response:
    await entry_svc.delete_entry(db, entry_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- aggregation ------------------------------------------------------------


@router.get("/topics/{ref}/stats", tags=["stats"], operation_id="getTopicStats")
async def get_stats(db: Db, ref: TopicRef, filters: Filters) -> TopicStats:
    return await stats_svc.topic_stats(db, ref, filters)


@router.get("/topics/{ref}/questions/{key}/series", tags=["stats"], operation_id="getQuestionSeries")
async def get_series(
    db: Db,
    ref: TopicRef,
    key: str,
    filters: Filters,
    bucket: Bucket = "day",
    tz: Annotated[str, Query(max_length=64, description="IANA timezone for bucketing.")] = "UTC",
) -> QuestionSeries:
    return await stats_svc.question_series(db, ref, key, filters, bucket=bucket, tz=tz)
