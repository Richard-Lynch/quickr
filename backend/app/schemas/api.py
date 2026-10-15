"""Request/response models for the HTTP API and MCP tools."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AwareDatetime, Field

from app.models import Channel, TopicStatus
from app.schemas.questions import AnswerValue, Question, QuestionKey, StrictModel

SLUG_PATTERN = r"^[a-z0-9][a-z0-9-]{0,63}$"
Slug = Annotated[str, Field(pattern=SLUG_PATTERN, examples=["sleep-log"])]
TopicName = Annotated[str, Field(min_length=1, max_length=200)]
Description = Annotated[str, Field(max_length=5000)]
Source = Annotated[
    str,
    Field(
        min_length=1,
        max_length=100,
        description="Free-form origin of the data, e.g. 'iphone', 'garmin-sync', 'claude'.",
    ),
]
Notes = Annotated[str, Field(max_length=5000)]
Meta = Annotated[
    dict[Annotated[str, Field(max_length=64)], Annotated[str, Field(max_length=500)]],
    Field(max_length=50, description="Arbitrary string key/value metadata."),
]
QuestionList = Annotated[list[Question], Field(min_length=1, max_length=100)]


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class FieldIssue(StrictModel):
    loc: list[str | int]
    message: str


class Problem(StrictModel):
    """Error envelope for all domain errors (4xx other than request-shape 422s)."""

    code: str = Field(examples=["not_found"])
    detail: str
    errors: list[FieldIssue] = []


# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------


class TopicCreate(StrictModel):
    name: TopicName
    slug: Slug | None = Field(default=None, description="Derived from name when omitted.")
    description: Description = ""
    questions: QuestionList


class TopicUpdate(StrictModel):
    """Metadata-only update. Omitted fields are unchanged. Questions change via versions."""

    name: TopicName | None = None
    slug: Slug | None = None
    description: Description | None = None


class TopicSummary(StrictModel):
    id: UUID
    slug: str
    name: str
    description: str
    status: TopicStatus
    current_version: int
    question_count: int
    session_count: int
    last_captured_at: datetime | None
    created_at: datetime
    updated_at: datetime
    archived_at: datetime | None


class TopicDetail(TopicSummary):
    questions: list[Question]


class TopicPage(StrictModel):
    items: list[TopicSummary]
    total: int
    limit: int
    offset: int


TopicSort = Literal[
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


class VersionCreate(VersionDraft):
    base_version: int = Field(
        ge=1,
        description="The version this edit was based on. Must equal the topic's current version "
        "(optimistic concurrency); otherwise 409.",
    )
    change_note: Annotated[str, Field(max_length=2000)] = ""


class TopicVersionOut(StrictModel):
    version: int
    questions: list[Question]
    change_note: str
    created_at: datetime
    session_count: int


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
# Sessions & answers
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
    key: str
    type: Literal["enum"] = "enum"
    value: str


AnswerOut = Annotated[IntAnswer | DoubleAnswer | StrAnswer | EnumAnswer, Field(discriminator="type")]

AnswerMap = Annotated[
    dict[QuestionKey, AnswerValue | None],
    Field(
        description="Map of question key -> value. int questions take integers, double questions "
        "numbers, str questions strings, enum questions an option value. null/absent = unanswered.",
        examples=[{"hours_slept": 7.5, "quality": "good"}],
    ),
]


class SessionCreate(StrictModel):
    answers: AnswerMap
    source: Source | None = Field(default=None, description="Defaults to the channel name.")
    captured_at: AwareDatetime | None = Field(
        default=None,
        description="When the observation happened (timezone-aware). Defaults to now.",
    )
    notes: Notes = ""
    meta: Meta = {}
    version: int | None = Field(
        default=None,
        ge=1,
        description="Topic version the answers were written against. Defaults to current.",
    )


class SessionUpdate(StrictModel):
    """Partial update. ``answers`` merges into existing answers; a null value clears an answer."""

    answers: AnswerMap | None = None
    source: Source | None = None
    captured_at: AwareDatetime | None = None
    notes: Notes | None = None
    meta: Meta | None = None


class SessionOut(StrictModel):
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


class SessionPage(StrictModel):
    items: list[SessionOut]
    total: int
    limit: int
    offset: int


SessionOrder = Literal["captured_at", "-captured_at", "created_at", "-created_at"]


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
    session_id: UUID
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
    count: int
    share: float = Field(description="Fraction of answered sessions (0-1).")


class EnumStats(StrictModel):
    key: str
    label: str
    type: Literal["enum"]
    count: int
    missing: int
    options: list[EnumOptionCount]


QuestionStats = Annotated[NumericStats | StrStats | EnumStats, Field(discriminator="type")]


class TopicStats(StrictModel):
    topic_id: UUID
    session_count: int
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
    option_counts: dict[str, int] = {}


class QuestionSeries(StrictModel):
    key: str
    type: Literal["int", "double", "str", "enum"]
    bucket: Bucket
    points: list[SeriesPoint]


class SessionFilters(StrictModel):
    captured_from: AwareDatetime | None = None
    captured_to: AwareDatetime | None = None
    version: int | None = None
    source: str | None = None
    channel: Channel | None = None


class QuestionTypeInfo(StrictModel):
    type: Literal["int", "double", "str", "enum"]
    description: str
    json_schema: dict[str, object]
