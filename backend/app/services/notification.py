"""What a reminder offers to log, and the notification category that offers it.

Pure functions (no DB, no clock), mirrored by the iOS app, which registers the same
categories from its local store: ``shared/fixtures/notification-vectors.json`` (generated
from this module) is the contract both sides check. The rules are
docs/ios/specs/notifications.md §2.3 (the descriptor) and §4 (actions and category ids).

- :func:`descriptor` builds the ``quick_log`` descriptor of a topic version from its
  questions (eligibility is :func:`app.services.quicklog.quick_log_for`), how often each
  enum option was answered, and the latest answer. Labels and units are truncated to
  ``MAX_LABEL_LENGTH`` here, so every channel and the category hash see the same text.
- :func:`actions` renders a descriptor as the ordered notification actions, and
  :func:`category_id` hashes them into the immutable category id.
- :func:`action_entry_id` is the id every client gives the entry a reminder action logs
  (§7.4), so one reminder logs once across the iOS app and the PWA. The server never
  calls it; it is here so ``shared/fixtures/action-entry-id-vectors.json`` comes from
  the reference implementation.
"""

from __future__ import annotations

import hashlib
import unicodedata
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Literal

from app.errors import InvalidAnswers
from app.schemas.api import QuickLogDescriptor, QuickLogEnum, QuickLogNumber, QuickLogOption
from app.schemas.questions import DoubleQuestion, IntQuestion
from app.services.answers import validate_answers
from app.services.quicklog import AnyQuestion, QuickLogChips, quick_log_for

MAX_LABEL_LENGTH = 64  # question and option labels, units (Unicode scalars, "…" included)
MAX_SHOWN_OPTIONS = 4  # up to this many active options: one action each
MOST_USED_OPTIONS = 3  # above it: the most-used ones, then "More…"
MORE_TITLE = "More…"
OTHER_VALUE_TITLE = "Other value…"
TEXT_INPUT_BUTTON_TITLE = "Log"
ACTION_SCHEME = "q1"
CATEGORY_HASH_PREFIX = "quickr-cat-v1"
ACTION_ENTRY_ID_PREFIX = "quickr-action-entry-v1"
_RECORD_SEPARATOR = "\u001e"
_UNIT_SEPARATOR = "\u001f"

type ActionKind = Literal["log", "input", "open"]


def truncate(text: str, limit: int) -> str:
    """At most ``limit`` characters (Unicode scalars), the "…" included."""
    return text if len(text) <= limit else text[: limit - 1] + "…"


def canonical_instant(at: datetime) -> str:
    """``at`` in UTC, truncated to whole seconds, with a ``Z``: the canonical ``due_since``."""
    return at.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- the descriptor ---------------------------------------------------------------------


def descriptor(
    questions: Sequence[AnyQuestion], *, counts: Mapping[str, int], last: object
) -> QuickLogDescriptor | None:
    """The ``quick_log`` descriptor, or None when the version isn't quick-loggable.

    ``counts`` maps an enum option value to the number of the topic's entries that chose
    it (any version); ``last`` is the latest entry's answer for the key, as JSON carries it
    (None when there is none).
    """
    quick = quick_log_for(questions)
    if quick is None:
        return None
    if isinstance(quick, QuickLogChips):
        options = list(quick.options)
        if len(options) > MAX_SHOWN_OPTIONS:
            order = {o.value: i for i, o in enumerate(options)}
            options = sorted(options, key=lambda o: (-counts.get(o.value, 0), order[o.value]))
            options = options[:MOST_USED_OPTIONS]
        return QuickLogEnum(
            key=quick.question.key,
            label=truncate(quick.question.label, MAX_LABEL_LENGTH),
            options=[
                QuickLogOption(value=o.value, label=truncate(o.label, MAX_LABEL_LENGTH)) for o in options
            ],
            total_options=len(quick.options),
        )
    q = quick.question
    return QuickLogNumber(
        type="int" if isinstance(q, IntQuestion) else "double",
        key=q.key,
        label=truncate(q.label, MAX_LABEL_LENGTH),
        unit=truncate(q.unit, MAX_LABEL_LENGTH) if q.unit else None,
        min=q.min,
        max=q.max,
        decimals=q.decimals if isinstance(q, DoubleQuestion) else None,
        last_value=last_value(q, last),
    )


def last_value(q: IntQuestion | DoubleQuestion, last: object) -> int | float | None:
    """``last`` when the server would still accept it as an answer to ``q`` (a number,
    finite, within the bounds, and whole for an int question), else None.

    ``decimals`` is a display hint, not a rule: a double with more fraction digits is kept,
    and its action logs it exactly.
    """
    if isinstance(last, bool) or not isinstance(last, int | float):
        return None
    try:
        (typed,) = validate_answers([q], {q.key: last})
    except InvalidAnswers:
        return None
    return typed.value_int if isinstance(q, IntQuestion) else typed.value_double


def fmt(kind: Literal["int", "double"], x: int | float) -> str:
    """A number as action titles and identifiers show it (§4.4).

    int: base 10. double: the shortest decimal that round-trips to the same binary64 value
    (what JS ``String(x)`` and Python ``repr`` pick), written positionally (no exponent),
    with no trailing zeros or dot, and never "-0". Always ``.``, no grouping, no rounding.
    """
    if kind == "int":
        return str(int(x))
    text = format(Decimal(repr(float(x))), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text == "-0" else text


# --- actions and the category -------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Action:
    """One notification action, as the category registers it.

    ``log`` logs from the background, ``input`` asks for a number first, ``open`` (the
    "More…" action) opens the app on the record screen.
    """

    kind: ActionKind
    identifier: str
    title: str
    text_input_button_title: str | None = None
    text_input_placeholder: str | None = None


def action_identifier(
    server_id: str, topic_id: str, version: int, key: str, k: Literal["o", "n", "i", "m"], value: str = ""
) -> str:
    """``q1|{server_id}|{topic_id}|{version}|{key}|{k}|{value}`` (§4.2)."""
    return "|".join((ACTION_SCHEME, server_id, topic_id, str(version), key, k, value))


def actions(server_id: str, topic_id: str, version: int, quick_log: QuickLogDescriptor) -> list[Action]:
    """The ordered actions a notification with ``quick_log`` offers (§4.1)."""

    def ident(k: Literal["o", "n", "i", "m"], value: str = "") -> str:
        return action_identifier(server_id, topic_id, version, quick_log.key, k, value)

    if isinstance(quick_log, QuickLogEnum):
        rendered = [Action("log", ident("o", o.value), o.label) for o in quick_log.options]
        if quick_log.total_options > len(quick_log.options):
            rendered.append(Action("open", ident("m"), MORE_TITLE))
        return rendered
    rendered = []
    if quick_log.last_value is not None:
        shown = fmt(quick_log.type, quick_log.last_value)
        title = f"✓ {shown} {quick_log.unit}" if quick_log.unit else f"✓ {shown}"
        rendered.append(Action("log", ident("n", shown), title))
    placeholder = f"Value in {quick_log.unit}" if quick_log.unit else "Value"
    rendered.append(Action("input", ident("i"), OTHER_VALUE_TITLE, TEXT_INPUT_BUTTON_TITLE, placeholder))
    return rendered


def category_hash_input(rendered: Sequence[Action]) -> str:
    """The string the category id hashes (§4.3), NFC-normalised."""
    parts = [CATEGORY_HASH_PREFIX]
    for a in rendered:
        fields = [a.kind, a.identifier, a.title]
        if a.kind == "input":
            fields += [a.text_input_button_title or "", a.text_input_placeholder or ""]
        parts.append(_RECORD_SEPARATOR + _UNIT_SEPARATOR.join(fields))
    return unicodedata.normalize("NFC", "".join(parts))


def category_id(topic_id: str, rendered: Sequence[Action]) -> str:
    """``quickr.t.{topic_id}.{first 16 hex digits of sha256(H)}``: one id per action set."""
    digest = hashlib.sha256(category_hash_input(rendered).encode()).hexdigest()
    return f"quickr.t.{topic_id}.{digest[:16]}"


def more_suffix(quick_log: QuickLogDescriptor | None) -> str:
    """What the alert body adds when the actions show only some options ("" otherwise)."""
    if isinstance(quick_log, QuickLogEnum) and quick_log.total_options > len(quick_log.options):
        return f" · {len(quick_log.options)} of {quick_log.total_options} shown, More for all"
    return ""


def action_entry_id(server_id: str, topic_id: str, due_since: str) -> uuid.UUID:
    """The id of the entry a reminder action logs (notifications.md §7.4).

    A version-8 UUID from the first 16 bytes of
    ``SHA-256(UTF-8("quickr-action-entry-v1|{server_id}|{topic_id}|{due_since}"))``, with
    both ids lowercased and ``due_since`` exactly as the payload carries it, then the
    version (8) and RFC 9562 variant bits set. One reminder slot, one entry: a second action
    on any client replays the same create, which the server answers with the first entry.
    """
    name = "|".join((ACTION_ENTRY_ID_PREFIX, server_id.lower(), topic_id.lower(), due_since))
    raw = bytearray(hashlib.sha256(name.encode()).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x80
    raw[8] = (raw[8] & 0x3F) | 0x80
    return uuid.UUID(bytes=bytes(raw))
