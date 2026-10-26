"""SQLAlchemy ORM models.

Topic versions are immutable snapshots of a topic's question config. Every
entry is pinned to the version it was recorded against, so historic answers
always remain interpretable even as a topic evolves.
"""

from __future__ import annotations

import enum
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Double,
    Enum,
    ForeignKey,
    Identity,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class TopicStatus(enum.StrEnum):
    active = "active"
    archived = "archived"


class Channel(enum.StrEnum):
    """How an entry reached the system. Set server-side."""

    ui = "ui"
    api = "api"
    mcp = "mcp"
    ios = "ios"


class Topic(Base):
    __tablename__ = "topics"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    slug: Mapped[str] = mapped_column(String(64), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text, default="")
    status: Mapped[TopicStatus] = mapped_column(
        Enum(TopicStatus, name="topic_status", native_enum=True), default=TopicStatus.active
    )
    current_version: Mapped[int] = mapped_column(Integer, default=1)
    # Bumped on every change to the topic's own fields (optimistic concurrency, see feed).
    revision: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    # Validated Schedule payload (not versioned); null = unscheduled.
    schedule: Mapped[dict[str, Any] | None] = mapped_column(JSONB, default=None)
    # When the schedule was last set/changed: the reference point for due status.
    schedule_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    # due_since of the last slot a push notification was sent for (scheduler dedupe).
    last_notified_due_since: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)

    versions: Mapped[list[TopicVersion]] = relationship(
        back_populates="topic", cascade="all, delete-orphan", order_by="TopicVersion.version"
    )

    __table_args__ = (Index("ix_topics_status_updated", "status", "updated_at"),)


class TopicVersion(Base):
    __tablename__ = "topic_versions"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    topic_id: Mapped[UUID] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"))
    version: Mapped[int] = mapped_column(Integer)
    # Validated QuestionSet.questions payload (list of question dicts).
    questions: Mapped[list[dict[str, Any]]] = mapped_column(JSONB)
    change_note: Mapped[str] = mapped_column(Text, default="")
    # Validated Timer payload ({steps: [...]}); null = not timed (timers.md §2.1).
    timer: Mapped[dict[str, Any] | None] = mapped_column(JSONB, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    topic: Mapped[Topic] = relationship(back_populates="versions")

    __table_args__ = (UniqueConstraint("topic_id", "version", name="uq_topic_version"),)


class Entry(Base):
    """A single set of answers recorded against one topic version."""

    __tablename__ = "entries"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    topic_id: Mapped[UUID] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"))
    topic_version_id: Mapped[UUID] = mapped_column(ForeignKey("topic_versions.id", ondelete="CASCADE"))
    version: Mapped[int] = mapped_column(Integer)
    source: Mapped[str] = mapped_column(String(100))
    channel: Mapped[Channel] = mapped_column(Enum(Channel, name="entry_channel", native_enum=True))
    captured_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    notes: Mapped[str] = mapped_column(Text, default="")
    meta: Mapped[dict[str, str]] = mapped_column(JSONB, default=dict)
    # A finished run's Timing projection; null = untimed entry (timers.md §2.3).
    timing: Mapped[dict[str, Any] | None] = mapped_column(JSONB, default=None)
    # Bumped on every update (optimistic concurrency, see feed).
    revision: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    answers: Mapped[list[Answer]] = relationship(
        back_populates="entry", cascade="all, delete-orphan", lazy="selectin", order_by="Answer.position"
    )

    __table_args__ = (Index("ix_entries_topic_captured", "topic_id", "captured_at"),)


ANSWER_TYPED_VALUE_CHECK = (
    "(question_type = 'int' AND value_int IS NOT NULL"
    " AND value_double IS NULL AND value_str IS NULL AND value_list IS NULL)"
    " OR (question_type = 'double' AND value_double IS NOT NULL"
    " AND value_int IS NULL AND value_str IS NULL AND value_list IS NULL)"
    " OR (question_type = 'str' AND value_str IS NOT NULL"
    " AND value_int IS NULL AND value_double IS NULL AND value_list IS NULL)"
    " OR (question_type = 'enum' AND value_int IS NULL AND value_double IS NULL AND ("
    "(value_str IS NOT NULL AND value_list IS NULL)"
    " OR (value_str IS NULL AND value_list IS NOT NULL AND cardinality(value_list) > 0)))"
)


class Answer(Base):
    """One typed answer. Exactly one value column is populated (by question type).

    Enum answers use ``value_str`` (single-select) or ``value_list`` (multi-select).
    """

    __tablename__ = "answers"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    entry_id: Mapped[UUID] = mapped_column(ForeignKey("entries.id", ondelete="CASCADE"))
    topic_id: Mapped[UUID] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"))
    question_key: Mapped[str] = mapped_column(String(64))
    question_type: Mapped[str] = mapped_column(String(16))
    position: Mapped[int] = mapped_column(Integer, default=0)
    value_int: Mapped[int | None] = mapped_column(BigInteger, default=None)
    value_double: Mapped[float | None] = mapped_column(Double, default=None)
    value_str: Mapped[str | None] = mapped_column(Text, default=None)
    # Multi-select enum answers (option values, in option order). Never empty.
    value_list: Mapped[list[str] | None] = mapped_column(ARRAY(Text), default=None)

    entry: Mapped[Entry] = relationship(back_populates="answers")

    __table_args__ = (
        UniqueConstraint("entry_id", "question_key", name="uq_answer_entry_key"),
        Index("ix_answers_topic_key", "topic_id", "question_key"),
        CheckConstraint(ANSWER_TYPED_VALUE_CHECK, name="ck_answer_typed_value"),
    )


class RunStatus(enum.StrEnum):
    running = "running"
    paused = "paused"
    finishing = "finishing"
    stopped = "stopped"
    discarded = "discarded"


class RunEventType(enum.StrEnum):
    start = "start"
    next = "next"
    lap = "lap"
    skip = "skip"
    pause = "pause"
    resume = "resume"
    stop = "stop"
    finish = "finish"
    discard = "discard"


class Run(Base):
    """One timing session of a timed topic (timers.md §2.2).

    Its id is the start event's id, and the id of the entry it becomes once stopped. The run
    is pinned to the version it started on.
    """

    __tablename__ = "runs"

    id: Mapped[UUID] = mapped_column(primary_key=True)
    topic_id: Mapped[UUID] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"))
    topic_version_id: Mapped[UUID] = mapped_column(ForeignKey("topic_versions.id", ondelete="CASCADE"))
    version: Mapped[int] = mapped_column(Integer)
    status: Mapped[RunStatus] = mapped_column(Enum(RunStatus, name="run_status", native_enum=True))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    # Timing edited after stop (§3.8).
    edited: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    # == id once the entry exists; null again if it is deleted.
    entry_id: Mapped[UUID | None] = mapped_column(default=None)
    # The fold's output (§4), cached.
    state: Mapped[dict[str, Any]] = mapped_column(JSONB)
    source: Mapped[str] = mapped_column(String(100))
    channel: Mapped[Channel] = mapped_column(Enum(Channel, name="entry_channel", native_enum=True))
    revision: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        # One open run per topic.
        Index(
            "ux_runs_one_open",
            "topic_id",
            unique=True,
            postgresql_where=text("status IN ('running', 'paused')"),
        ),
    )


class RunEvent(Base):
    """One tap of a run. Its effect (applied or void) is the fold's output, not stored."""

    __tablename__ = "run_events"

    # Client-generated: the idempotency key.
    id: Mapped[UUID] = mapped_column(primary_key=True)
    run_id: Mapped[UUID] = mapped_column(ForeignKey("runs.id", ondelete="CASCADE"))
    # Server arrival order (§4.1).
    arrival: Mapped[int] = mapped_column(BigInteger, Identity())
    type: Mapped[RunEventType] = mapped_column(Enum(RunEventType, name="run_event_type", native_enum=True))
    # Device time of the tap.
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    # next, lap, skip: the open segment's index (§3.2).
    seg: Mapped[int | None] = mapped_column(Integer, default=None)
    # skip: the step being skipped.
    step: Mapped[str | None] = mapped_column(String(64), default=None)
    # resume: the pause event it ends.
    pause_id: Mapped[UUID | None] = mapped_column(default=None)
    # stop/finish: answers, notes, meta; start: version.
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, default=dict, server_default="{}")
    source: Mapped[str] = mapped_column(String(100))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (Index("ix_run_events_run", "run_id", "arrival"),)


class RunAlias(Base):
    """A losing start's run id, merged into another open run of the same topic (§4.5)."""

    __tablename__ = "run_aliases"

    id: Mapped[UUID] = mapped_column(primary_key=True)
    run_id: Mapped[UUID] = mapped_column(ForeignKey("runs.id", ondelete="CASCADE"))


class LiveActivityToken(Base):
    """A Live Activity push token (timers.md §10.3): separate from ``apns_devices``, so a failed
    send drops only this row."""

    __tablename__ = "live_activity_tokens"

    token: Mapped[str] = mapped_column(Text, primary_key=True)  # lower-case hex
    kind: Mapped[str] = mapped_column(Text)
    # The APNs device token of the phone that owns it.
    device_token: Mapped[str] = mapped_column(Text)
    environment: Mapped[str] = mapped_column(Text)
    # Update tokens: the topic, and the run it was registered for.
    topic_id: Mapped[UUID | None] = mapped_column(default=None)
    run_id: Mapped[UUID | None] = mapped_column(default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        CheckConstraint("kind IN ('start', 'update')", name="ck_live_activity_tokens_kind"),
        CheckConstraint(
            "environment IN ('sandbox', 'production')", name="ck_live_activity_tokens_environment"
        ),
        Index("ix_live_activity_tokens_run", "run_id"),
        Index("ix_live_activity_tokens_topic", "topic_id"),
        Index("ix_live_activity_tokens_device", "device_token"),
    )


class PushSubscription(Base):
    """A browser Web Push subscription. Upserted by endpoint."""

    __tablename__ = "push_subscriptions"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    endpoint: Mapped[str] = mapped_column(Text, unique=True)
    p256dh: Mapped[str] = mapped_column(Text)
    auth: Mapped[str] = mapped_column(Text)
    user_agent: Mapped[str | None] = mapped_column(Text, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_success_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    failure_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")


class ApnsDevice(Base):
    """An iOS app install's APNs device token. Upserted by token on every launch."""

    __tablename__ = "apns_devices"

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    token: Mapped[str] = mapped_column(Text, unique=True)  # lower-case hex
    # Which APNs host the token belongs to (a plain CHECK, not another PG enum).
    environment: Mapped[str] = mapped_column(String(16))
    bundle_id: Mapped[str | None] = mapped_column(String(155), default=None)
    app_version: Mapped[str | None] = mapped_column(String(64), default=None)
    device_name: Mapped[str | None] = mapped_column(String(200), default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    last_success_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), default=None)
    failure_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")

    __table_args__ = (
        CheckConstraint("environment IN ('sandbox', 'production')", name="ck_apns_devices_environment"),
    )


class PushSlotDelivery(Base):
    """Progress of one due slot's fan-out: this target's send finished (sent or failed).

    Written by a scheduler tick whose budget ran out mid-topic, so the next tick resumes
    with the targets not yet reached instead of starting over. Rows go when the slot is
    marked notified, or after a couple of days. ``target_id`` is an ``apns_devices`` or
    ``push_subscriptions`` id (no foreign key: two tables, and a gone target is harmless).
    """

    __tablename__ = "push_slot_deliveries"

    topic_id: Mapped[UUID] = mapped_column(ForeignKey("topics.id", ondelete="CASCADE"), primary_key=True)
    due_since: Mapped[datetime] = mapped_column(DateTime(timezone=True), primary_key=True)
    target_kind: Mapped[str] = mapped_column(String(8), primary_key=True)
    target_id: Mapped[UUID] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        CheckConstraint("target_kind IN ('web', 'apns')", name="ck_push_slot_deliveries_target_kind"),
    )


class AppSetting(Base):
    """Small key/value store for server state that must survive restarts (e.g. generated VAPID keys)."""

    __tablename__ = "app_settings"

    key: Mapped[str] = mapped_column(Text, primary_key=True)
    value: Mapped[str] = mapped_column(Text)


class FeedKind(enum.StrEnum):
    """What a change-feed row refers to."""

    entry = "entry"
    topic = "topic"
    version = "version"
    run = "run"


class FeedOp(enum.StrEnum):
    upsert = "upsert"
    delete = "delete"


class ChangeLog(Base):
    """The change feed: one row per mutation, written in the mutation's transaction.

    ``seq`` is allocated while holding the feed advisory lock (``app.services.feed``), so
    seq order is commit order and a reader never sees seq N+1 without seq N.
    """

    __tablename__ = "change_log"

    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    kind: Mapped[FeedKind] = mapped_column(Enum(FeedKind, name="feed_kind", native_enum=True))
    op: Mapped[FeedOp] = mapped_column(Enum(FeedOp, name="feed_op", native_enum=True))
    entity_id: Mapped[UUID] = mapped_column()
    topic_id: Mapped[UUID] = mapped_column()
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class DeletedId(Base):
    """Permanent tombstone: a deleted id is never reused (a replayed create gets 409).

    Keyed by ``(kind, id)``: ids are only unique per table (entry ids are client-chosen).
    """

    __tablename__ = "deleted_ids"

    kind: Mapped[FeedKind] = mapped_column(
        Enum(FeedKind, name="feed_kind", native_enum=True), primary_key=True
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    # Null when an entry id was reserved before the server ever saw the entry.
    topic_id: Mapped[UUID | None] = mapped_column(default=None)
    deleted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
