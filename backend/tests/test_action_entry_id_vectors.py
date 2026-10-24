"""Action entry id vectors: ``shared/fixtures/action-entry-id-vectors.json``.

Generated from :func:`app.services.notification.action_entry_id` (docs/ios/specs/
notifications.md §7.4): the id of the entry a reminder action logs, derived from
``(server_id, topic_id, due_since)`` so the iOS app and the PWA log one reminder once.
The PWA (``frontend/src/lib/pushActions.test.ts``) and the iOS handler check their ports
against these. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file;
otherwise the committed file must match.
"""

from __future__ import annotations

import uuid
from typing import Any

from app.services import notification
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "action-entry-id-vectors.json"
GENERATOR_VERSION = 1

SERVER = "0b9e0000-0000-4000-8000-0000000000aa"
TOPIC = "6f1c0000-0000-4000-8000-000000000001"
SLOT = "2026-10-17T08:00:00Z"

# name -> (server_id, topic_id, due_since)
CASES: dict[str, tuple[str, str, str]] = {
    "canonical": (SERVER, TOPIC, SLOT),
    "mixed-case-ids": (SERVER.upper(), "6F1C0000-0000-4000-8000-000000000001", SLOT),
    "next-slot": (SERVER, TOPIC, "2026-10-17T20:00:00Z"),
    "other-topic": (SERVER, "6f1c0000-0000-4000-8000-000000000002", SLOT),
    "other-server": ("0b9e0000-0000-4000-8000-0000000000bb", TOPIC, SLOT),
    "new-year-midnight": (SERVER, TOPIC, "2027-01-01T00:00:00Z"),
    "leap-day-last-second": (SERVER, TOPIC, "2028-02-29T23:59:59Z"),
    "epoch": (SERVER, TOPIC, "1970-01-01T00:00:00Z"),
    # Taken byte for byte, never re-normalised: a non-canonical form is a different slot.
    "non-canonical-fraction": (SERVER, TOPIC, "2026-10-17T08:00:00.000Z"),
    "non-canonical-offset": (SERVER, TOPIC, "2026-10-17T08:00:00+00:00"),
    "random-v4-ids": ("c3a1d2b4-9e8f-4a7b-b6c5-d4e3f2a1b0c9", "11112222-3333-4444-a555-666677778888", SLOT),
}


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_action_entry_id_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "semantics": [
                "id = UUIDv8 from the first 16 bytes of SHA-256(UTF-8(name)), with "
                "byte 6 = (b & 0x0f) | 0x80 and byte 8 = (b & 0x3f) | 0x80, "
                "written as lowercase 8-4-4-4-12 hex",
                f"name = '{notification.ACTION_ENTRY_ID_PREFIX}|' + lower(server_id) + '|' + lower(topic_id) "
                "+ '|' + due_since",
                "due_since is used exactly as the push payload carries it "
                "(canonical: UTC, whole seconds, 'Z'); it is never re-normalised",
                "docs/ios/specs/notifications.md §7.4",
                "a timed reminder's Start uses the same id as its run id and start event id, so "
                "one reminder starts one run on every client (docs/specs/timers.md §10.2)",
            ],
        },
        "cases": [
            {
                "name": name,
                "server_id": server_id,
                "topic_id": topic_id,
                "due_since": due_since,
                "expected": str(notification.action_entry_id(server_id, topic_id, due_since)),
            }
            for name, (server_id, topic_id, due_since) in CASES.items()
        ],
    }


def test_action_entry_id_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


def test_action_entry_ids_are_version_8_and_case_insensitive_in_the_ids() -> None:
    ids = {name: notification.action_entry_id(*inputs) for name, inputs in CASES.items()}
    assert all(i.version == 8 and i.variant == uuid.RFC_4122 for i in ids.values())
    assert ids["mixed-case-ids"] == ids["canonical"]
    others = [n for n in CASES if n != "mixed-case-ids"]
    assert len({ids[n] for n in others}) == len(others)  # every other input is a different id
