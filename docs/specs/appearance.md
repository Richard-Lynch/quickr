# Spec: topic appearance (colour, emoji, tags; photos in phase B)

**Status:** draft (revision 3, 2026-11-25, after review round 2). **Applies
to:** the backend (topic schema, limits, feed, reminders, MCP), the PWA, the iOS
app (app, widgets, Live Activity, store) and, in phase B, hosting (nginx, docker
volumes). **Companion specs:** [active-surfaces.md](active-surfaces.md) (M2
consumes the theme API), [content-display.md](content-display.md) (M4 topic
header), [timers2.md](timers2.md) (M1 owns `RunActivity.swift`; M3 patches
`attributes.appearance`), [sync-protocol.md](../ios/specs/sync-protocol.md)
(§4.2 upsert guards, §4.3 tombstones),
[notifications.md](../ios/specs/notifications.md) (reminder payloads) and
[client-versions.md](client-versions.md) (additive at level 2). **Plan:**
[t2-plan.md](t2-plan.md) (milestones M3a and M3b).

## Purpose

The user's words (requirements.md, item 9 and its clarification):

> 9. I want to be able to customise tasks with colors, images, labels, etc.

> **#9, images:** both. Icon/emoji first (rendered on every client, including
> widgets and Live Activities), with photo upload (server-side image storage) as
> a later phase.

Phase A (M3a) is colour, emoji icon and tags; phase B (M3b, part II of this
spec) is photos. Appearance is **topic-level and unversioned**: it never changes
what an entry means, so it follows the `PATCH /topics/{ref}` + `revision` path
(`backend/app/services/topics.py:348-369`), not a version.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]**, **[ios]** and **[pwa]** mark who implements a rule.

## Glossary

- **Appearance** — `{color, icon, tags}` on a topic. Always present in output
  (defaults `null`, `null`, `[]`).
- **Colour name** — one of twelve fixed names (§3). No free hex (OQ-8).
- **Palette** — the name → `{tint, tintSoft, onTint}` table per light/dark mode,
  pinned by `appearance-vectors.json`.
- **Glyph** — what stands in for the topic before its name: the emoji, or the
  name's first grapheme on the tint when there is none.
- **Theme** — a client-side value `{tint, tintSoft, onTint, glyph}` derived from
  an appearance (§4). The **default theme** is the brand accent and no glyph.
- **Tag** — a short free-text label on a topic (§5); a home filter.
- **Photo** (phase B) — one JPEG per topic on the server, served in three sizes,
  identified by an **etag**.

---

# Part I — Phase A (M3a): colour, emoji, tags

## 1. Model **[server]**

### 1.1 Wire shape

```
Appearance = {
  color: ColorName | null,                       // "red" | "orange" | "amber" | "yellow" | "lime" | "green" | "teal" | "cyan" | "blue" | "indigo" | "violet" | "pink"
  icon:  { kind: "emoji", value: str } | null,   // one emoji grapheme cluster (§2)
  tags:  str[]                                   // ≤ 10, each 1..24 chars, trimmed, unique casefolded, order kept
}
```

- `TopicSummary.appearance: Appearance` and therefore `TopicDetail`, every
  `listTopics` item and the `topic` feed item (`FeedTopic` embeds `TopicDetail`,
  `schemas/api.py:1217-1223`). Output is normalised: the three keys are always
  present.
- `TopicCreate.appearance: Appearance | None = None` (`schemas/api.py:205-213`
  gains the field); `None` = defaults.
- `TopicUpdate.appearance: AppearanceUpdate | None = None` where

  ```
  AppearanceUpdate = { color?: ColorName | null, icon?: Icon | null, tags?: str[] }
  ```

  **PATCH semantics:** an omitted field is unchanged; `color: null` and
  `icon: null` clear; `tags: []` clears. `appearance: null` is refused with 422
  `invalid_request` ("clear fields individually") — the same stance as
  `EntryUpdate.timing: null` (`_timing_not_null`). Any present field bumps
  `revision` (`update_topic` already bumps unconditionally, `topics.py:363`) and
  logs the topic (`_log_topic`, `:368`), so the feed re-sends the detail.

- `expected_revision` applies as to any `TopicUpdate`.
- `icon.kind` is an enum with the single value `"emoji"` in phase A (OQ-7); a
  future `"symbol"` kind is a schema addition, not a change.

### 1.2 Columns and migration

Alembic `20261127_f7a4b0c5d326_topic_appearance` (down `e6f3a9b4c215`; M1 merges
to `feat/t2` first):

```sql
ALTER TABLE topics ADD COLUMN color VARCHAR(16) NULL;
ALTER TABLE topics ADD COLUMN icon  VARCHAR(16) NULL;            -- ≤ 16 code points, NFC
ALTER TABLE topics ADD COLUMN tags  JSONB NOT NULL DEFAULT '[]'::jsonb;
```

No index: topic counts are small and `list_topics` already sorts in Python
(`topics.py:245-253`). Downgrade drops the three columns. `_summaries`
(`topics.py:132-164`) maps them; `_base_select` (`:167-183`) needs no join.

### 1.3 Validation and limits

In `backend/app/services/appearance.py` (new; the reference implementation the
vectors are generated from):

| Rule                                                                                                                                  | Error (422, dotted path) |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `color` ∈ the twelve names                                                                                                            | `appearance.color`       |
| `icon.value` is one emoji grapheme after normalisation (§2); ≤ `MAX_ICON_LENGTH` = 16 code points                                     | `appearance.icon.value`  |
| each tag: `str.strip()`, internal whitespace runs collapsed to one space, 1..`MAX_TAG_LENGTH` = 24 code points, no control characters | `appearance.tags.{i}`    |
| ≤ `MAX_TAGS` = 10 tags                                                                                                                | `appearance.tags`        |
| unique by `str.casefold()` (first occurrence wins; a duplicate is an error, not dropped)                                              | `appearance.tags.{i}`    |

Constants go in `schemas/limits.py`; `GET /limits` (`schemas/api.py:766-791`)
gains:

```
max_tags: int = 10
max_tag_length: int = 24
max_icon_length: int = 16
color_names: list[str] = [...]   // the twelve, in palette order
```

mirrored in `frontend/src/api/limits.ts` `FALLBACK_LIMITS` (`:14-38`), iOS
`Limits` (`QuickrCore/Models/ServerInfo.swift:4-27`) and
`Limits.serverDefaults`, and the `shared/fixtures/api/getLimits.json` fixture
(`make vectors`).

## 2. Emoji validation

Python's `unicodedata` has no `Emoji_Presentation` property and no grapheme
segmentation, so the server uses the `regex` package (added to
`backend/pyproject.toml`; it supports `\X` and Unicode emoji properties).
`appearance.check_icon(value: str) -> str` returns the stored form:

1. `value = unicodedata.normalize("NFC", value)`; reject if empty.
2. **Normalise text-presentation pictographs:** if the first scalar is
   `\p{Extended_Pictographic}` without `\p{Emoji_Presentation}` and the second
   scalar is not U+FE0F, insert U+FE0F after it (so "☺" is stored as "☺️").
   Keycap bases (`[0-9#*]`) are not pictographs; they need the full
   `base FE0F 20E3` sequence as sent. Then reject if the result is more than
   16 code points: the limit applies to the **stored** form, so it fits
   `VARCHAR(16)` after the VS16 insert.
3. Reject unless `regex.fullmatch(r"\X", value)` (exactly one extended grapheme
   cluster).
4. Reject unless the cluster **starts** as an emoji, per the **server** row of
   the table below. This admits ZWJ sequences (👨‍👩‍👧), skin-toned emoji, flags and
   keycaps, and refuses letters, digits, "abc", two emoji, a bare pictograph the
   normalisation could not fix, a **lone regional indicator** (🇮) and a **lone
   skin-tone modifier** (🏽) — neither is `\p{Extended_Pictographic}`, although
   both are `\p{Emoji_Presentation}`.

**Exact predicates per platform** (after the shared NFC + VS16 normalisation of
steps 1–2 and the one-cluster check of step 3; `s0` is the first scalar, `s1`
the second):

| Platform   | One cluster                                                                            | Starts as an emoji                                                                                                                                                                                                                                                                                                                                         |
| ---------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **server** | `regex.fullmatch(r"\X", value)`                                                        | `s0 ∈ \p{Extended_Pictographic}` and (`s0 ∈ \p{Emoji_Presentation}` or `s1 == U+FE0F`); or `s0, s1 ∈ \p{Regional_Indicator}`; or `s0 ∈ [0-9#*]` and `s1 == U+FE0F` and `s2 == U+20E3` (keycap)                                                                                                                                                             |
| **iOS**    | `value.count == 1` (one `Character`)                                                   | `s0` is neither a regional indicator (U+1F1E6–1F1FF) nor `isEmojiModifier`, and (`s0.properties.isEmojiPresentation`, or `s0.properties.isEmoji && !s0.isASCII` and `s1 == U+FE0F`); or `s0`, `s1` both in U+1F1E6–1F1FF; or the keycap sequence as on the server. Swift has no `Extended_Pictographic`; `isEmoji` is true for `0–9 # *`, hence `!isASCII` |
| **PWA**    | `[...new Intl.Segmenter('en', {granularity: 'grapheme'}).segment(value)].length === 1` | the server row, as `s0`/`s1`/`s2` checks with `\p{…}` property escapes (`u` or `v` flag): `\p{Extended_Pictographic}` on `s0` and (`\p{Emoji_Presentation}` on `s0` or `s1 == U+FE0F`); or `\p{Regional_Indicator}` on `s0` and `s1`; or the keycap                                                                                                        |

Where the platforms differ: a **digit or `#`/`*` followed by VS16** (`5️`) is
refused everywhere (server: not `Extended_Pictographic`; iOS: `isASCII`);
`©️`/`®️` (U+00A9/U+00AE + VS16) are accepted everywhere (both properties,
non-ASCII). The only known divergence is an **unassigned** code point in an
`Extended_Pictographic` reserved range followed by VS16: the server (Unicode
tables of `regex`) accepts it, iOS (`isEmoji` false on unassigned scalars)
refuses; the vectors contain no such case and the behaviour is not pinned. Both
clients apply the normalisation of step 2 before sending. The clients' pickers
(§7) normally produce valid input; the rule exists for the API and MCP.

## 3. Palette

### 3.1 Values

Twelve names, fixed (OQ-8). `tint` is the fill (buttons, accent bar, Live
Activity primary); `tintSoft` the wash (card background, badge background);
`onTint` the text on `tint`. Every `onTint`-on-`tint` pair has WCAG contrast ≥
4.5:1 (checked by the generator and asserted in the vector test). Text on
`tintSoft` is always `ink`, never `tint` (yellow's soft/tint pair is 1.5:1).

| Name   | Light tint | Light tintSoft | Light onTint | Dark tint | Dark tintSoft | Dark onTint |
| ------ | ---------- | -------------- | ------------ | --------- | ------------- | ----------- |
| red    | `#c2362b`  | `#f8dcd8`      | `#ffffff`    | `#ff7b6e` | `#3b1714`     | `#1b0d04`   |
| orange | `#c2470a`  | `#fde4d4`      | `#ffffff`    | `#ff7a2e` | `#3a2214`     | `#1b0d04`   |
| amber  | `#9e5406`  | `#fbe7c6`      | `#ffffff`    | `#f0a63a` | `#3a2a0e`     | `#1b1204`   |
| yellow | `#f2c230`  | `#fbf0c4`      | `#1b1915`    | `#f5cf4f` | `#3a3110`     | `#1b1804`   |
| lime   | `#4f7a0c`  | `#e6f2cc`      | `#ffffff`    | `#a9d64c` | `#243410`     | `#101a04`   |
| green  | `#2f7d4f`  | `#dcefe2`      | `#ffffff`    | `#5cc28a` | `#173323`     | `#04170c`   |
| teal   | `#19786f`  | `#d4eeea`      | `#ffffff`    | `#4fc4b7` | `#113330`     | `#04201c`   |
| cyan   | `#1c7fa3`  | `#d6ecf5`      | `#ffffff`    | `#5cc0e8` | `#113040`     | `#041a26`   |
| blue   | `#2f5f8f`  | `#dce7f2`      | `#ffffff`    | `#7fb1e3` | `#16283a`     | `#071624`   |
| indigo | `#4a3aa7`  | `#e3dff6`      | `#ffffff`    | `#9085e9` | `#1f1a3d`     | `#0d0a24`   |
| violet | `#7a3c9e`  | `#ecdff4`      | `#ffffff`    | `#c08ae0` | `#2d1a3a`     | `#1b0a26`   |
| pink   | `#b8386e`  | `#f8dde9`      | `#ffffff`    | `#ec84b1` | `#3a1728`     | `#260a18`   |

Red, orange, green, blue and indigo reuse the brand's `danger`, `accent-strong`,
`ok`, `info` and `series-4` values (`frontend/src/index.css:24-45, :93-108`) so
a themed topic sits naturally beside untinted chrome. The table is the source of
truth in `services/appearance.py`; `index.css` and `TopicColors.xcassets` copy
it and the drift tests (§3.3) catch divergence.

### 3.2 `appearance-vectors.json`

Generated by `backend/tests/test_appearance_vectors.py`
(`GENERATOR_VERSION = 1`, `check_or_write`, `dump_cases` as `tests/vectors.py`
does), README row added:

```
{ "meta": { "generator", "generator_version": 1, "colors": [12 names], "max_tags": 10, "max_tag_length": 24, "max_icon_length": 16,
            "min_contrast": 4.5, "semantics": [prose rules of §2 and §1.3] },
  "palette": [ { "name", "light": {"tint","tint_soft","on_tint"}, "dark": {...} } × 12 ],
  "icons":   [ { "name", "value", "expected": {"ok": true, "value": stored} | {"ok": false, "message"} } ],
  "tags":    [ { "name", "input": [..], "expected": {"ok": true, "value": [..]} | {"ok": false, "loc": "tags.2", "message"} } ],
  "reminder_titles": [ { "name", "topic_name", "icon", "expected" } ] }
```

`icons[]` (≥ 17): `plain` (🚬), `vs16_added` (☺ → ☺️), `vs16_present` (☺️),
`copyright_vs16` (©️ ✓), `zwj_family`, `skin_tone`, `flag`, `keycap` (1️⃣),
`letter` (✗), `digit` (✗), `digit_vs16` (`5️` ✗ — iOS must check `!isASCII`),
`hash_vs16_no_keycap` (`#️` ✗), `lone_regional_indicator` (🇮 ✗),
`lone_skin_tone` (🏽 ✗), `two_emoji` (✗), `emoji_plus_letter` (✗), `empty`
(✗), `too_long` (✗, 17 code points of tag characters),
`text_symbol_no_vs16_unfixable` (✗, e.g. "→"). Every case carries one
`expected`; the three validators MUST agree on all of them (§2). `tags[]` (≥ 8):
trim, collapse, casefold duplicate, eleventh tag, 25-char tag, empty after trim,
order kept, control character. `reminder_titles[]` (§6.6).

### 3.3 Consumers

- **[ios]** `QuickrDesignTests/TopicThemeTests`: every palette entry equals the
  colour in `QuickrUI/Resources/TopicColors.xcassets` (light and dark, as
  `TokenDriftTests` compares `Colors.xcassets` to `index.css`); `checkIcon` and
  `checkTags` over `icons[]`/`tags[]`.
- **[pwa]** `src/lib/appearance.test.ts`: `PALETTE` equals the vectors;
  `index.css` `@theme` topic variables (§4.2) are generated from `PALETTE` by a
  small script or asserted equal; `checkIcon`/`checkTags` over the vectors.

## 4. Theme API

### 4.1 iOS `QuickrUI/Tokens/TopicTheme.swift` **[ios]**

```swift
public struct TopicTheme: Sendable, Hashable {
    public var tint: Color
    public var tintSoft: Color
    public var onTint: Color
    public var glyph: TopicGlyph?                  // nil: no emoji; views may fall back to the initial
    public init(appearance: TopicAppearance?, name: String)   // nil or color nil → accent tokens; icon → .emoji
    public static let `default`: TopicTheme        // accent, accentSoft, onAccent, glyph nil
}
public enum TopicGlyph: Sendable, Hashable { case emoji(String); case initial(String) }

public struct TopicGlyphView: View {                // emoji at `size`, or the initial on a tint circle
    public init(theme: TopicTheme, size: CGFloat = 22, fallbackInitial: Bool = true)
}
extension EnvironmentValues { public var topicTheme: TopicTheme }        // default .default
extension View {
    public func topicTheme(_ theme: TopicTheme) -> some View
    public func topicTheme(for topic: Topic) -> some View                 // TopicTheme(appearance: topic.appearance, name: topic.name)
}
```

Colours come from `TopicColors.xcassets` (`topic-red-tint`, `topic-red-soft`,
`topic-red-on`, … with light/dark appearances), kept **outside**
`Colors.xcassets` so `TokenDriftTests` (which compares that catalogue to
`index.css` brand tokens) is unchanged; `TopicThemeTests` covers the new
catalogue against the vectors. `TopicAppearance` (`color: ColorName?`,
`icon: Icon?`, `tags: [String]`) lives in a new
`QuickrCore/Models/TopicAppearance.swift` and `Topic`/`TopicSummary` gain
`appearance: TopicAppearance` (default empty) — a patch to M1's `Topic.swift`
limited to one stored property each. Widgets and the Live Activity link QuickrUI
already (`project.yml:117-121`), so they use the same type.

### 4.2 PWA `src/lib/appearance.ts` **[pwa]**

```ts
export const COLOR_NAMES = ['red', ...] as const;
export type ColorName = (typeof COLOR_NAMES)[number];
export interface Appearance { color: ColorName | null; icon: { kind: 'emoji'; value: string } | null; tags: string[] }
export const PALETTE: Record<ColorName, { light: Swatch; dark: Swatch }>;   // Swatch = {tint, tintSoft, onTint}
/** CSS variables for a themed element; {} for null/none (the brand accent applies). */
export function topicStyle(a: Appearance | null | undefined): CSSProperties;  // --topic-tint, --topic-tint-soft, --topic-on-tint
export function glyphOf(a: Appearance | null | undefined, name: string): { kind: 'emoji'; value: string } | { kind: 'initial'; value: string };
export function checkIcon(value: string): { ok: true; value: string } | { ok: false; message: string };
export function checkTags(tags: readonly string[]): { ok: true; value: string[] } | { ok: false; index: number; message: string };
```

`index.css` adds, in `@theme inline`,
`--color-topic-tint: var(--topic-tint, var(--color-accent))`,
`--color-topic-tint-soft: var(--topic-tint-soft, var(--color-accent-soft))`,
`--color-topic-on-tint: var(--topic-on-tint, var(--color-on-accent))` (so
`bg-topic-tint`, `bg-topic-tint-soft`, `text-topic-tint`, `text-topic-on-tint`,
`border-topic-tint` utilities exist and default to the accent; `inline` makes
each utility read the variable on the element itself, which a plain `@theme`
token resolved on `:root` would not). `src/topicColors.css` (imported from
`index.css`, outside `TokenDriftTests`' scan) holds the `--topic-<name>-*` root
variables, light and dark under `@media (prefers-color-scheme: dark)`, and
twelve `[data-topic-color="red"] { --topic-tint: …; --topic-tint-soft: …;
--topic-on-tint: … }` blocks. `topicStyle` sets the three
variables inline so a themed subtree needs no attribute; the `data-topic-color`
blocks serve static markup. `<TopicGlyph appearance name size/>`
(`src/components/ui/TopicGlyph.tsx`) renders the emoji (`role="img"`,
`aria-label={name}`) or the initial on a `bg-topic-tint text-topic-on-tint`
circle.

### 4.3 Rules every consumer follows

- A theme never changes **semantic** colours: `danger` (Stop, Discard), `warn`
  (Paused, Add details), `ok`. Only accent-coloured chrome is re-tinted.
- Text on `tintSoft` is `ink`/`inkSoft`; text on `tint` is `onTint`.
- The default theme is indistinguishable from today's UI: a topic with no
  appearance looks exactly as it does on `main`, and a topic without a colour
  adds no accent-coloured chrome (no tint rule, no initial circle); its emoji
  and tag chips still render where §5 and §6 place them.

## 5. Tags

- Chips: `QuickrBadge(tag)` / `<Badge>` neutral, in the tile footer under the
  summary line (idle tiles; M2's active card shows none) and in the topic header
  (§6.3). At most three chips on a tile, then "+2".
- **Home filter [server] [pwa] [ios]:** `GET /topics?tag=<exact tag text>`
  filters `Topic.tags ? :tag` (JSONB `?` containment): the match is on the
  **stored spelling, exactly** — no casefolding at query time (B4). Uniqueness
  is casefolded **on write** (§1.3), so a topic can hold "Gym" or "gym" but not
  both, and a chip tap always sends the stored text, which is why an exact match
  is enough. (`gym` typed by hand does not match "Gym"; the filter is
  chip-driven.) The PWA adds `tag` to the URL params read at
  `TopicsPage.tsx:55-74` and `listTopicsInfiniteOptions`; tapping a chip sets
  it; the filter panel shows a "Tag" row with the active tag and a clear ✕. iOS
  filters locally in `TopicListing.matches`
  (`QuickrCore/Home/TopicListing.swift`; a tag match joins the name/question
  search with an explicit `tag:` term is **not** added — a tapped chip sets
  `HomeModel.tagFilter`), and `home-vectors.json` is unchanged because the
  server's `?tag=` is a separate query, not a sort. Where the filter touches
  M2-owned home files (`HomeView.swift`, `HomeModel.swift`, `TopicsPage.tsx`) it
  lands through the **T2-WIRE-I/F** wiring WP named in t2-plan.md, not in an M3
  WP.
- MCP `list_topics` gains `tag: str | None`.

## 6. Rendering per surface

| Surface                         | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 6.1 Tile (idle)                 | `TileView` accent bar (`TileView.swift:85`), border (`:88`) and Log/Start block (`:101-105`) use `tint`/`tintSoft`/`onTint` via `\.topicTheme`; glyph before the title (`:54`). PWA `TopicTile.tsx:107-114` border/bar and the action column (`:172-178`, `:202-207`) use the `topic-*` utilities; `<TopicGlyph/>` in the `<h2>`.                                                                                                                          |
| 6.2 Active card                 | active-surfaces.md §3.2 / §6.2: `tintSoft` background, `tint` primary.                                                                                                                                                                                                                                                                                                                                                                                     |
| 6.3 Topic header                | iOS `App/Entries/TopicTabsView.swift`: a header row above the segmented picker with the glyph (28 pt), name, and tag chips; a 4 pt `tint` rule under it. PWA `TopicLayout.tsx:154-206`: glyph before the name, chips under the version tag.                                                                                                                                                                                                                |
| 6.4 Run screen / run panel      | The primary button `tint`/`onTint`; the Running badge tone stays accent-coloured but uses `tint` for its dot; the total clock stays `ink`.                                                                                                                                                                                                                                                                                                                 |
| 6.5 Live Activity               | `RunActivityAttributes` gains `appearance: TopicAppearance?` (optional; M3 patches M1's `RunActivity.swift` and `live_activity.attributes`, `live_activity.py:157-163`, vectors `attributes` gain the key). Set at start: a colour change mid-run shows at the next run (accepted). Lock Screen background `tintSoft`, primary `tint`, glyph before the topic name.                                                                                        |
| 6.6 Widgets                     | Full-colour: accent bar and the primary chip in `tint`, glyph before the name. Tinted/accented modes (`WidgetStyle.isAccented`): no fills, glyph shown as text (emoji render monochrome in accented mode — accepted), nothing else changes.                                                                                                                                                                                                                |
| 6.7 Reminder title **[server]** | `scheduler.py:199` builds `title=name`; it becomes `f"{icon} {name}"` when the topic has an icon, on both APNs (`apns.render`, truncated to `MAX_TITLE_LENGTH`, `apns.py:107`) and Web Push (`web.render`, `web.py:233`). `apns-payload-vectors.json` gains `timed_with_icon`; `reminder_titles[]` in the appearance vectors pins the composition (emoji, no emoji, truncation keeps the emoji). iOS `DueReminder` (local fallback) composes the same way. |
| 6.8 Due list widget, Control    | Due rows prefix the glyph; `TimerControlValue.title` stays "Timer: {name}" (Controls render one SF Symbol only).                                                                                                                                                                                                                                                                                                                                           |

## 7. Builder and settings UI

- **[pwa]** `TopicMetaFields.tsx` (new topic) and `SettingsPage.tsx` `MetaForm`
  (`:73-186`) gain an **Appearance** card: a row of twelve swatches (radio
  group, `aria-label` = name, a ✓ on the chosen one, "None" first); an emoji
  field: a curated grid of 24 (🚬 🏃 😴 💊 🍺 ☕ 🧘 🏋️ 🚿 🛏️ 🦷 💧 🍽️ 🚶 📚 🧹
  🐕 🚗 💼 🎸 🩺 🧠 ❤️ ⭐) plus a free text input validated by `checkIcon`; a
  tags editor (chips with ✕, an input that commits on Enter or comma,
  `checkTags` errors inline). `makeTopicMetaSchema`/`makeTopicDraftSchema`
  (`builder.ts:816-842, :882-889`) add `appearance`; `serverErrors.ts`
  `builderFieldFor` maps `appearance.*` paths. `useUpdateTopicMeta`
  (`mutations.ts:225-247`) patches `appearance` optimistically through
  `patchTopics` (`cache.ts:89-120`).
- **[ios]** `NewTopicScreen.topicSection` and `TopicSettingsView.detailsSection`
  get an Appearance row opening `AppearanceEditorView` (new,
  `App/Topics/Builder/AppearanceEditorView.swift`): swatches
  (`topic.color.<name>`), an emoji `TextField` (`topic.icon`) limited by
  `checkIcon` with the system emoji keyboard (`.keyboardType(.default)`; iOS has
  no emoji-only keyboard type — the field's placeholder says "Emoji"), tags
  (`topic.tags` container, `topic.tags.add` input, `topic.tags.<i>` chips with
  their ✕). **Accessibility ids live in this spec only** (B3); the plans and the
  UI tests on both sides of the seam key on these names.
  `TopicDraft`/`NewTopicModel`/`TopicSettingsModel.saveDetails` carry
  `appearance`; `TopicDetailsChange` (`QuickrUI/Topics/TopicWriter.swift`) gains
  `appearance: AppearanceUpdate?`; `TopicWrites` sends it in
  `TopicUpdateDTO`/`TopicCreateDTO`
  (`QuickrData/Contracts/TopicRequestDTO.swift`). M1 MUST NOT edit these
  sections; M3 MUST NOT edit `TimerSections` (brief §5).

## 8. Feed and stores

- **[server]** Nothing beyond `_log_topic` on PATCH: the topic item already
  carries `TopicDetail`.
- **[ios]** `StoreSchema+T2M3.swift` registers `t2m3_topic_appearance`:

  ```sql
  ALTER TABLE topic ADD COLUMN color TEXT;            -- and stage_topic
  ALTER TABLE topic ADD COLUMN icon TEXT;
  ALTER TABLE topic ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]';
  ```

  (`StoreSchema.swift:23-25` gets one line in `migrations`.) **Re-pull:** the
  migration **resets the feed cursor** so every topic is re-pulled, exactly as
  `v2` did for `timer_json` (`StoreSchema.swift:105-119`). Without it a topic
  themed on another device before this build upgraded would stay unthemed for
  good: nothing re-sends a topic whose own fields don't change (review C-S2).
  The reset is epoch-safe (the cursor restarts at 0 in the same epoch;
  sync-protocol.md §5) and costs one bootstrap of topics and versions; entries
  and runs are re-applied through the §4.2 revision guard. The planner records
  this on I3-STORE. `TopicDetailDTO`/`TopicSummaryDTO` gain
  `@RequiredKey appearance` (`TopicDTO.swift:34-41` pattern), `StoreView` maps
  the columns, the upsert guard rules of sync-protocol.md §4.2 apply unchanged.
  `api/*.json` fixtures regenerate.

- **[pwa]** `patchTopics` applies the optimistic appearance; `setTopicDetail` on
  success (as `useUpdateTopicMeta` does today).

## 9. MCP **[server]**

`create_topic` gains `color: ColorName | None`, `icon: str | None` (emoji),
`tags: list[str] | None`; `update_topic` gains the same plus `clear_color`,
`clear_icon: bool = False` (mirroring `clear_schedule`, `mcp_server.py:194`);
`list_topics` gains `tag`. `INSTRUCTIONS` names the twelve colours. Tests in
`test_mcp.py` per area-B §7 (one tool test each, error surfacing for a bad
emoji).

## 10. Compatibility

Additive at api_level 2: new optional request fields, new always-present
response fields that level-2 clients ignore (`StrictModel` is `extra=forbid` on
**requests**; the iOS DTOs decode unknown keys by ignoring them, the PWA's
generated types widen). No `api_level` bump; no `supported-clients.json` change.
`make openapi client vectors` at every merge (brief §5).

---

# Part II — Phase B (M3b): photos

## 11. Endpoints **[server]**

| Op id              | Route                                                       | Notes                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `uploadTopicPhoto` | `POST /topics/{ref}/photo` (multipart, field `file`)        | `ExpectIdentity`; ≤ `MAX_PHOTO_BYTES` = 5 000 000 (under nginx's `client_max_body_size 5m`, `frontend/nginx.conf:19`); accepted `image/jpeg`, `image/png`, `image/heic`, `image/heif` (sniffed, not trusted from the header); 201 with `TopicDetail`; 413 `photo_too_large`, 415 `photo_unsupported` (new `DomainError`s, terminal on both clients) |
| `getTopicPhoto`    | `GET /topics/{ref}/photo?size=thumb\|medium\|full&v=<etag>` | `image/jpeg`; `ETag: "<etag>"`; with a matching `v`: `Cache-Control: private, max-age=31536000, immutable`; without `v` or mismatched: `Cache-Control: private, no-cache` and `If-None-Match` → 304; 404 when none                                                                                                                                  |
| `deleteTopicPhoto` | `DELETE /topics/{ref}/photo`                                | `ExpectIdentity`; 204 always. When `photo_etag` is set: cleared, `revision += 1`, topic logged. When it is already null: **a no-op** — no revision bump, no log row, still 204 — so a retry after a lost response writes nothing (review C-S2)                                                                                                      |

`expected_revision` is accepted as a query parameter on upload and delete (the
`ExpectedRevision` dependency, `routes.py:75-81`). Both mutations are `@writer`
service functions for the **row** part only (area-B §7 rules 1, 7): image work
happens before the writer, and **no file is ever deleted by a request** — the
garbage collector of §12.1 is the only deleter.

## 12. Storage and pipeline **[server]**

- `Settings.media_dir: str = "/app/media"` (`QUICKR_MEDIA_DIR`,
  `backend/app/config.py`). Layout:
  `QUICKR_MEDIA_DIR/topics/{topic_id}/{etag}.{size}.jpg` with sizes `full`
  (longest side ≤ 1600 px), `medium` (512 px) and `thumb` (128 px, centre-
  square). `etag` = first 16 hex characters of SHA-256 of the **uploaded bytes**
  (the original): files are content-addressed, so the same upload always lands
  on the same names and a re-upload of a current photo changes nothing.
- Pillow (`pillow>=11` added) plus **`pillow-heif`** for HEIC/HEIF: iPhone
  cameras produce HEIC by default and the PWA on iOS hands the file over as is,
  so refusing it would make the common path fail; `pillow-heif` ships manylinux
  wheels with `libheif` bundled, so the `python:3.14-slim` image needs no apt
  package. Pipeline, in a worker thread (`run_in_threadpool`) **before** the
  writer: open → `ImageOps.exif_transpose` → convert to RGB (flatten alpha on
  white) → resize with `LANCZOS` for each size → JPEG quality 85, progressive,
  no EXIF → write to `{dir}/.tmp-{uuid}.{size}.jpg` → compute etag → rename into
  place (idempotent: an identical upload lands on the same names). Decompression
  bomb guard: `Image.MAX_IMAGE_PIXELS` 40 MP → 415.
- Writer: `topics.set_photo(db, ref, etag, expected_revision)` sets
  `photo_etag`, `photo_updated_at = now()`, `revision += 1`, `_log_topic`. Only
  the writer **publishes** an etag; the files already exist when it runs. It
  deletes nothing. `delete_topic` (`topics.py:386-414`) stays a writer and does
  not touch files either.

### 12.1 Cleanup is garbage collection, not eager deletion

A scheduler tick (`services/scheduler.py`, every 10 minutes, alongside the
reminder loop) walks `QUICKR_MEDIA_DIR/topics/` and deletes:

- a file whose etag is **not** the topic's current `photo_etag` **and** whose
  mtime is older than **1 hour**;
- a directory whose topic id no longer exists in `topics`, when its newest file
  is older than 1 hour.

The 1-hour grace covers every in-flight interleaving, because files are
content-addressed and a request never deletes:

1. **A → B → A within the grace.** Upload B publishes `B`; before GC runs the
   user uploads A again: the files `A.*` already exist (same names), the writer
   publishes `A`. GC later sees `B` unreferenced and old → deleted; `A` is
   current → kept. With eager deletion the first job would have removed the
   now-current `A` (review C-S1 #9).
2. **Files written, writer crashed.** `X.*` exist, `photo_etag` unchanged. GC
   deletes `X.*` once they are an hour old; a retry of the upload within the
   hour reuses them (rename is idempotent) and the writer publishes `X`.
3. **Topic deleted while an upload is in flight.** The directory survives up to
   an hour past its newest file, then goes; the upload's writer fails on the
   missing topic (404) and leaves nothing published.

`make media-gc` runs one tick by hand (restore drills, §13). A GC run is
idempotent and safe to run concurrently with uploads.

- Cloudflare Access protects the URLs like every `/api/` path; nothing is
  mounted as `StaticFiles` (the route reads the file and streams it, so identity
  and version middleware apply uniformly).

Migration `20261201_a8b5c1d6e437_topic_photo` (down `f7a4b0c5d326`):

```sql
ALTER TABLE topics ADD COLUMN photo_etag VARCHAR(32) NULL;
ALTER TABLE topics ADD COLUMN photo_updated_at TIMESTAMPTZ NULL;
```

Wire: `TopicSummary.photo: { etag: str, updated_at: datetime } | null`
(additive, in the feed through `TopicDetail`). Limits: `max_photo_bytes`.

## 13. Hosting

- `docker-compose.yml`: a named volume `media:` mounted at `/app/media` on the
  backend; `backend/Dockerfile` creates `/app/media` and `chown`s it to uid
  10001 **before** `USER app` (`Dockerfile:27-38`), so the named volume inherits
  the ownership on first mount.
- nginx: `/api/` is already proxied (`nginx.conf:31-39`);
  `client_max_body_size 5m` stays. `proxy_read_timeout 60s` covers a 5 MB upload
  on a slow link.
- The PWA dev proxy (`vite.config.ts:29-32`) needs no change.
- **Backup and restore.** The M3b storage WP MUST update
  `docs/hosting/backend.md`: the volume name (`media`, mounted at `/app/media`),
  what to back up (the whole volume; files are immutable per etag, so a plain
  `tar` of the mount is consistent while the server runs), and the restore order
  — restore the **Postgres dump first**, then the media volume; a photo
  referenced by `topics.photo_etag` with no file returns 404 until the volume is
  back, and an orphan file is harmless. `make rotate-epoch` (`Makefile:39-44`,
  `docs/hosting/backend.md:39`) is **not affected**: photos are keyed by topic
  id + etag, neither of which changes with the change-feed epoch, so they
  survive an epoch rotation and clients' caches (§14) stay valid.

## 14. Clients

### 14.1 iOS **[ios]**

- Fetch through `APIClient` (Cloudflare Access credentials are per `baseURL`,
  `QuickrData/API/APIClient.swift:25-27`), never `AsyncImage`.
- Cache: `StoreSchema+T2M3B.swift` (its own file, one line in the registration
  list) registers `t2m3b_photo_cache`:

  ```sql
  CREATE TABLE photo_cache (
    topic_id TEXT NOT NULL, etag TEXT NOT NULL, size TEXT NOT NULL,   -- 'thumb' | 'medium'
    bytes BLOB NOT NULL, fetched_at REAL NOT NULL,
    PRIMARY KEY (topic_id, etag, size)
  )
  ```

  a local-only table in the per-server store (the store file is already in the
  App Group, `WidgetBootstrap.swift:13-46`), so widgets and the Live Activity
  read it through `ReadOnlyStores`. `full` is never cached. The app fills
  `thumb` and `medium` when a topic's `photo.etag` changes (observed from
  `observeTopics`), deletes rows whose etag is stale, and the topic tombstone
  cascade clears the table (`ServerLayer.swift:207-210` list gains `photo_cache`
  — `ServerLayer.swift` is M1's file; M3b sends that one-line change as a patch
  to its owner).

- Rendering: `TopicGlyphView` prefers the photo (`thumb`, clipped to a circle or
  rounded square) over the emoji when a cached row exists; the emoji remains the
  fallback (offline before the first fetch, widgets without a row). Size caps:
  Live Activity and widgets render **`thumb` only** (128 px, ≤ 20 KB; the widget
  memory budget and the 4 KB push payload rule out anything in attributes — the
  image is local, looked up by `topic_id` at render); the topic header uses
  `medium`.

### 14.2 PWA **[pwa]**

- `<TopicGlyph/>` renders
  `<img src="/api/v1/topics/{id}/photo?size=thumb&v={etag}">` when `photo` is
  set, emoji as fallback and while loading.
- Service worker:
  `registerRoute(({url}) => /\/api\/v1\/topics\/[^/]+\/photo$/.test(url.pathname), new CacheFirst({cacheName: 'quickr-photos', plugins: [new ExpirationPlugin({maxEntries: 300, maxAgeSeconds: 30 * 86400})]}))`
  beside the existing `NetworkFirst` API rule (`sw.ts:114-120`); the `v`
  parameter makes the URL unique per etag, so stale entries age out.
- Settings page: an "Photo" row with upload (file input `accept="image/*"`,
  `capture` omitted), a preview and Remove; the upload goes through the
  generated client's multipart call; offline → disabled with a hint.

## 15. Seams

**Provides:** `TopicTheme`, `\.topicTheme`, `.topicTheme(for:)`,
`TopicGlyphView`, `TopicAppearance`, `checkIcon`/`checkTags` (iOS); `PALETTE`,
`topicStyle`, `glyphOf`, `<TopicGlyph/>`, `topic-*` utilities (PWA);
`Appearance` on every topic, `?tag=`, reminder title prefix,
`appearance-vectors.json` (server). Consumed by M2 (tiles, active card, run
screen, LA, widgets), M4 (topic header), M1 (none).

**Consumes:** M1's `RunActivity.swift` for `attributes.appearance` (patch; until
merged the LA renders the default theme) — and M3 **re-runs the payload-size
vector** of timers2.md §8.2 with `attributes.appearance` set to its largest
value (`color: "orange"`, a 16-code-point emoji, ten 24-character tags) on the
`start` payload, adding the case `start_longest_labels_with_appearance` to
`live-activity-vectors.json` (adjudication C4). The budget is timers2.md §8's
rule on the **encoded** APNs body (A9): the server encodes, and over 4096 bytes
truncates `alert_label`, then `next_label`, then `label`, then `topic_name` to
32 characters each, re-encoding after each step; the appearance attributes
(colour name ≤ 6 bytes, emoji ≤ 64 bytes, tags ≤ 10 × 24 code points) count
against the same budget and are **never** truncated — they are bounded by §1.3,
and the vector pins all four labels at 64 four-byte code points plus the largest
appearance (untruncated); with six-byte-escape labels the body exceeds 4096
bytes and the budget's first step (`alert_label`) fits it, the appearance
untouched (asserted in `test_live_activity_vectors.py`); `Topic.swift` for the stored property
(patch); `ServerLayer.swift` for the `photo_cache` cascade line (patch, M3b);
the Alembic head `e6f3a9b4c215` (M1 merges first). Before M3 lands, consumers
use `TopicTheme.default` / `topicStyle(null)` = `{}` and nothing changes
visually.

## 16. Tests

| Where                                                                     | Runs on | What                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend/tests/test_appearance_vectors.py`                                | pytest  | generator + contrast assertion; `icons[]`, `tags[]`, `reminder_titles[]`                                                                                                                                                                                      |
| `test_api_topics.py` additions                                            | pytest  | create/PATCH semantics (omitted, null, `tags: []`, `appearance: null` → 422), dotted error paths, `?tag=`, feed re-send, revision                                                                                                                             |
| `test_identity.py` `_mutations` (+3 in M3b)                               | pytest  | upload/delete photo preconditions                                                                                                                                                                                                                             |
| `test_photos.py` (M3b)                                                    | pytest  | HEIC/PNG/JPEG accepted, EXIF rotation, sizes, etag stability, 413/415, ETag/304, immutable with `v`; DELETE twice → second is a no-op (same revision, no log row); GC: the three §12.1 interleavings with a mocked clock, a GC tick concurrent with an upload |
| `test_live_activity_vectors.py` (M3a re-run)                              | pytest  | `start_longest_labels_with_appearance` ≤ 4096 bytes                                                                                                                                                                                                           |
| `StoreMigrationTests` (QuickrDataTests)                                   | host    | `t2m3_topic_appearance` resets the cursor; a pre-existing topic is re-pulled with its appearance; `t2m3b_photo_cache` creates the table                                                                                                                       |
| `test_mcp.py`                                                             | pytest  | appearance params, bad emoji surfaces 422                                                                                                                                                                                                                     |
| `TopicThemeTests` (QuickrDesignTests)                                     | host    | catalogue vs vectors; `checkIcon`/`checkTags`; `TopicTheme(appearance:)` default                                                                                                                                                                              |
| `TopicSettingsModelTests`, `NewTopicModelTests`                           | host    | appearance in the draft and the PATCH body                                                                                                                                                                                                                    |
| `appearance.test.ts`, `TopicMetaFields.test.tsx`, `SettingsPage.test.tsx` | vitest  | palette vs vectors, validators, optimistic patch and rollback                                                                                                                                                                                                 |
| `BuilderUITests` (one case)                                               | sim     | pick a colour and emoji in New topic → the tile shows the glyph and the tinted bar                                                                                                                                                                            |
| `WidgetViewsUITests`                                                      | sim     | gallery: themed topic widget in full-colour and accented modes                                                                                                                                                                                                |
| Device check                                                              | device  | Live Activity tinted background and glyph; reminder title shows the emoji                                                                                                                                                                                     |

## 17. Open questions

- **OQ-7** icons are emoji only in phase A; SF Symbols need a PWA mapping.
  Default: emoji only; `icon.kind` leaves room. Follow-up issue to create, label
  `t2-followup`: **"SF Symbol topic icons (needs a PWA mapping)"**.
- **OQ-8** fixed twelve-name palette, no free hex. Default: fixed. A free hex
  would need a runtime contrast rule on every client. Follow-up issue to create,
  label `t2-followup`: **"free hex topic colours"**.
- **OQ-9** tags in phase A, with a home filter (`?tag=` on the PWA, a filter
  chip on iOS; §5). Default **yes**. Alternative: tags display-only in phase A,
  the filter later.
- **OQ-10** local volume + Pillow, S3 deferred. Default: local volume
  (`QUICKR_MEDIA_DIR`), one host.
- **OQ-M3-a** HEIC via `pillow-heif` (default yes, §12). If the wheel fails to
  build for 3.14 at implementation time, HEIC is refused with 415 and the
  clients transcode (iOS `UIImage` → JPEG before upload; PWA can't, so Safari
  users would see the error).
- **OQ-M3-b** a photo replaces the emoji glyph wherever a cached thumb exists
  (§14.1). Default yes; the emoji stays the reminder-title prefix.

## 18. Decisions

- D-1 Appearance is topic-level, PATCHed, revisioned; never versioned (§1).
- D-2 Per-field null clears; `tags: []` clears; `appearance: null` is an error
  (§1.1).
- D-3 Server normalises a bare pictograph by inserting VS16 instead of rejecting
  it; everything else about the emoji rule is strict (§2).
- D-3a Pure-Python `regex` for grapheme segmentation and Emoji properties;
  `unicodedata` can't (§2).
- D-4 Twelve named colours with pinned light/dark swatches and a generator-
  enforced 4.5:1 contrast (§3).
- D-5 Topic colours live in their own asset catalogue / CSS block so the
  brand-token drift test is untouched (§4).
- D-6 The iOS appearance migration resets the feed cursor (topic re-pull), as
  `v2` did (§8).
- D-7 Photos: filesystem volume, three sizes, etag in the URL for immutable
  caching, thumbs only in widgets and the Live Activity (§12–§14).
- D-8 Image decoding runs before the writer; files are content-addressed by the
  upload's SHA-256 and only ever deleted by the 10-minute GC with a 1-hour
  grace, never by a request (§12, §12.1). Photo DELETE on a topic without a
  photo is a no-op (§11).

## 19. Traceability

| User item                     | Where                                |
| ----------------------------- | ------------------------------------ |
| 9 colours                     | §1, §3, §4, §6                       |
| 9 images — emoji first        | §2, §4.1 `TopicGlyphView`, §6, §7    |
| 9 images — on widgets and LA  | §6.5, §6.6, §14.1                    |
| 9 images — photo upload later | Part II                              |
| 9 labels (tags)               | §1.3, §5, §7                         |
| 6 obvious on the home page    | §6.1, §6.2 (with active-surfaces.md) |

## 20. Review log (round 1)

| Finding                                                      | Outcome                                                                                                                                       |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| C-S1 #9 async photo cleanup can delete the current photo     | Fixed in §11, §12, §12.1 (D1): content-addressed files, no request deletes, 10-minute GC with a 1-hour grace, three interleavings written out |
| C-S2 photo DELETE mutates on every call                      | Fixed in §11 (D2): no-op when `photo_etag` is null                                                                                            |
| C-S2 existing iOS topics stay unthemed after upgrade         | Fixed in §8, D-6 (D3): the migration resets the feed cursor; planner told (I3-STORE)                                                          |
| C-S2 payload-size test omits appearance                      | Fixed in §15, §16 (C4): M3 re-runs the size vector with `attributes.appearance` set                                                           |
| K-S2 emoji validators cannot agree                           | Fixed in §2, §3.2 (D7): exact per-platform predicates, `!isASCII` on iOS, divergence cases listed and pinned                                  |
| K-S2 `t2m3b_photo_cache` registered in the M3a file          | Fixed in §14.1 (D8): `StoreSchema+T2M3B.swift`                                                                                                |
| K-S2 `ServerLayer.swift` edited by M3b without ownership     | Fixed in §14.1, §15 (D8): a patch to M1's file owner                                                                                          |
| K-S2 `builder.ts`/`serverErrors.ts`/`topics.py` shared edits | Ownership rule lives in t2-plan.md (E3); this spec's §1.2 and §7 are unchanged                                                                |

### Round 2

| Finding                                             | Outcome                                                                                                                                                                                                                                                |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| K-S2 `?tag=` casefolded (plan) vs stored spelling   | Fixed in §5 (B4): exact match on the stored spelling; uniqueness casefolded on write; the plan follows                                                                                                                                                 |
| K-S2 accessibility-id drift                         | Fixed in §7 (B3): `topic.color.<name>`, `topic.icon`, `topic.tags`, `topic.tags.add`, `topic.tags.<i>`; ids live here only                                                                                                                             |
| K-S2 M3b plan and spec disagree on the cache design | No spec change (B5): the §14 design stands (`photo_cache` BLOB table in the per-server store; SW `CacheFirst` + `ExpirationPlugin(300, 30 d)` with `v=<etag>`; `photo_etag VARCHAR(32)`; sizes `thumb\|medium\|full`; §11 headers); the plan copies it |
| K-S3 PWA topic utilities have three spellings       | No change here (B6): §4.2 is the one set; active-surfaces §6.2 and M3-TOKENS align to it                                                                                                                                                               |
| C-S2 APNs payload bytes                             | Fixed in §15 (A9): the encoded-body budget and truncation order noted; appearance attributes count against it, never truncated                                                                                                                         |
| K-S1 M3B-STORAGE still requires an eager delete     | Plan matter (C); §11–§12.1 unchanged: GC is the only deleter                                                                                                                                                                                           |
