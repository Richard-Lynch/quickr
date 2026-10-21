"""APNs payload vectors: ``shared/fixtures/apns-payload-vectors.json``.

Whole due-reminder payloads from ``apns.render``, over the scheduler's inputs: the topic, its
version's questions, the counts and last answer the descriptor reads, the slot and the body
text (docs/ios/specs/notifications.md §2). The iOS app's DEBUG demo reminder
(``DueReminder``, the M3 media captures) builds the same title, body, category, thread and
``quickr`` object on the device, so a simulator screenshot shows what a real push would.
``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the committed
file must match.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import TypeAdapter

from app.schemas.questions import DoubleQuestion, EnumQuestion, IntQuestion, Question, StrQuestion
from app.services import notification
from app.services.push import apns
from app.services.push.base import Notification
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "apns-payload-vectors.json"
GENERATOR_VERSION = 1

SERVER_ID = "0b9e0000-0000-4000-8000-0000000000aa"

question_adapter: TypeAdapter[IntQuestion | DoubleQuestion | StrQuestion | EnumQuestion] = TypeAdapter(
    Question
)

GLASSES = {"key": "glasses", "label": "Glasses", "type": "int", "min": 0, "max": 20, "unit": "glasses"}
SEVERITY = {
    "key": "severity",
    "label": "Severity",
    "type": "enum",
    "options": [{"value": v, "label": v.capitalize()} for v in ("none", "mild", "moderate", "severe")],
}
SIX = {
    "key": "mood",
    "label": "Mood",
    "type": "enum",
    "options": [{"value": f"o{i}", "label": f"Option {i}"} for i in range(6)],
}
HOURS = {"key": "hours", "label": "Hours slept", "type": "double", "decimals": 1, "unit": "h"}
MINUTES = {"key": "minutes", "label": "Minutes", "type": "int", "min": 1}
KIND = {
    "key": "kind",
    "label": "Kind",
    "type": "enum",
    "options": [{"value": "run", "label": "Run"}, {"value": "gym", "label": "Gym"}],
}

# name -> (topic number, slug, title, body, version, due_since, questions, counts, last)
CASES: dict[str, tuple[int, str, str, str, int, str, list[dict[str, Any]], dict[str, int], Any]] = {
    "int-last": (2, "water", "Water", "Time to log", 1, "2026-10-21T08:00:00Z", [GLASSES], {}, 3),
    "int-no-last": (
        2,
        "water",
        "Water",
        "Overdue since 08:00",
        2,
        "2026-10-21T08:00:00Z",
        [GLASSES],
        {},
        None,
    ),
    "enum-4": (8, "headache", "Headache", "Time to log", 1, "2026-10-21T09:30:00Z", [SEVERITY], {}, "mild"),
    "enum-6-cut": (
        5,
        "mood",
        "Mood",
        "Time to log",
        3,
        "2026-10-21T20:00:00Z",
        [SIX],
        {"o4": 9, "o2": 4, "o5": 4},
        None,
    ),
    "double-last": (
        6,
        "sleep",
        "Sleep",
        "Overdue since Tue 07:00",
        1,
        "2026-10-20T07:00:00Z",
        [HOURS],
        {},
        7.5,
    ),
    # Two required questions: no category and no quick_log; tapping opens the record screen.
    "not-quick-loggable": (
        9,
        "workout",
        "Workout",
        "Time to log",
        4,
        "2026-10-21T18:00:00Z",
        [MINUTES, KIND],
        {},
        None,
    ),
    # A non-UTC slot with fractions: due_since is canonical (UTC, whole seconds, Z).
    "slot-canonical": (
        2,
        "water",
        "Water",
        "Time to log",
        1,
        "2026-10-21T10:00:00.750+02:00",
        [GLASSES],
        {},
        3,
    ),
    # A 130-scalar title (emoji are one scalar each): cut to 120 with "…".
    "title-cut": (
        3,
        "stretch",
        "🧘" * 10 + "Stretch " * 15,
        "Time to log",
        1,
        "2026-10-21T08:00:00Z",
        [GLASSES],
        {},
        None,
    ),
}


def topic_id(n: int) -> UUID:
    return UUID(f"00000000-0000-4000-8000-{n:012d}")


def case(
    name: str,
    n: int,
    slug: str,
    title: str,
    body: str,
    version: int,
    due_since: str,
    raw: list[dict[str, Any]],
    counts: dict[str, int],
    last: Any,
) -> dict[str, Any]:
    questions = [question_adapter.validate_python(q) for q in raw]
    quick_log = notification.descriptor(questions, counts=counts, last=last)
    payload = apns.render(
        Notification(
            kind="due",
            title=title,
            body=body,
            url=f"/t/{slug}/record",
            tag=f"due-{topic_id(n)}",
            topic_slug=slug,
            server_id=SERVER_ID,
            topic_id=topic_id(n),
            version=version,
            due_since=datetime.fromisoformat(due_since),
            quick_log=quick_log,
        )
    )
    return {
        "name": name,
        "server_id": SERVER_ID,
        "topic_id": str(topic_id(n)),
        "topic_slug": slug,
        "title": title,
        "body": body,
        "version": version,
        "due_since": due_since,
        "questions": [q.model_dump(mode="json") for q in questions],
        "counts": counts,
        "last": last,
        "expected": payload,
    }


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_apns_payload_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "semantics": [
                "expected: apns.render of a due Notification built as the scheduler builds it: "
                "title = the topic name, url = /t/{slug}/record, the descriptor from "
                "notification.descriptor(questions, counts, last) (notification-vectors.json).",
                "aps.alert.title is cut to 120 Unicode scalars with '…'; aps.alert.body is body + "
                "the descriptor's body suffix; aps.category is the category id (absent without a "
                "quick_log); aps.thread-id is topic-{topic_id}.",
                "aps.sound, aps.mutable-content and aps.relevance-score are delivery settings: a "
                "local notification has no equivalent for the last two.",
                "quickr.due_since is canonical: UTC, whole seconds, Z.",
            ],
        },
        "cases": [case(name, *spec) for name, spec in CASES.items()],
    }


def test_apns_payload_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_vectors_cover_the_payload() -> None:
    cases = {c["name"]: c["expected"] for c in build()["cases"]}
    assert cases["int-last"]["aps"]["category"].startswith("quickr.t.")
    assert "category" not in cases["not-quick-loggable"]["aps"]
    assert cases["not-quick-loggable"]["quickr"]["quick_log"] is None
    assert cases["enum-6-cut"]["aps"]["alert"]["body"].endswith(" · 3 of 6 shown, More for all")
    assert cases["slot-canonical"]["quickr"]["due_since"] == "2026-10-21T08:00:00Z"
    title = cases["title-cut"]["aps"]["alert"]["title"]
    assert len(title) == apns.MAX_TITLE_LENGTH
    assert title.endswith("…")
    # A last value is part of the actions, so it changes the category.
    assert cases["int-last"]["aps"]["category"] != cases["int-no-last"]["aps"]["category"]
