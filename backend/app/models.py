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
    CheckConstraint,
    DateTime,
    Double,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
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


class AppSetting(Base):
    """Small key/value store for server state that must survive restarts (e.g. generated VAPID keys)."""

    __tablename__ = "app_settings"

    key: Mapped[str] = mapped_column(Text, primary_key=True)
    value: Mapped[str] = mapped_column(Text)
