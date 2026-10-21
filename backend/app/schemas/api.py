"""Request/response models for the HTTP API and MCP tools."""

from __future__ import annotations

import re
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Annotated, Literal, Self
from uuid import UUID
from zoneinfo import available_timezones

from pydantic import (
    AfterValidator,
    AwareDatetime,
    Field,
    StrictBool,
    StrictInt,
    WithJsonSchema,
    field_validator,
    model_validator,
)
from pydantic_core import PydanticCustomError

from app.models import Channel, TopicStatus
from app.push_guard import PushEndpointRejected, check_endpoint
from app.schemas.base import FieldIssue, Problem, StrictModel, field_error
from app.schemas.limits import (
    APNS_TOKEN_PATTERN,
    BUNDLE_ID_PATTERN,
    CAPTURED_AT_MAX_FUTURE_HOURS,
    CAPTURED_AT_MIN,
    INTERVAL_MAX_MINUTES,
    INTERVAL_MIN_MINUTES,
    MAX_APP_VERSION_LENGTH,
    MAX_CHANGE_NOTE_LENGTH,
    MAX_DECIMALS,
    MAX_DESCRIPTION_LENGTH,
    MAX_DEVICE_NAME_LENGTH,
    MAX_ENUM_OPTIONS,
    MAX_HELP_TEXT_LENGTH,
    MAX_LABEL_LENGTH,
    MAX_META_ENTRIES,
    MAX_META_KEY_LENGTH,
    MAX_META_VALUE_LENGTH,
    MAX_NOTES_LENGTH,
    MAX_PUSH_ENDPOINT_LENGTH,
    MAX_PUSH_KEY_LENGTH,
    MAX_QUESTIONS,
    MAX_SOURCE_LENGTH,
    MAX_STR_LENGTH,
    MAX_TIMEZONE_LENGTH,
    MAX_TOPIC_NAME_LENGTH,
    MAX_UNIT_LENGTH,
    MAX_USER_AGENT_LENGTH,
    SCHEDULE_MAX_TIMES,
    SLUG_PATTERN,
    TIME_PATTERN,
)
from app.schemas.questions import KEY_PATTERN, AnswerValue, Question, QuestionKey, QuestionList

__all__ = ["FieldIssue", "Problem", "QuestionList"]

_SLUG_RE = re.compile(SLUG_PATTERN)
_TIME_RE = re.compile(TIME_PATTERN)


def _check_slug(v: str) -> str:
    if not _SLUG_RE.fullmatch(v):
        raise PydanticCustomError(
            "slug_format",
            "must start with a lowercase letter or digit and contain only lowercase letters, digits "
            "and hyphens (at most 64 characters)",
        )
    return v


Slug = Annotated[
    str,
    AfterValidator(_check_slug),
    Field(json_schema_extra={"pattern": SLUG_PATTERN}, examples=["sleep-log"]),
]
TopicName = Annotated[str, Field(min_length=1, max_length=MAX_TOPIC_NAME_LENGTH)]
Description = Annotated[str, Field(max_length=MAX_DESCRIPTION_LENGTH)]
Source = Annotated[
    str,
    Field(
        min_length=1,
        max_length=MAX_SOURCE_LENGTH,
        description="Free-form origin of the data, e.g. 'iphone', 'garmin-sync', 'claude'.",
    ),
]
Notes = Annotated[str, Field(max_length=MAX_NOTES_LENGTH)]
Meta = Annotated[
    dict[
        Annotated[str, Field(min_length=1, max_length=MAX_META_KEY_LENGTH)],
        Annotated[str, Field(max_length=MAX_META_VALUE_LENGTH)],
    ],
    Field(max_length=MAX_META_ENTRIES, description="Arbitrary string key/value metadata."),
]


# ---------------------------------------------------------------------------
# Schedules
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def _timezones() -> frozenset[str]:
    return frozenset(available_timezones())


def _check_timezone(v: str) -> str:
    if v not in _timezones():
        raise PydanticCustomError("timezone", "unknown IANA timezone (e.g. 'Europe/London', 'UTC')")
    return v


def _check_time(v: str) -> str:
    if not _TIME_RE.fullmatch(v):
        raise PydanticCustomError("time_format", "must be a 24-hour time HH:MM, e.g. '08:00'")
    return v


Timezone = Annotated[
    str,
    Field(
        min_length=1,
        max_length=MAX_TIMEZONE_LENGTH,
        examples=["Europe/London"],
        description="IANA timezone the schedule is evaluated in.",
    ),
    AfterValidator(_check_timezone),
]
TimeOfDay = Annotated[
    str, AfterValidator(_check_time), Field(json_schema_extra={"pattern": TIME_PATTERN}, examples=["08:00"])
]
IsoWeekday = Annotated[StrictInt, Field(ge=1, le=7, description="ISO weekday: 1 = Monday ... 7 = Sunday.")]
Notify = Annotated[StrictBool, Field(description="Send a push notification when the topic becomes due.")]


class DailySchedule(StrictModel):
    """Due at fixed local times on selected weekdays."""

    kind: Literal["daily"] = "daily"
    times: Annotated[
        list[TimeOfDay],
        Field(min_length=1, max_length=SCHEDULE_MAX_TIMES, description="Local times; stored sorted."),
    ]
    days: Annotated[list[IsoWeekday], Field(min_length=1, max_length=7)] = [1, 2, 3, 4, 5, 6, 7]
    timezone: Timezone
    notify: Notify = True

    @model_validator(mode="after")
    def _normalise(self) -> Self:
        for i, t in enumerate(self.times):
            if t in self.times[:i]:
                raise field_error(f"times.{i}", f"duplicate time '{t}'")
        for i, d in enumerate(self.days):
            if d in self.days[:i]:
                raise field_error(f"days.{i}", f"duplicate day {d}")
        self.times = sorted(self.times)
        self.days = sorted(self.days)
        return self


class IntervalSchedule(StrictModel):
    """Due ``every_minutes`` after the latest entry."""

    kind: Literal["interval"] = "interval"
    every_minutes: Annotated[StrictInt, Field(ge=INTERVAL_MIN_MINUTES, le=INTERVAL_MAX_MINUTES)]
    timezone: Timezone
    notify: Notify = True


Schedule = Annotated[DailySchedule | IntervalSchedule, Field(discriminator="kind")]


class DueStatus(StrictModel):
    """Whether a scheduled topic is waiting for an entry. Computed server-side."""

    is_due: bool
    due_since: datetime | None = Field(description="Start of the slot/interval that is overdue.")
    next_due_at: datetime | None = Field(description="When the topic next becomes due.")
    last_entry_at: datetime | None


ExpectedRevision = Annotated[
    StrictInt | None,
    Field(
        ge=1,
        description="Optional optimistic-concurrency guard: the revision this change was based on. "
        "When it no longer matches, the change is rejected with 409 stale_revision.",
    ),
]


# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------


class TopicCreate(StrictModel):
    name: TopicName
    slug: Slug | None = Field(default=None, description="Derived from name when omitted.")
    description: Description = ""
    questions: QuestionList
    schedule: Schedule | None = Field(default=None, description="When entries are expected (optional).")


class TopicUpdate(StrictModel):
    """Metadata-only update. Omitted fields are unchanged; ``schedule: null`` clears the schedule.

    Questions change via versions.
    """

    name: TopicName | None = None
    slug: Slug | None = None
    description: Description | None = None
    schedule: Schedule | None = None
    expected_revision: ExpectedRevision = None


class TopicSummary(StrictModel):
    id: UUID
    slug: str
    name: str
    description: str
    status: TopicStatus
    current_version: int
    revision: int = Field(description="Bumped on every change to the topic's own fields.")
    question_count: int
    entry_count: int
    last_captured_at: datetime | None
    created_at: datetime
    updated_at: datetime
    archived_at: datetime | None
    schedule: Schedule | None
    schedule_updated_at: datetime | None = Field(
        description="When the schedule was last set or changed; due status ignores anything before it."
    )
    due: DueStatus | None = Field(description="Null when the topic has no schedule.")


class TopicDetail(TopicSummary):
    questions: list[Question]


class TopicPage(StrictModel):
    items: list[TopicSummary]
    total: int
    limit: int
    offset: int


TopicSort = Literal[
    "due",
    "updated",
    "-updated",
    "name",
    "-name",
    "created",
    "-created",
    "activity",
    "-activity",
]
StatusFilter = Literal["active", "archived", "all"]


# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------


class VersionDraft(StrictModel):
    questions: QuestionList
    base_version: StrictInt | None = Field(
        default=None,
        ge=1,
        description="Optional: the version this draft was based on. When given and stale, the dry run "
        "fails with 409 just as publishing would.",
    )


class VersionCreate(VersionDraft):
    base_version: StrictInt = Field(
        ge=1,
        description="The version this edit was based on. Must equal the topic's current version "
        "(optimistic concurrency); otherwise 409.",
    )
    change_note: Annotated[str, Field(max_length=MAX_CHANGE_NOTE_LENGTH)] = ""


class TopicVersionOut(StrictModel):
    version: int
    questions: list[Question]
    change_note: str
    created_at: datetime
    entry_count: int


IssueLevel = Literal["error", "warning", "info"]
ChangeKind = Literal["added", "removed", "modified", "restored", "reordered"]


class CompatibilityIssue(StrictModel):
    level: IssueLevel
    question_key: str | None
    message: str


class QuestionChange(StrictModel):
    kind: ChangeKind
    question_key: str
    details: list[str] = []


class CompatibilityReport(StrictModel):
    ok: bool = Field(description="True when the draft can be published.")
    next_version: int
    issues: list[CompatibilityIssue]
    changes: list[QuestionChange]


# ---------------------------------------------------------------------------
# Entries & answers
# ---------------------------------------------------------------------------


class IntAnswer(StrictModel):
    key: str
    type: Literal["int"] = "int"
    value: int


class DoubleAnswer(StrictModel):
    key: str
    type: Literal["double"] = "double"
    value: float


class StrAnswer(StrictModel):
    key: str
    type: Literal["str"] = "str"
    value: str


class EnumAnswer(StrictModel):
    """Answer to a single-select enum question."""

    key: str
    type: Literal["enum"] = "enum"
    value: str


class EnumListAnswer(StrictModel):
    """Answer to a multi-select enum question (option values in option order)."""

    key: str
    type: Literal["enum_list"] = "enum_list"
    value: list[str]


AnswerOut = Annotated[
    IntAnswer | DoubleAnswer | StrAnswer | EnumAnswer | EnumListAnswer, Field(discriminator="type")
]

# The schema is spelled out: pydantic would emit ``patternProperties`` (from the key
# pattern), which code generators such as swift-openapi-generator drop. Validation is
# unchanged; ``number`` covers integers, so there is no separate integer branch.
AnswerMap = Annotated[
    dict[QuestionKey, AnswerValue | None],
    WithJsonSchema(
        {
            "type": "object",
            "propertyNames": {"pattern": KEY_PATTERN},
            "additionalProperties": {
                "anyOf": [
                    {"type": "number"},
                    {"type": "string"},
                    {"type": "array", "items": {"type": "string"}},
                    {"type": "null"},
                ]
            },
            "description": "Map of question key -> value. int questions take integers, double "
            "questions numbers, str questions strings, enum questions an option value, multi-select "
            "enum questions a list of option values. null/absent/empty list = unanswered.",
            "examples": [{"hours_slept": 7.5, "quality": "good", "factors": ["caffeine", "screen"]}],
        }
    ),
]


def check_captured_at(v: datetime | None, now: datetime | None = None) -> datetime | None:
    if v is None:
        return v
    if v < CAPTURED_AT_MIN:
        raise PydanticCustomError("captured_at_range", "must not be before 2000-01-01")
    now = now or datetime.now(UTC)
    if v > now + timedelta(hours=CAPTURED_AT_MAX_FUTURE_HOURS):
        raise PydanticCustomError(
            "captured_at_range", f"must not be more than {CAPTURED_AT_MAX_FUTURE_HOURS} hours in the future"
        )
    return v


CapturedAt = Annotated[
    AwareDatetime | None,
    AfterValidator(check_captured_at),
    Field(
        description="When the observation happened, in the client's clock (timezone-aware). May be "
        "in the past (offline/late submissions) but not more than 24h ahead or before 2000-01-01.",
    ),
]


class EntryCreate(StrictModel):
    id: UUID | None = Field(
        default=None,
        description="Client-generated id, for idempotent/offline-safe submission. Re-sending an entry "
        "with the same id for the same topic returns the existing entry (201) instead of a duplicate; "
        "the same id under another topic is a 409.",
    )
    answers: AnswerMap
    source: Source | None = Field(default=None, description="Defaults to the channel name.")
    captured_at: CapturedAt = None
    notes: Notes = ""
    meta: Meta = {}
    version: StrictInt | None = Field(
        default=None,
        ge=1,
        description="Topic version the answers were written against. Defaults to current.",
    )


class EntryUpdate(StrictModel):
    """Partial update. ``answers`` merges into existing answers; a null value clears an answer."""

    answers: AnswerMap | None = None
    source: Source | None = None
    captured_at: CapturedAt = None
    notes: Notes | None = None
    meta: Meta | None = None
    expected_revision: ExpectedRevision = None


class EntryOut(StrictModel):
    id: UUID
    topic_id: UUID
    version: int
    revision: int = Field(description="Bumped on every update.")
    source: str
    channel: Channel
    captured_at: datetime
    created_at: datetime
    updated_at: datetime
    notes: str
    meta: dict[str, str]
    answers: list[AnswerOut]


class EntryPage(StrictModel):
    items: list[EntryOut]
    total: int
    limit: int
    offset: int


EntryOrder = Literal["captured_at", "-captured_at", "created_at", "-created_at"]


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------


class HistogramBin(StrictModel):
    lower: float
    upper: float
    count: int


class NumericStats(StrictModel):
    key: str
    label: str
    type: Literal["int", "double"]
    count: int
    missing: int
    min: float | None
    max: float | None
    mean: float | None
    median: float | None
    stddev: float | None
    sum: float | None
    histogram: list[HistogramBin]


class ValueCount(StrictModel):
    value: str
    count: int


class RecentText(StrictModel):
    entry_id: UUID
    value: str
    captured_at: datetime


class StrStats(StrictModel):
    key: str
    label: str
    type: Literal["str"]
    count: int
    missing: int
    distinct: int
    top: list[ValueCount]
    recent: list[RecentText]


class EnumOptionCount(StrictModel):
    value: str
    label: str
    archived: bool
    count: int = Field(description="Answered entries that selected this option.")
    share: float = Field(
        description="count / answered entries (0-1). Multi-select shares can sum to more than 1."
    )


class EnumStats(StrictModel):
    key: str
    label: str
    type: Literal["enum"]
    multiple: bool = Field(description="Whether the question (as currently configured) is multi-select.")
    count: int
    missing: int
    options: list[EnumOptionCount]


QuestionStats = Annotated[NumericStats | StrStats | EnumStats, Field(discriminator="type")]


class TopicStats(StrictModel):
    topic_id: UUID
    entry_count: int
    first_captured_at: datetime | None
    last_captured_at: datetime | None
    sources: list[ValueCount]
    questions: list[QuestionStats] = Field(
        description="One entry per question in the current version plus any historic questions with data."
    )


Bucket = Literal["day", "week", "month"]


class SeriesPoint(StrictModel):
    start: datetime
    count: int
    mean: float | None = None
    min: float | None = None
    max: float | None = None
    option_counts: dict[str, int] = Field(
        default={}, description="Enum questions: entries in the bucket that selected each option."
    )


class QuestionSeries(StrictModel):
    key: str
    type: Literal["int", "double", "str", "enum"]
    bucket: Bucket
    points: list[SeriesPoint]


class EntryFilters(StrictModel):
    captured_from: AwareDatetime | None = None
    captured_to: AwareDatetime | None = None
    version: int | None = None
    source: str | None = None
    channel: Channel | None = None


# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------


class QuestionTypeInfo(StrictModel):
    type: Literal["int", "double", "str", "enum"]
    description: str
    json_schema: dict[str, object]


class Limits(StrictModel):
    """Validation ceilings, so clients can mirror server-side validation without hard-coding."""

    key_pattern: str = KEY_PATTERN
    slug_pattern: str = SLUG_PATTERN
    time_pattern: str = TIME_PATTERN
    max_questions: int = MAX_QUESTIONS
    max_enum_options: int = MAX_ENUM_OPTIONS
    max_str_length: int = MAX_STR_LENGTH
    max_label_length: int = MAX_LABEL_LENGTH
    max_help_text_length: int = MAX_HELP_TEXT_LENGTH
    max_unit_length: int = MAX_UNIT_LENGTH
    max_decimals: int = MAX_DECIMALS
    max_topic_name_length: int = MAX_TOPIC_NAME_LENGTH
    max_description_length: int = MAX_DESCRIPTION_LENGTH
    max_change_note_length: int = MAX_CHANGE_NOTE_LENGTH
    max_source_length: int = MAX_SOURCE_LENGTH
    max_notes_length: int = MAX_NOTES_LENGTH
    max_meta_entries: int = MAX_META_ENTRIES
    max_meta_key_length: int = MAX_META_KEY_LENGTH
    max_meta_value_length: int = MAX_META_VALUE_LENGTH
    captured_at_min: datetime = CAPTURED_AT_MIN
    captured_at_max_future_hours: int = CAPTURED_AT_MAX_FUTURE_HOURS
    schedule_max_times: int = SCHEDULE_MAX_TIMES
    interval_min_minutes: int = INTERVAL_MIN_MINUTES
    interval_max_minutes: int = INTERVAL_MAX_MINUTES


# ---------------------------------------------------------------------------
# Push notifications
# ---------------------------------------------------------------------------


def _check_endpoint(v: str) -> str:
    try:
        check_endpoint(v)
    except PushEndpointRejected as exc:
        raise PydanticCustomError("push_endpoint", str(exc).replace("{", "{{").replace("}", "}}")) from None
    return v


PushEndpoint = Annotated[
    str, Field(min_length=1, max_length=MAX_PUSH_ENDPOINT_LENGTH), AfterValidator(_check_endpoint)
]
PushKey = Annotated[str, Field(min_length=1, max_length=MAX_PUSH_KEY_LENGTH)]


class PushConfig(StrictModel):
    public_key: str = Field(
        description="VAPID public key (base64url, uncompressed P-256 point): the applicationServerKey "
        "for PushManager.subscribe()."
    )
    apns_enabled: bool = Field(
        description="Whether this server can send APNs notifications (to the iOS app). When false, "
        "devices can still register, but nothing is sent to them."
    )


class PushKeys(StrictModel):
    p256dh: PushKey
    auth: PushKey


class PushSubscriptionIn(StrictModel):
    """A browser PushSubscription (``subscription.toJSON()``), upserted by endpoint."""

    endpoint: PushEndpoint
    keys: PushKeys
    user_agent: Annotated[str | None, Field(max_length=MAX_USER_AGENT_LENGTH)] = None

    @field_validator("user_agent")
    @classmethod
    def _blank_is_none(cls, v: str | None) -> str | None:
        return v or None


class PushSubscriptionOut(StrictModel):
    id: UUID
    endpoint: str
    created_at: datetime


class PushSubscriptionDelete(StrictModel):
    endpoint: Annotated[str, Field(min_length=1, max_length=MAX_PUSH_ENDPOINT_LENGTH)]


class PushTestResult(StrictModel):
    sent: int
    failed: int


class QuickLogOption(StrictModel):
    value: str
    label: str


class QuickLogEnum(StrictModel):
    """A single-select enum a notification can log: the options it offers as actions.

    With 1-4 active options, all of them, in question order. With 5-6, the 3 most-used
    (most-used first, ties in question order), and a "More…" action opens the record
    screen (docs/ios/specs/notifications.md §2.3).
    """

    type: Literal["enum"] = "enum"
    key: str
    label: str
    options: list[QuickLogOption]
    total_options: int  # the number of active options


class QuickLogNumber(StrictModel):
    """An int or double question a notification can log, with its latest valid value."""

    type: Literal["int", "double"]
    key: str
    label: str
    unit: str | None
    min: int | float | None
    max: int | float | None
    decimals: int | None
    last_value: int | float | None


type QuickLogDescriptor = QuickLogEnum | QuickLogNumber


class QuickLogSingle(StrictModel):
    """A topic with no questions (a "single" topic): its reminder logs it with one action,
    "Log it", an entry with no answers. Web Push only: the APNs payload keeps ``quick_log``
    null for these topics.
    """

    type: Literal["single"] = "single"


class PushPayload(StrictModel):
    """JSON body of every Web Push message (consumed by the service worker).

    The first five fields are the original contract. The rest carry the actionable
    fields, with the same shapes as the APNs payload's ``quickr`` dict (null on a test
    push); older service workers ignore them.
    """

    title: str
    body: str
    url: str
    tag: str
    topic_slug: str | None = None
    v: int = 1
    kind: Literal["due", "test"] = "due"
    server_id: str | None = None
    topic_id: str | None = None
    version: int | None = None
    due_since: str | None = None  # canonical: UTC, whole seconds, "Z"
    quick_log: QuickLogEnum | QuickLogNumber | QuickLogSingle | None = None


ApnsToken = Annotated[
    str,
    Field(pattern=APNS_TOKEN_PATTERN, description="The APNs device token, hex (stored lower-case)."),
    AfterValidator(str.lower),
]
ApnsEnvironment = Literal["sandbox", "production"]


class ApnsDeviceIn(StrictModel):
    """An iOS app install's APNs registration, upserted by token (sent on every launch)."""

    token: ApnsToken
    environment: ApnsEnvironment = Field(
        description="The APNs host the token belongs to: sandbox for debug builds, production for "
        "TestFlight and App Store builds."
    )
    bundle_id: Annotated[str | None, Field(pattern=BUNDLE_ID_PATTERN)] = None
    app_version: Annotated[str | None, Field(max_length=MAX_APP_VERSION_LENGTH)] = None
    device_name: Annotated[str | None, Field(max_length=MAX_DEVICE_NAME_LENGTH)] = None

    @field_validator("app_version", "device_name")
    @classmethod
    def _blank_is_none(cls, v: str | None) -> str | None:
        return v or None


class ApnsDeviceOut(StrictModel):
    id: UUID
    token: str
    environment: ApnsEnvironment
    bundle_id: str | None
    app_version: str | None
    device_name: str | None
    created_at: datetime
    updated_at: datetime


class ApnsDeviceRef(StrictModel):
    """One device, by token (unregister, test)."""

    token: ApnsToken


# ---------------------------------------------------------------------------
# Change feed
# ---------------------------------------------------------------------------


class FeedEntry(StrictModel):
    kind: Literal["entry"] = "entry"
    seq: int
    entry: EntryOut


class FeedTopic(StrictModel):
    """A topic's current state. Its derived fields (``entry_count``, ``last_captured_at``,
    ``due``) are not re-sent when entries change: clients recompute them from entries."""

    kind: Literal["topic"] = "topic"
    seq: int
    topic: TopicDetail


class FeedVersion(StrictModel):
    """A published question version (immutable; ``version.entry_count`` is as of this page)."""

    kind: Literal["version"] = "version"
    seq: int
    id: UUID
    topic_id: UUID
    version: TopicVersionOut


FeedItem = Annotated[FeedEntry | FeedTopic | FeedVersion, Field(discriminator="kind")]


class FeedDeletion(StrictModel):
    """A permanently deleted id. A topic deletion also deletes all of its versions and entries."""

    kind: Literal["entry", "topic", "version"]
    seq: int
    id: UUID
    topic_id: UUID
    deleted_at: datetime


class ChangesPage(StrictModel):
    """One page of the change feed, read from a single consistent snapshot.

    Each changed entity appears once, in its latest state (``items``) or as a deletion
    (``deleted``). Apply ``items`` in order (topics, then versions, then entries), then
    ``deleted`` (entries, then versions, then topics), then store ``next`` as the cursor.
    """

    items: list[FeedItem]
    deleted: list[FeedDeletion]
    next: int = Field(description="Cursor for the next page: the highest seq in this page.")
    has_more: bool
    head: int = Field(
        description="The server's highest seq. A client cursor above it means the database was "
        "restored or reset: treat it like an epoch change."
    )
    epoch: str = Field(
        description="Changes when the database is restored or reset. On a mismatch, rebuild from after=0."
    )
    server_id: str = Field(description="Stable random id of this server (one local store per server).")
    server_time: datetime
