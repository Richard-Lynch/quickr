"""Request/response models for the HTTP API and MCP tools."""

from __future__ import annotations

import re
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Annotated, Literal, Self
from urllib.parse import urlsplit
from uuid import UUID
from zoneinfo import available_timezones

from pydantic import AfterValidator, AwareDatetime, Field, field_validator, model_validator
from pydantic_core import PydanticCustomError

from app.models import Channel, TopicStatus
from app.schemas.base import FieldIssue, Problem, StrictModel, field_error
from app.schemas.limits import (
    CAPTURED_AT_MAX_FUTURE_HOURS,
    CAPTURED_AT_MIN,
    INTERVAL_MAX_MINUTES,
    INTERVAL_MIN_MINUTES,
    MAX_CHANGE_NOTE_LENGTH,
    MAX_DECIMALS,
    MAX_DESCRIPTION_LENGTH,
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
IsoWeekday = Annotated[int, Field(ge=1, le=7, description="ISO weekday: 1 = Monday ... 7 = Sunday.")]
Notify = Annotated[bool, Field(description="Send a push notification when the topic becomes due.")]


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
    every_minutes: Annotated[int, Field(ge=INTERVAL_MIN_MINUTES, le=INTERVAL_MAX_MINUTES)]
    timezone: Timezone
    notify: Notify = True


Schedule = Annotated[DailySchedule | IntervalSchedule, Field(discriminator="kind")]


class DueStatus(StrictModel):
    """Whether a scheduled topic is waiting for an entry. Computed server-side."""

    is_due: bool
    due_since: datetime | None = Field(description="Start of the slot/interval that is overdue.")
    next_due_at: datetime | None = Field(description="When the topic next becomes due.")
    last_entry_at: datetime | None


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


class TopicSummary(StrictModel):
    id: UUID
    slug: str
    name: str
    description: str
    status: TopicStatus
    current_version: int
    question_count: int
    entry_count: int
    last_captured_at: datetime | None
    created_at: datetime
    updated_at: datetime
    archived_at: datetime | None
    schedule: Schedule | None
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
    base_version: int | None = Field(
        default=None,
        ge=1,
        description="Optional: the version this draft was based on. When given and stale, the dry run "
        "fails with 409 just as publishing would.",
    )


class VersionCreate(VersionDraft):
    base_version: int = Field(
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

AnswerMap = Annotated[
    dict[QuestionKey, AnswerValue | None],
    Field(
        description="Map of question key -> value. int questions take integers, double questions "
        "numbers, str questions strings, enum questions an option value, multi-select enum questions "
        "a list of option values. null/absent/empty list = unanswered.",
        examples=[{"hours_slept": 7.5, "quality": "good", "factors": ["caffeine", "screen"]}],
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
    version: int | None = Field(
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


class EntryOut(StrictModel):
    id: UUID
    topic_id: UUID
    version: int
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
    parts = urlsplit(v)
    if parts.scheme != "https" or not parts.netloc:
        raise PydanticCustomError("push_endpoint", "must be an https:// URL from the browser's push service")
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


class PushPayload(StrictModel):
    """JSON body of every push message (consumed by the service worker)."""

    title: str
    body: str
    url: str
    tag: str
    topic_slug: str | None = None
