"""Topic appearance vectors: ``shared/fixtures/appearance-vectors.json``.

Generated from ``app/services/appearance.py`` (docs/specs/appearance.md §2, §3, §6.7), the
reference implementation: the palette (light and dark swatches, every ``on_tint`` on its ``tint``
at 4.5:1 or better), the emoji icon rule, the tag rule and the reminder title. The PWA
(``appearance.test.ts``) and the iOS app (``TopicThemeTests``) check their palettes, their
``checkIcon``/``checkTags`` and (iOS) the reminder title against the same cases, and must answer
the same. ``QUICKR_UPDATE_VECTORS=1`` (``make vectors``) rewrites the file; otherwise the
committed file must match.
"""

from __future__ import annotations

import re
from typing import Any

from app.schemas.limits import MAX_ICON_LENGTH, MAX_TAG_LENGTH, MAX_TAGS
from app.services import appearance
from app.services.appearance import COLOR_NAMES, MIN_CONTRAST, PALETTE, AppearanceError, Swatch
from app.services.notification import truncate
from app.services.push.apns import MAX_TITLE_LENGTH
from tests.vectors import FIXTURES_DIR, check_or_write, dump_cases

PATH = FIXTURES_DIR / "appearance-vectors.json"
GENERATOR_VERSION = 1

VS16 = "️"
KEYCAP = "⃣"
BLACK_FLAG = "\U0001f3f4"
TAG_G = "\U000e0067"  # TAG LATIN SMALL LETTER G: a grapheme extender
CANCEL_TAG = "\U000e007f"


SCOTLAND = BLACK_FLAG + "\U000e0067\U000e0062\U000e0073\U000e0063\U000e0074" + CANCEL_TAG


def tag_sequence(code_points: int, base: str = BLACK_FLAG) -> str:
    """``base`` and tag characters ending in CANCEL TAG: one cluster of ``code_points``."""
    return base + TAG_G * (code_points - 2) + CANCEL_TAG


# name -> (value, note). The note says where a platform's predicate needs care (§2's table).
ICONS: dict[str, tuple[str, str | None]] = {
    "plain": ("🚬", None),
    "vs16_added": ("☺", "a text-presentation pictograph gets U+FE0F"),
    "vs16_present": ("☺" + VS16, None),
    "presentation_with_vs16": ("🚬" + VS16, "kept as sent"),
    "copyright_bare": ("©", "U+00A9 is Extended_Pictographic, so it gets U+FE0F like ☺"),
    "copyright_vs16": ("©" + VS16, "iOS: isEmoji and !isASCII"),
    "zwj_family": ("👨‍👩‍👧", None),
    "skin_tone": ("👍🏽", None),
    "flag": ("🇮🇪", None),
    "subdivision_flag": (SCOTLAND, "a tag sequence: 7 code points, one cluster"),
    "keycap": ("1" + VS16 + KEYCAP, None),
    "keycap_hash": ("#" + VS16 + KEYCAP, None),
    "keycap_without_vs16": ("1" + KEYCAP, "a keycap needs base FE0F 20E3 as sent"),
    "letter": ("a", None),
    "digit": ("5", "iOS: isEmoji is true for 0-9 # *"),
    "digit_vs16": ("5" + VS16, "not Extended_Pictographic; iOS must check !isASCII"),
    "hash_vs16_no_keycap": ("#" + VS16, "iOS must check !isASCII"),
    "lone_regional_indicator": ("🇮", "Emoji_Presentation but not Extended_Pictographic"),
    "lone_skin_tone": ("🏽", "Emoji_Presentation but not Extended_Pictographic (iOS: isEmojiModifier)"),
    "two_emoji": ("🚬🚬", None),
    "emoji_plus_letter": ("🚬a", None),
    "padded": (" 🚬", "not trimmed: the server refuses what the clients refuse"),
    "empty": ("", None),
    "longest": (tag_sequence(MAX_ICON_LENGTH), "16 code points: the most"),
    "too_long": (tag_sequence(MAX_ICON_LENGTH + 1), "17 code points"),
    "too_long_after_vs16": (
        tag_sequence(MAX_ICON_LENGTH, base="☺"),
        "16 code points as sent, 17 stored: the limit applies after the U+FE0F insert",
    ),
    "text_symbol_no_vs16_unfixable": ("→", "U+2192 is not Extended_Pictographic"),
}

TEN = [f"t{i}" for i in range(1, 11)]

# name -> input
TAGS: dict[str, list[str]] = {
    "none": [],
    "trim": ["  gym  "],
    "collapse": ["morning \t  run"],
    "collapse_before_length": ["a" * 12 + "     " + "b" * 11],
    "order_kept": ["b", "a", "c"],
    "casefold_duplicate": ["Gym", "run", "GYM"],
    "duplicate_after_trim": ["gym", "  GYM "],
    "casefold_full": ["Straße", "STRASSE"],
    "casefold_capital_sharp_s": ["ß", "ẞ"],
    "casefold_dotless_i": ["\u0131", "i"],
    "canonically_equivalent_distinct": ["é", "é"],
    "ten_tags": TEN,
    "eleventh_tag": [*TEN, "t11"],
    "bad_tag_before_count": [*TEN[:3], "  ", *TEN[3:], "t11"],
    "longest": ["a" * MAX_TAG_LENGTH],
    "longest_astral": ["🏃" * MAX_TAG_LENGTH],
    "too_long": ["gym", "a" * (MAX_TAG_LENGTH + 1)],
    "empty": [""],
    "empty_after_trim": ["gym", " \n "],
    "control_character": ["gym\u0007"],
    "delete_character": ["gym\u007f"],
    "python_isspace": ["\u001cgym\u001frun"],
    "nel_is_space": ["a\u0085b"],
    "no_break_space": ["\u00a0gym\u00a0"],
}

LONG_NAME = "Stretch " * 20  # 160 characters

# name -> (topic name, icon)
REMINDER_TITLES: dict[str, tuple[str, str | None]] = {
    "with_icon": ("Water", "💧"),
    "no_icon": ("Water", None),
    "zwj_icon": ("Family time", "👨‍👩‍👧"),
    "flag_icon": ("Irish", "🇮🇪"),
    "cut_keeps_the_emoji": (LONG_NAME, "🧘"),
    "cut_keeps_the_longest_emoji": (LONG_NAME, tag_sequence(MAX_ICON_LENGTH)),
    "cut_without_icon": (LONG_NAME, None),
    "exactly_the_limit": ("x" * (MAX_TITLE_LENGTH - 2), "💧"),
}


def icon_case(name: str, value: str, note: str | None) -> dict[str, Any]:
    try:
        expected: dict[str, Any] = {"ok": True, "value": appearance.check_icon(value)}
    except AppearanceError as exc:
        expected = {"ok": False, "message": exc.message}
    case: dict[str, Any] = {"name": name, "value": value, "expected": expected}
    if note is not None:
        case["note"] = note
    return case


def tags_case(name: str, tags: list[str]) -> dict[str, Any]:
    try:
        expected: dict[str, Any] = {"ok": True, "value": appearance.check_tags(tags)}
    except AppearanceError as exc:
        loc = "tags" if exc.index is None else f"tags.{exc.index}"
        expected = {"ok": False, "loc": loc, "message": exc.message}
    return {"name": name, "input": tags, "expected": expected}


def swatch(s: Swatch) -> dict[str, str]:
    return {"tint": s.tint, "tint_soft": s.tint_soft, "on_tint": s.on_tint}


def build() -> dict[str, Any]:
    return {
        "meta": {
            "generator": "backend/tests/test_appearance_vectors.py",
            "generator_version": GENERATOR_VERSION,
            "colors": list(COLOR_NAMES),
            "max_tags": MAX_TAGS,
            "max_tag_length": MAX_TAG_LENGTH,
            "max_icon_length": MAX_ICON_LENGTH,
            "max_title_length": MAX_TITLE_LENGTH,
            "min_contrast": MIN_CONTRAST,
            "semantics": [
                "palette: the twelve names in palette order; light and dark {tint, tint_soft, on_tint} "
                "as lowercase #rrggbb. Every on_tint on its tint has a WCAG 2 contrast of at least "
                "min_contrast. Text on tint_soft is ink, never tint.",
                "icons: NFC, then a first scalar that is Extended_Pictographic but not "
                "Emoji_Presentation, not followed by U+FE0F, gets U+FE0F after it; then at most "
                "max_icon_length code points (the stored form); then exactly one extended grapheme "
                "cluster; then it starts as an emoji: s0 Extended_Pictographic and (s0 "
                "Emoji_Presentation or s1 == U+FE0F), or s0 and s1 regional indicators, or s0 in "
                "[0-9#*] with s1 == U+FE0F and s2 == U+20E3. The value is not trimmed. expected.value "
                "is the stored form; a refusal's message is the server's (clients word their own).",
                "tags: each tag in order: Python str.strip() and inner whitespace runs collapsed to one "
                "space (str.isspace: Unicode White_Space plus U+001C-U+001F); refused when empty, when "
                "it holds a control character (Cc), when longer than max_tag_length code points, or "
                "when its str.casefold() equals an earlier tag's (the later one is refused, nothing is "
                "dropped); then at most max_tags. loc is tags.{i} for a tag, tags for the count; the "
                "first failing tag wins, before the count.",
                "reminder_titles: the title is '{icon} {topic_name}' with an icon, else topic_name; "
                "expected is that title cut to max_title_length Unicode scalars with '…' (APNs and the "
                "iOS local reminder); the cut is from the end, so the emoji stays.",
            ],
        },
        "palette": [
            {"name": name, "light": swatch(PALETTE[name].light), "dark": swatch(PALETTE[name].dark)}
            for name in COLOR_NAMES
        ],
        "icons": [icon_case(name, value, note) for name, (value, note) in ICONS.items()],
        "tags": [tags_case(name, tags) for name, tags in TAGS.items()],
        "reminder_titles": [
            {
                "name": name,
                "topic_name": topic_name,
                "icon": icon,
                "expected": truncate(appearance.reminder_title(topic_name, icon), MAX_TITLE_LENGTH),
            }
            for name, (topic_name, icon) in REMINDER_TITLES.items()
        ],
    }


def test_appearance_vectors_match_committed() -> None:
    check_or_write(PATH, dump_cases(build()))


HEX = re.compile(r"#[0-9a-f]{6}")


def test_palette_contrast_and_shape() -> None:
    palette = build()["palette"]
    assert [p["name"] for p in palette] == list(COLOR_NAMES)
    assert len(COLOR_NAMES) == 12
    for p in palette:
        for mode in ("light", "dark"):
            s = p[mode]
            assert all(HEX.fullmatch(v) for v in s.values()), p
            ratio = appearance.contrast(s["on_tint"], s["tint"])
            assert ratio >= MIN_CONTRAST, f"{p['name']} {mode}: {ratio:.2f}"


def test_contrast_is_wcag() -> None:
    assert appearance.contrast("#000000", "#ffffff") == 21
    assert appearance.contrast("#777777", "#777777") == 1


def test_vectors_cover_the_spec() -> None:
    doc = build()
    icons = {c["name"]: c["expected"] for c in doc["icons"]}
    assert len(icons) >= 17
    accepted = {"plain", "vs16_added", "vs16_present", "copyright_vs16", "zwj_family", "skin_tone"}
    accepted |= {"flag", "subdivision_flag", "keycap", "keycap_hash", "longest", "copyright_bare"}
    assert {n for n, e in icons.items() if e["ok"]} == accepted | {"presentation_with_vs16"}
    assert icons["vs16_added"]["value"] == "☺" + VS16
    assert icons["copyright_bare"]["value"] == "©" + VS16
    assert len(icons["longest"]["value"]) == MAX_ICON_LENGTH
    assert len(ICONS["too_long_after_vs16"][0]) == MAX_ICON_LENGTH  # as sent; stored would be 17

    tags = {c["name"]: c["expected"] for c in doc["tags"]}
    assert len(tags) >= 8
    assert tags["trim"]["value"] == ["gym"]
    assert tags["collapse"]["value"] == ["morning run"]
    assert tags["casefold_duplicate"] == {
        "ok": False,
        "loc": "tags.2",
        "message": "duplicate tag 'GYM' (tags are unique ignoring case)",
    }
    assert tags["casefold_full"]["loc"] == "tags.1"
    assert tags["casefold_dotless_i"]["ok"]
    assert tags["eleventh_tag"]["loc"] == "tags"
    assert tags["bad_tag_before_count"]["loc"] == "tags.3"
    assert tags["too_long"]["loc"] == "tags.1"
    assert tags["empty_after_trim"]["loc"] == "tags.1"
    assert tags["control_character"]["loc"] == "tags.0"
    assert tags["python_isspace"]["value"] == ["gym run"]
    assert tags["nel_is_space"]["value"] == ["a b"]
    assert tags["order_kept"]["value"] == ["b", "a", "c"]

    titles = {c["name"]: c["expected"] for c in doc["reminder_titles"]}
    assert titles["with_icon"] == "💧 Water"
    assert titles["no_icon"] == "Water"
    for name in ("cut_keeps_the_emoji", "cut_keeps_the_longest_emoji", "cut_without_icon"):
        assert len(titles[name]) == MAX_TITLE_LENGTH
        assert titles[name].endswith("…")
    assert titles["cut_keeps_the_emoji"].startswith("🧘 Stretch")
    assert titles["cut_keeps_the_longest_emoji"].startswith(tag_sequence(MAX_ICON_LENGTH) + " ")
    assert titles["exactly_the_limit"] == "💧 " + "x" * (MAX_TITLE_LENGTH - 2)  # 120: not cut
