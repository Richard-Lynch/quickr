from __future__ import annotations

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Path, Query, Response, status
from fastapi.responses import StreamingResponse
from pydantic import AwareDatetime, TypeAdapter
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.identity import ExpectIdentity, identity_headers
from app.db import get_db
from app.models import Channel
from app.schemas.api import (
    ApnsDeviceIn,
    ApnsDeviceOut,
    ApnsDeviceRef,
    Bucket,
    ChangesPage,
    CompatibilityReport,
    EntryCreate,
    EntryFilters,
    EntryOrder,
    EntryOut,
    EntryPage,
    EntryUpdate,
    Limits,
    LiveActivityIn,
    LiveActivityOut,
    LiveActivityRef,
    Problem,
    PushConfig,
    PushSubscriptionDelete,
    PushSubscriptionIn,
    PushSubscriptionOut,
    PushTestResult,
    QuestionSeries,
    QuestionTypeInfo,
    RunEventIn,
    RunEventResult,
    RunListStatus,
    RunOut,
    StatusFilter,
    TopicCreate,
    TopicDetail,
    TopicPage,
    TopicSort,
    TopicStats,
    TopicTiming,
    TopicUpdate,
    TopicVersionOut,
    VersionCreate,
    VersionDraft,
)
from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, StrQuestion
from app.services import changes as changes_svc
from app.services import entries as entry_svc
from app.services import push as push_svc
from app.services import runs as run_svc
from app.services import stats as stats_svc
from app.services import timing as timing_svc
from app.services import topics as topic_svc
from app.services.feed import FeedIdentity
from app.services.push import live_activity

Db = Annotated[AsyncSession, Depends(get_db)]
TopicRef = Annotated[str, Path(description="Topic UUID or slug.", examples=["sleep-log"])]
ExpectedRevision = Annotated[
    int | None,
    Query(
        ge=1,
        description="Optional: the topic revision this change was based on; 409 stale_revision on mismatch.",
    ),
]
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
            "One (or, with multiple, several) of a configured list of options. Options can be "
            "archived, never removed.",
        ),
    ]
    return [
        QuestionTypeInfo(type=t, description=d, json_schema=TypeAdapter(m).json_schema())  # type: ignore[arg-type]
        for t, m, d in specs
    ]


@router.get("/limits", tags=["meta"], operation_id="getLimits")
async def limits() -> Limits:
    """Validation ceilings (lengths, counts, ranges) so clients can mirror server-side validation."""
    return Limits()


# --- topics -----------------------------------------------------------------


@router.get("/topics", tags=["topics"], operation_id="listTopics")
async def list_topics(
    db: Db,
    q: Annotated[
        str | None, Query(max_length=200, description="Search name, slug, description, questions.")
    ] = None,
    status_: Annotated[StatusFilter, Query(alias="status")] = "active",
    sort: Annotated[
        TopicSort,
        Query(
            description="'due' (default): due topics first (longest overdue first), then scheduled topics "
            "by next due time, then the rest by latest activity."
        ),
    ] = "due",
    due_only: Annotated[bool, Query(description="Only topics that are due now.")] = False,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> TopicPage:
    return await topic_svc.list_topics(
        db, q=q, status=status_, sort=sort, due_only=due_only, limit=limit, offset=offset
    )


@router.post(
    "/topics",
    tags=["topics"],
    operation_id="createTopic",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_201_CREATED,
)
async def create_topic(db: Db, body: TopicCreate) -> TopicDetail:
    return await topic_svc.create_topic(db, body)


@router.get("/topics/{ref}", tags=["topics"], operation_id="getTopic")
async def get_topic(db: Db, ref: TopicRef) -> TopicDetail:
    topic = await topic_svc.resolve_topic(db, ref)
    return await topic_svc.topic_detail(db, topic.id)


@router.patch("/topics/{ref}", tags=["topics"], operation_id="updateTopic", dependencies=[ExpectIdentity])
async def update_topic(db: Db, ref: TopicRef, body: TopicUpdate) -> TopicDetail:
    return await topic_svc.update_topic(db, ref, body)


@router.post(
    "/topics/{ref}/archive", tags=["topics"], operation_id="archiveTopic", dependencies=[ExpectIdentity]
)
async def archive_topic(db: Db, ref: TopicRef, expected_revision: ExpectedRevision = None) -> TopicDetail:
    return await topic_svc.set_archived(db, ref, archived=True, expected_revision=expected_revision)


@router.post(
    "/topics/{ref}/unarchive", tags=["topics"], operation_id="unarchiveTopic", dependencies=[ExpectIdentity]
)
async def unarchive_topic(db: Db, ref: TopicRef, expected_revision: ExpectedRevision = None) -> TopicDetail:
    return await topic_svc.set_archived(db, ref, archived=False, expected_revision=expected_revision)


@router.delete(
    "/topics/{ref}",
    tags=["topics"],
    operation_id="deleteTopic",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_204_NO_CONTENT,
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
    return await topic_svc.check_version(
        db,
        ref,
        body.questions,
        body.base_version,
        timer=body.timer,
        with_timer="timer" in body.model_fields_set,
    )


@router.post(
    "/topics/{ref}/versions",
    tags=["versions"],
    operation_id="publishTopicVersion",
    dependencies=[ExpectIdentity],
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
    dependencies=[ExpectIdentity],
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
    identity, gen = await entry_svc.export_csv(db, ref, filters)
    stamp = datetime.now().strftime("%Y%m%d")
    return StreamingResponse(
        gen,
        media_type="text/csv",
        # The export's snapshot identity: the rows stream later, from that same snapshot.
        headers={
            "Content-Disposition": f'attachment; filename="{ref}-{stamp}.csv"',
            **identity_headers(identity),
        },
    )


@router.get("/entries/{entry_id}", tags=["entries"], operation_id="getEntry")
async def get_entry(db: Db, entry_id: UUID) -> EntryOut:
    return await entry_svc.get_entry(db, entry_id)


@router.patch(
    "/entries/{entry_id}",
    tags=["entries"],
    operation_id="updateEntry",
    dependencies=[ExpectIdentity],
)
async def update_entry(db: Db, entry_id: UUID, body: EntryUpdate) -> EntryOut:
    return await entry_svc.update_entry(db, entry_id, body)


@router.delete(
    "/entries/{entry_id}",
    tags=["entries"],
    operation_id="deleteEntry",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_entry(db: Db, entry_id: UUID) -> Response:
    """Delete an entry. Idempotent: an unknown id also returns 204 and is reserved, so the
    entry can never be created afterwards (a later create gets 409 entry_deleted)."""
    await entry_svc.delete_entry(db, entry_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --- runs -------------------------------------------------------------------


@router.post(
    "/runs/{run_id}/events",
    tags=["runs"],
    operation_id="recordRunEvent",
    dependencies=[ExpectIdentity],
    responses={201: {"model": RunEventResult, "description": "The call created the run (or merged it)."}},
)
async def record_run_event(
    db: Db,
    run_id: UUID,
    body: RunEventIn,
    response: Response,
    background: BackgroundTasks,
    channel: ChannelHeader = None,
) -> RunEventResult:
    """Record one tap on a run: start, next, lap, skip, pause, resume, stop, finish or discard.

    Idempotent by event id. An event the fold voids (a double tap, a lap after the stop) is
    stored and answered with 200 and ``effect: "void"``. ``run_id`` may be an alias: the
    event applies to the run it was merged into, and ``run.id`` says which.
    """
    recorded = await run_svc.record_event(db, run_id, body, channel or Channel.api)
    if recorded.created:
        response.status_code = status.HTTP_201_CREATED
    run = recorded.result.run
    created = recorded.created and run.id == run_id  # a merged start created nothing
    background.add_task(run_svc.after_run_event, run.id, run.topic_id, body.device, created=created)
    return recorded.result


@router.get("/runs", tags=["runs"], operation_id="listRuns")
async def list_runs(
    db: Db,
    status_: Annotated[
        list[RunListStatus],
        Query(alias="status", description="open (running or paused) and/or finishing; default both."),
    ] = ["open", "finishing"],  # noqa: B006  # FastAPI copies query defaults
    topic: Annotated[str | None, Query(max_length=64, description="Only this topic (UUID or slug).")] = None,
) -> list[RunOut]:
    """Open and finishing runs, oldest start first. Closed runs are entries."""
    return await run_svc.list_runs(db, status_, topic)


@router.get("/runs/{run_id}", tags=["runs"], operation_id="getRun")
async def get_run(db: Db, run_id: UUID) -> RunOut:
    """One run in any status, with its events and their effects. An alias returns its run."""
    return await run_svc.get_run(db, run_id)


# --- sync -------------------------------------------------------------------


@router.get("/changes", tags=["sync"], operation_id="listChanges")
async def list_changes(
    db: Db,
    response: Response,
    after: Annotated[
        int, Query(ge=0, description="Cursor: the `next` of the previous page (0 = from the start).")
    ] = 0,
    limit: Annotated[int, Query(ge=1, le=changes_svc.MAX_PAGE, description="Change-log rows to read.")] = 500,
) -> ChangesPage:
    """The change feed: every topic, version and entry changed after a cursor, plus deletions.

    Start from ``after=0`` to bootstrap, then follow ``next`` while ``has_more``. When ``epoch``
    changes, or the cursor is above ``head``, rebuild from ``after=0``.
    """
    page = await changes_svc.list_changes(db, after, limit)
    # From the page's snapshot, so the identity headers always match the body.
    response.headers.update(identity_headers(FeedIdentity(epoch=page.epoch, server_id=page.server_id)))
    return page


# --- aggregation ------------------------------------------------------------


@router.get("/topics/{ref}/stats", tags=["stats"], operation_id="getTopicStats")
async def get_stats(db: Db, ref: TopicRef, filters: Filters) -> TopicStats:
    return await stats_svc.topic_stats(db, ref, filters)


@router.get("/topics/{ref}/timing", tags=["stats"], operation_id="getTopicTiming")
async def get_timing(db: Db, ref: TopicRef, filters: Filters) -> TopicTiming:
    """Timing stats over the topic's timed entries (timers.md §9): best, median and mean run
    totals over complete runs, per step, laps, pauses and one series point per run. The filters
    are getTopicStats's; ``version`` keeps that version's runs, labels still come from the latest.
    A topic that isn't timed answers zero counts."""
    return await timing_svc.topic_timing(db, ref, filters)


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


# --- push notifications -----------------------------------------------------


@router.get("/push/config", tags=["push"], operation_id="getPushConfig")
async def push_config(db: Db) -> PushConfig:
    """The VAPID public key to pass to ``PushManager.subscribe({applicationServerKey})``, and
    whether APNs (the iOS app) is configured."""
    keys = await push_svc.get_vapid_keys(db)
    return PushConfig(public_key=keys.public_key, apns_enabled=push_svc.apns_enabled())


@router.post(
    "/push/subscriptions",
    tags=["push"],
    operation_id="createPushSubscription",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_201_CREATED,
)
async def create_push_subscription(db: Db, body: PushSubscriptionIn) -> PushSubscriptionOut:
    """Register (or refresh, keyed by endpoint) a browser push subscription."""
    return await push_svc.subscribe(db, body)


@router.post(
    "/push/subscriptions/delete",
    tags=["push"],
    operation_id="deletePushSubscription",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_push_subscription(db: Db, body: PushSubscriptionDelete) -> Response:
    """Remove a subscription by endpoint (idempotent). POST because DELETE bodies are poorly supported."""
    await push_svc.unsubscribe(db, body.endpoint)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/push/test", tags=["push"], operation_id="sendTestPush", dependencies=[ExpectIdentity])
async def send_test_push(db: Db) -> PushTestResult:
    """Send a test notification to every browser subscription and APNs device."""
    return await push_svc.send_test(db)


@router.post(
    "/push/apns/devices",
    tags=["push"],
    operation_id="registerApnsDevice",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_201_CREATED,
)
async def register_apns_device(db: Db, body: ApnsDeviceIn) -> ApnsDeviceOut:
    """Register (or refresh, keyed by token) the iOS app's APNs device token. Resets its failure
    count. The app calls this on every launch; it works whether or not APNs is enabled."""
    return await push_svc.register_device(db, body)


@router.post(
    "/push/apns/devices/delete",
    tags=["push"],
    operation_id="deleteApnsDevice",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_apns_device(db: Db, body: ApnsDeviceRef) -> Response:
    """Remove a device by token (idempotent)."""
    await push_svc.unregister_device(db, body.token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/push/apns/live-activities",
    tags=["push"],
    operation_id="registerLiveActivity",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_201_CREATED,
)
async def register_live_activity(db: Db, body: LiveActivityIn) -> LiveActivityOut:
    """Register (or refresh, keyed by token) a Live Activity push token: the device's push-to-start
    token (``kind: start``; it replaces the device's older ones), or one activity's update token
    (``kind: update``, with its topic and run). Works whether or not APNs is enabled."""
    return await live_activity.register(db, body)


@router.post(
    "/push/apns/live-activities/delete",
    tags=["push"],
    operation_id="deleteLiveActivity",
    dependencies=[ExpectIdentity],
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_live_activity(db: Db, body: LiveActivityRef) -> Response:
    """Remove a Live Activity token (idempotent)."""
    await live_activity.unregister(db, body.token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/push/apns/devices/test",
    tags=["push"],
    operation_id="sendApnsTestPush",
    dependencies=[ExpectIdentity],
)
async def send_apns_test_push(db: Db, body: ApnsDeviceRef) -> PushTestResult:
    """Send a test notification to this one device ("Test this device"). 404 ``not_found`` for an
    unregistered token; 409 ``apns_disabled`` when APNs is not configured."""
    return await push_svc.send_test_to_device(db, body.token)
