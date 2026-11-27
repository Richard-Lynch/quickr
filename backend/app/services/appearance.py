"""Topic appearance (docs/specs/appearance.md Part I): the twelve-colour palette, the emoji icon
rule and the tag rule. This is the reference implementation: ``tests/test_appearance_vectors.py``
generates ``shared/fixtures/appearance-vectors.json`` from it, and the PWA's and the iOS app's
``checkIcon``/``checkTags`` and palettes are tested against that file.

Pure functions only (no database, no pydantic): ``schemas/api.py`` wraps them as validators, so
a bad value is a 422 at its dotted path (``appearance.icon.value``, ``appearance.tags.3``).
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from typing import Literal, get_args

import regex

from app.schemas.limits import MAX_ICON_LENGTH, MAX_TAG_LENGTH, MAX_TAGS

ColorName = Literal[
    "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo", "violet", "pink"
]
COLOR_NAMES: tuple[ColorName, ...] = get_args(ColorName)
"""The twelve names, in palette order (§3.1); ``GET /limits`` lists them as ``color_names``."""

MIN_CONTRAST = 4.5  # WCAG AA: every on_tint on its tint, light and dark (§3.1)


@dataclass(frozen=True, slots=True)
class Swatch:
    tint: str  # the fill: buttons, the accent bar, the Live Activity primary
    tint_soft: str  # the wash: card and badge backgrounds (text on it is ink, never tint)
    on_tint: str  # text on tint


@dataclass(frozen=True, slots=True)
class Colors:
    light: Swatch
    dark: Swatch


def _colors(light: tuple[str, str, str], dark: tuple[str, str, str]) -> Colors:
    return Colors(Swatch(*light), Swatch(*dark))


# appearance.md §3.1, the source of truth: topicColors.css / appearance.ts (PWA) and
# TopicColors.xcassets (iOS) copy it, and their drift tests read the vectors made from it.
PALETTE: dict[ColorName, Colors] = {
    "red": _colors(("#c2362b", "#f8dcd8", "#ffffff"), ("#ff7b6e", "#3b1714", "#1b0d04")),
    "orange": _colors(("#c2470a", "#fde4d4", "#ffffff"), ("#ff7a2e", "#3a2214", "#1b0d04")),
    "amber": _colors(("#9e5406", "#fbe7c6", "#ffffff"), ("#f0a63a", "#3a2a0e", "#1b1204")),
    "yellow": _colors(("#f2c230", "#fbf0c4", "#1b1915"), ("#f5cf4f", "#3a3110", "#1b1804")),
    "lime": _colors(("#4f7a0c", "#e6f2cc", "#ffffff"), ("#a9d64c", "#243410", "#101a04")),
    "green": _colors(("#2f7d4f", "#dcefe2", "#ffffff"), ("#5cc28a", "#173323", "#04170c")),
    "teal": _colors(("#19786f", "#d4eeea", "#ffffff"), ("#4fc4b7", "#113330", "#04201c")),
    "cyan": _colors(("#1c7fa3", "#d6ecf5", "#ffffff"), ("#5cc0e8", "#113040", "#041a26")),
    "blue": _colors(("#2f5f8f", "#dce7f2", "#ffffff"), ("#7fb1e3", "#16283a", "#071624")),
    "indigo": _colors(("#4a3aa7", "#e3dff6", "#ffffff"), ("#9085e9", "#1f1a3d", "#0d0a24")),
    "violet": _colors(("#7a3c9e", "#ecdff4", "#ffffff"), ("#c08ae0", "#2d1a3a", "#1b0a26")),
    "pink": _colors(("#b8386e", "#f8dde9", "#ffffff"), ("#ec84b1", "#3a1728", "#260a18")),
}


def contrast(a: str, b: str) -> float:
    """The WCAG 2 contrast ratio of two ``#rrggbb`` colours."""
    la, lb = _luminance(a), _luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def _luminance(hex_color: str) -> float:
    def channel(i: int) -> float:
        v = int(hex_color[i : i + 2], 16) / 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4

    return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)


class AppearanceError(ValueError):
    """An icon or tag the rules refuse. ``index`` is the offending tag (``appearance.tags.{i}``);
    None for the icon and for too many tags (``appearance.tags``)."""

    def __init__(self, message: str, index: int | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.index = index


# --- the icon (§2) -----------------------------------------------------------------------

VS16 = "️"
KEYCAP = "⃣"
_PICTOGRAPH = regex.compile(r"\p{Extended_Pictographic}")
_PRESENTATION = regex.compile(r"\p{Emoji_Presentation}")
_REGIONAL = regex.compile(r"\p{Regional_Indicator}")
_ONE_CLUSTER = regex.compile(r"\X")
_KEYCAP_BASES = frozenset("0123456789#*")


def _is(pattern: regex.Pattern[str], scalar: str) -> bool:
    return scalar != "" and pattern.fullmatch(scalar) is not None


def check_icon(value: str) -> str:
    """The stored form of an emoji icon, or :class:`AppearanceError` (§2, the server row).

    1. NFC; refused when empty.
    2. A text-presentation pictograph (``Extended_Pictographic`` without ``Emoji_Presentation``)
       not followed by U+FE0F gets one ("☺" is stored as "☺️"). Keycap bases are not pictographs:
       a keycap needs ``base FE0F 20E3`` as sent. Then at most ``MAX_ICON_LENGTH`` code points, in
       the stored form (so it fits ``VARCHAR(16)`` after the insert).
    3. Exactly one extended grapheme cluster.
    4. It starts as an emoji: a pictograph shown as emoji (by default, or with U+FE0F); or two
       regional indicators (a flag); or a keycap ``[0-9#*] FE0F 20E3``. A lone regional indicator
       and a lone skin-tone modifier are ``Emoji_Presentation`` but not pictographs: refused.
    """
    value = unicodedata.normalize("NFC", value)
    if not value:
        raise AppearanceError("must not be empty")
    if _is(_PICTOGRAPH, value[0]) and not _is(_PRESENTATION, value[0]) and value[1:2] != VS16:
        value = value[0] + VS16 + value[1:]
    if len(value) > MAX_ICON_LENGTH:
        raise AppearanceError(f"must be one emoji of at most {MAX_ICON_LENGTH} code points")
    if _ONE_CLUSTER.fullmatch(value) is None:
        raise AppearanceError("must be a single emoji")
    s0, s1, s2 = value[0], value[1:2], value[2:3]
    emoji = (
        (_is(_PICTOGRAPH, s0) and (_is(_PRESENTATION, s0) or s1 == VS16))
        or (_is(_REGIONAL, s0) and _is(_REGIONAL, s1))
        or (s0 in _KEYCAP_BASES and s1 == VS16 and s2 == KEYCAP)
    )
    if not emoji:
        raise AppearanceError("must be an emoji, not text")
    return value


# --- tags (§1.3, §5) ---------------------------------------------------------------------


def normalize_tag(tag: str) -> str:
    """``str.strip()`` with inner whitespace runs collapsed to one space (Python's
    ``str.isspace``, so U+001C-U+001F count as spaces)."""
    return " ".join(tag.split())


def check_tags(tags: list[str]) -> list[str]:
    """The tags in their stored form, in order, or :class:`AppearanceError`.

    Each tag in turn: normalised (:func:`normalize_tag`), then refused when empty, when it holds a
    control character, when longer than ``MAX_TAG_LENGTH`` code points, or when it equals an
    earlier tag by ``str.casefold()`` (the later one is the error; nothing is dropped). Then at
    most ``MAX_TAGS``. Both clients check in the same order, so they report the same tag.
    """
    out: list[str] = []
    seen: set[str] = set()
    for i, raw in enumerate(tags):
        tag = normalize_tag(raw)
        if not tag:
            raise AppearanceError("must not be empty", i)
        if any(unicodedata.category(c) == "Cc" for c in tag):
            raise AppearanceError("must not contain control characters", i)
        if len(tag) > MAX_TAG_LENGTH:
            raise AppearanceError(f"at most {MAX_TAG_LENGTH} characters", i)
        key = tag.casefold()
        if key in seen:
            raise AppearanceError(f"duplicate tag '{tag}' (tags are unique ignoring case)", i)
        seen.add(key)
        out.append(tag)
    if len(out) > MAX_TAGS:
        raise AppearanceError(f"at most {MAX_TAGS} tags")
    return out


# --- the reminder title (§6.7) -----------------------------------------------------------


def reminder_title(name: str, icon: str | None) -> str:
    """A due reminder's title: ``"{emoji} {name}"`` when the topic has an icon, else the name.
    Channels cut it to their own limit from the end (APNs: 120 scalars), so the emoji stays."""
    return f"{icon} {name}" if icon else name
