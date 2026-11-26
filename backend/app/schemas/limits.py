"""Numeric ceilings shared by validation and ``GET /limits`` (so clients can mirror them)."""

from __future__ import annotations

from datetime import UTC, datetime

KEY_PATTERN = r"^[a-z][a-z0-9_]{0,62}$"
SLUG_PATTERN = r"^[a-z0-9][a-z0-9-]{0,63}$"
TIME_PATTERN = r"^([01][0-9]|2[0-3]):[0-5][0-9]$"

MAX_QUESTIONS = 100
MAX_STEPS = 30
MAX_RUN_EVENTS = 1_000  # per run, void events included (timers.md §5)
RUN_START_MAX_AGE_DAYS = 7  # a start's `at` is at most this old
MAX_ENUM_OPTIONS = 200
MAX_STR_LENGTH = 10_000
MAX_LABEL_LENGTH = 200
MAX_HELP_TEXT_LENGTH = 1_000
MAX_UNIT_LENGTH = 32
MAX_DECIMALS = 10

MAX_TOPIC_NAME_LENGTH = 200
MAX_DESCRIPTION_LENGTH = 5_000
MAX_CHANGE_NOTE_LENGTH = 2_000

MAX_SOURCE_LENGTH = 100
MAX_NOTES_LENGTH = 5_000
MAX_META_ENTRIES = 50
MAX_META_KEY_LENGTH = 64
MAX_META_VALUE_LENGTH = 500
CAPTURED_AT_MAX_FUTURE_HOURS = 24
CAPTURED_AT_MIN = datetime(2000, 1, 1, tzinfo=UTC)

SCHEDULE_MAX_TIMES = 24
INTERVAL_MIN_MINUTES = 15
INTERVAL_MAX_MINUTES = 129_600  # 90 days
MAX_TIMEZONE_LENGTH = 64

MAX_PUSH_ENDPOINT_LENGTH = 2_048
MAX_PUSH_KEY_LENGTH = 256
MAX_USER_AGENT_LENGTH = 500
APNS_TOKEN_PATTERN = r"^[0-9a-fA-F]{64,200}$"  # hex; Apple's tokens are 32 bytes today
# Live Activity push tokens (push-to-start and update) are longer than device tokens.
LIVE_ACTIVITY_TOKEN_PATTERN = r"^[0-9a-fA-F]{64,512}$"
BUNDLE_ID_PATTERN = r"^[A-Za-z0-9.-]{1,155}$"
MAX_APP_VERSION_LENGTH = 64
MAX_DEVICE_NAME_LENGTH = 200

# Integer answers and bounds are stored as BIGINT.
INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1

# T2-M1: Timer v2 (docs/specs/timers2.md §1.2)
MAX_LAP_TYPES = 8
MAX_VARIABLES = 16
MAX_ALERTS = 8  # per step or lap type
MAX_EXPR_LENGTH = 64  # an alert's `at` (timer_expr.MAX_LENGTH)
MAX_VAR_NAME_LENGTH = 16
MAX_SHORT_LABEL_LENGTH = 64  # lap-type and alert labels (the Live Activity label cap)
MAX_VARIABLE_MS = 7 * 24 * 3_600_000  # 7 days (timer_expr.MAX_MS)
VAR_NAME_PATTERN = r"^[a-z][a-z0-9_]{0,15}$"  # after lowercasing
RESERVED_VAR_NAMES = frozenset({"ms", "s", "m", "h"})  # the expression units
# end T2-M1

# T2-M3: topic appearance (docs/specs/appearance.md §1.3); the colour names are
# services/appearance.py COLOR_NAMES
MAX_TAGS = 10
MAX_TAG_LENGTH = 24  # code points, after trimming and collapsing whitespace
MAX_ICON_LENGTH = 16  # code points of the stored emoji (NFC, VS16 inserted): topics.icon VARCHAR(16)
# end T2-M3
