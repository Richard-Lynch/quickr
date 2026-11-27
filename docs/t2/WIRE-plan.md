# T2-WIRE plan (T2-WIRE-I iOS, T2-WIRE-F PWA)

Branch `t2/wire` from `origin/feat/t2` once M3a (#305, final sync #310) has
merged. Worktree `/Users/richie/code/quickr-worktrees/t2-wire`. One PR into
`feat/t2`. Owner: t2-wire (reports to team-lead).

Sources: `docs/specs/t2-plan.md` §T2-WIRE-I/F and the DAG rows "M3-TOKENS →
I2-HOME…", "M4-SUMMARY → M2 idle tile"; `appearance.md` §4.3, §5, §6;
`content-display.md` §2 (delivery note, PWA tile query reduction), §5;
`active-surfaces.md` §2.2, §3.2, §6.1; evidence `M2.md` row 9 and #286, `M3a.md`
I3-RENDER notes and #226, `M4.md` C1/R9.

## What M2 and M3a already did (skipped here)

- iOS `ActiveTopicCard`: `tintSoft` background, glyph, `\.topicTheme` from
  `TopicTile` (`.topicTheme(for:)` on the card only).
- PWA `ActiveTopicCard`: `topicStyle`, `TopicGlyph`, primary `bg-topic-tint`.
- Topic header (both clients), `RunActivityAttributes.appearance` on the wire
  and in push-to-start (M3a I3-RENDER).

## Scope, the plan's four items plus the two issues assigned to it

| #   | Item                                           | iOS                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | PWA                                                                                                                                                                                                                                                                                          |
| --- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Tile accent bar, border, action block, glyph   | `QuickrUI/Components/TileView.swift` reads `\.topicTheme`: bar `tint`, due border `tint` 45 %, loud block `tint`/`onTint`, soft block `tintSoft` (label `accentStrong` on the default theme, `ink` on a colour, §4.3); `TopicGlyphView` before the title (initial only when the topic has a colour, §4.3). `App/Home/Tiles/TopicTile.swift` moves `.topicTheme(for:)` from the card to the whole tile.                                                                                                                                                                                                                                                                                                                                                                  | `TopicTile.tsx`: `style={topicStyle(t.appearance)}` on the `<article>`; bar/border/Log/single-log in `topic-*` utilities; `RunTileAction` (`RunTile.tsx`) block in `topic-*`; `<TopicGlyph/>` in the `<h2>`.                                                                                 |
| 2   | Summary line replaces `lastLine` on idle tiles | `TopicTile.swift`: the tile follows its latest entry for every topic with entries (not only quick-log ones) and renders `TopicSummaryLine(entry:questions:timer:fallback:)` with the current questions only when `entry.version == currentVersion` (else `[]`, timing part only, as `EntriesModel`); fallback = today's line. Widgets: `WidgetTopic.lastEntry`, `WidgetReader`, `WidgetViews.lastLine` (M4 C1 assigned the widget here).                                                                                                                                                                                                                                                                                                                                | `TopicTile.tsx`: `<TopicSummaryLine entry={t.last_entry} …/>`; drop `useTopicVersions` and `lastEntryOptions` per tile (`timed = Boolean(t.timer) \|\| run`, `unknown` gone, Resume offer from `t.last_entry`); `RunTileAction` takes the timer instead of `versions`.                       |
| 3   | Topic theme on active surfaces + #286 + #226   | `QuickrUI/Components/Buttons.swift` `.primary` reads `\.topicTheme` (`tint`/`onTint`; identical on `.default`) so the card primary (#286) and the run-screen hero primary themed; `App/Runs/RunScreen.swift` applies `.topicTheme(for:)` to the run panel, Running badge dot in `tint`; `Widgets/RunActivityWidget.swift` reads `attributes.appearance` (Lock Screen `tintSoft` background, primary `tint`, glyph before the name); `WidgetViews.swift` accent bar + primary chip in `tint` in full-colour, glyph before the name, nothing filled in accented modes; due-list rows prefix the glyph (§6.8). #226: `RunActivitySnapshot.topicAppearances`, filled with `topicNames`, passed to `RunActivityContent.attributes(..., appearance:)` in `RunActivityCenter`. | `RunControls.tsx` hero primary and `RunPanel.tsx` (#286) use `bg-topic-tint text-topic-on-tint` under `topicStyle(appearance)` on the panel; Running badge dot `bg-topic-tint`; `RunningBar.tsx` per-run `topicStyle`, wash `bg-topic-tint-soft`, button `bg-topic-tint text-topic-on-tint`. |
| 4   | Home tag filter + tile tag chips (§5)          | `QuickrCore/Home/TopicListing.swift` `filter(tags:)`/`matches` with an exact tag; `QuickrData/Home/HomeModel.swift` `tagFilter: String?` (in `hasNonDefaultFilter`, reset with the others); `App/Home/HomeView.swift` filter panel "Tag" chip row (every tag on the listed topics, sorted, selected one highlighted, ✕ clears). Tile footer: up to three neutral `QuickrBadge` chips, then "+N" (display only; the meta passes taps through).                                                                                                                                                                                                                                                                                                                           | `TopicsPage.tsx`: `tag` URL param → `listTopicsInfiniteOptions({ query: { tag } })`; the filter panel's "Tag" row shows the active tag with ✕; tile chips (≤ 3, then "+N") above the link overlay set `?tag=`.                                                                               |

Default theme rule (§4.3): a topic without a colour looks exactly as on
`feat/t2` before this PR. Every themed change is checked against that with the
"before" screenshots.

## Tests (each new one fails without the wiring; two mutation-checked per platform)

iOS host (`swift test --filter`, via `heavy.sh` when wide):

- `TopicListingTests` / `HomeModelTests`: tag filter (match, no match, exact
  spelling, cleared, `hasNonDefaultFilter`), tag list for the panel.
- `LiveActivityReconcileTests`: a themed topic's local start requests attributes
  with its appearance (#226); unthemed → nil.
- `QuickrDesignTests`: primary button colours under `.default` equal the accent
  (no visual change), under a palette theme equal `tint`/`onTint`; tile chip
  overflow helper ("+N").
- `WidgetTopic`/`WidgetReader` tests: `lastEntry` filled; widget last line uses
  the summary.

iOS sim (own clone, `-only-testing`, `uptime` recorded):

- `TileUITests` (new: themed tile shows the glyph, the summary line and tag
  chips; existing cases unchanged), `HomeTests` (new: tag chip filters the
  list), `WidgetViewsUITests` (new themed gallery case, full-colour + accented),
  `RunUITests` (themed run screen screenshot), Live Activity mock from the
  widget gallery.
- At the end: one full UI plan and one e2e run
  (`heavy.sh ios/scripts/uitest-e2e.sh <udid> -collect-test-diagnostics never`),
  xcresult JSON exported to `docs/t2/evidence/WIRE/xcresults/`.

PWA (`heavy.sh make check-frontend`; single files directly):

- `TopicTile.test.tsx`: no per-tile entries or versions query (fetch spy);
  summary line from `last_entry`; tint style on the article; glyph; chips ≤ 3 +
  "+N"; Resume from `last_entry`.
- `TopicsPage.test.tsx`: `?tag=` sent, chip sets it, ✕ clears it.
- `RunControls`/`RunPanel`/`RunningBar` tests: primary carries the topic tint
  classes and the `--topic-tint` variable for a coloured topic, none for
  default.

## Screenshots (`docs/t2/evidence/WIRE/`, PNG, small)

Before (`feat/t2` at the branch point) and after, light, dark and XXXL: home
tile (themed + default), Active now card, run screen, Live Activity mock (widget
gallery). Widgets themed full-colour and accented. PWA mobile width, light and
dark: home tiles with chips and tag filter active, active card, run panel,
running bar, via an own headless Playwright script (system Chrome, fresh
profile, localhost, `/api/v1/` mocked from fixtures). No browser MCPs.

## Device-only (to `docs/t2/device-checklist.md` text, via team-lead)

Live Activity tinted background and glyph on a real Lock Screen and Dynamic
Island; widget tinted/accented modes on the Home Screen.

## Out of scope (follow-ups if found)

- #259 `ToastView`, #297–#299, #169 optimistic `last_entry`, #204: not T2-WIRE.
- Re-tinting other accent chrome (step list current row, home section dots).
