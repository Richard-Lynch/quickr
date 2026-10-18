"""The APNs payload the scheduler would send for a topic (SPIKE, docs/ios/demo/m1).

Runs inside the integration stack's backend container (``spike-proof.sh`` pipes it to
``python -``), so the payload, its category id and its action identifiers come from the
server's own code (``app.services.push.apns.render``, B7), not from a copy.

Input (environment): SPIKE_TOPIC, the topic as ``GET /api/v1/topics/{ref}`` returns it;
SPIKE_SERVER_ID; SPIKE_DUE_SINCE (RFC 3339). Output: the payload JSON on stdout.
"""

import json
import os
from datetime import datetime
from uuid import UUID

from app.services.notification import descriptor
from app.services.push.apns import render
from app.services.push.base import Notification
from app.services.quicklog import AnyQuestion
from pydantic import TypeAdapter

topic = json.loads(os.environ["SPIKE_TOPIC"])
questions = TypeAdapter(list[AnyQuestion]).validate_python(topic["questions"])
notification = Notification(
    kind="due",
    title=topic["name"],
    body="Time to log",
    url=f"/t/{topic['slug']}/record",
    tag=f"due-{topic['id']}",
    topic_slug=topic["slug"],
    server_id=os.environ["SPIKE_SERVER_ID"],
    topic_id=UUID(topic["id"]),
    version=topic["current_version"],
    due_since=datetime.fromisoformat(os.environ["SPIKE_DUE_SINCE"]),
    quick_log=descriptor(questions, counts={}, last=None),
)
print(
    json.dumps(
        {"Simulator Target Bundle": "com.bahumia.quickr", **render(notification)}
    )
)
