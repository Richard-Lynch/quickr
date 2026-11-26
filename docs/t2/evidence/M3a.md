# M3a evidence · topic appearance, phase A

**Status: DRAFT, pre-gate** (2026-11-26). Branch `t2/m3a` at
`9d671383ce7b4e593aa502533c5755c1ad3c476d` (`git rev-parse HEAD` in the
milestone worktree, before this file was committed). Plan:
[M3a-plan.md](../M3a-plan.md). Spec: [appearance.md](../../specs/appearance.md)
Part I. SHAs are copied from `git log --oneline origin/t2/m3a` and `gh pr view`.
Counts are quoted from the PR descriptions and from the committed xcresult JSON
under [`M3a/xcresults/`](M3a/xcresults/). Lines marked **PENDING** are gate work
still to run. Lines marked **GAP** are evidence that is missing or weaker than
the rules ask for.

## 1. WPs

M3-TOKENS (#131) and I3-RENDER's Live Activity half (#227) were merged with
`--no-ff`, because their branches are shared with M2 and M1. Every other WP was
squash-merged, so it has one commit on `t2/m3a`.

| WP                          | PR                                                       | Commit on `t2/m3a` | Codex review file(s)                                                                                                                                                                                                                                  | Cleanup                                                                           |
| --------------------------- | -------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| M3-TOKENS                   | [#131](https://github.com/Richard-Lynch/quickr/pull/131) | `45775247` (merge) | [M3a-TOKENS-codex.md](../reviews/M3a-TOKENS-codex.md), [-r2](../reviews/M3a-TOKENS-codex-r2.md)                                                                                                                                                       | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/131#issuecomment-7177240960) |
| M3-DB                       | [#201](https://github.com/Richard-Lynch/quickr/pull/201) | `737a25ab`         | [M3a-db-codex.md](../reviews/M3a-db-codex.md), [-round2](../reviews/M3a-db-codex-round2.md)                                                                                                                                                           | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/201#issuecomment-7182929603) |
| I3-STORE                    | [#211](https://github.com/Richard-Lynch/quickr/pull/211) | `227fcfd9`         | [M3a-i3store-codex.md](../reviews/M3a-i3store-codex.md)                                                                                                                                                                                               | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/211#issuecomment-7184131908) |
| F3-EDIT                     | [#215](https://github.com/Richard-Lynch/quickr/pull/215) | `2fa9a265`         | [M3a-f3edit-codex.md](../reviews/M3a-f3edit-codex.md), [-r2](../reviews/M3a-f3edit-codex-r2.md), [-full](../reviews/M3a-f3edit-codex-full.md), [-full-r2](../reviews/M3a-f3edit-codex-full-r2.md), [-full-r3](../reviews/M3a-f3edit-codex-full-r3.md) | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/215#issuecomment-7184276363) |
| F3-RENDER                   | [#216](https://github.com/Richard-Lynch/quickr/pull/216) | `c0dad79f`         | [M3a-f3render-codex.md](../reviews/M3a-f3render-codex.md), [-p2](../reviews/M3a-f3render-codex-p2.md), [-p2r2](../reviews/M3a-f3render-codex-p2r2.md), [-full](../reviews/M3a-f3render-codex-full.md)                                                 | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/216#issuecomment-7184143157) |
| F3-EDIT-REBASE (extra WP)   | [#220](https://github.com/Richard-Lynch/quickr/pull/220) | `0e72eb5d`         | [M3a-f3edit-rebase-codex.md](../reviews/M3a-f3edit-rebase-codex.md), [-r2](../reviews/M3a-f3edit-rebase-codex-r2.md)                                                                                                                                  | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/220#issuecomment-7184276615) |
| I3-RENDER (header)          | [#221](https://github.com/Richard-Lynch/quickr/pull/221) | `9b10cba8`         | [M3a-i3render-codex.md](../reviews/M3a-i3render-codex.md) (four rounds in one file)                                                                                                                                                                   | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/221#issuecomment-7185133862) |
| I3-RENDER (LA attributes)   | [#227](https://github.com/Richard-Lynch/quickr/pull/227) | `3d4592b3` (merge) | [M3a-i3render-la-codex.md](../reviews/M3a-i3render-la-codex.md) (three rounds)                                                                                                                                                                        | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/227#issuecomment-7187933867) |
| I3-EDIT                     | [#238](https://github.com/Richard-Lynch/quickr/pull/238) | `d1b29181`         | [M3a-i3edit-codex.md](../reviews/M3a-i3edit-codex.md) (every round in one file)                                                                                                                                                                       | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/238#issuecomment-7190037618) |
| M3-UITEST                   | [#251](https://github.com/Richard-Lynch/quickr/pull/251) | `ac266a9f`         | [M3a-uitest-codex.md](../reviews/M3a-uitest-codex.md), [-r2](../reviews/M3a-uitest-codex-r2.md), [-r3](../reviews/M3a-uitest-codex-r3.md)                                                                                                             | [CLEAN](https://github.com/Richard-Lynch/quickr/pull/251#issuecomment-7193264091) |
| Review fixes, iOS           | [#268](https://github.com/Richard-Lynch/quickr/pull/268) | **PENDING** (open) | `M3a-rvfix-ios-codex.md` (on `t2/m3a-rvfix-ios`, three rounds)                                                                                                                                                                                        | **PENDING**                                                                       |
| Review fixes, PWA + backend | [#270](https://github.com/Richard-Lynch/quickr/pull/270) | **PENDING** (open) | `M3a-rvfix-fe-codex.md`, `-r2` … `-r5` (on `t2/m3a-rvfix-fe`)                                                                                                                                                                                         | **PENDING**                                                                       |
| M3-REVIEW                   | milestone PR, not opened yet                             | —                  | [M3a-milestone-codex.md](../reviews/M3a-milestone-codex.md), [M3a-milestone-claude.md](../reviews/M3a-milestone-claude.md)                                                                                                                            | **PENDING** (milestone `--machine` run, §7)                                       |

Other commits on `t2/m3a`:

- `3b836000`: the plan check before the first WP.
- `028d1546`, `f5a9ea1e`: spec clarifications (§3.1).
- `a130063e`: merge of `t2/m1-db` (shared WP branch, M1-DB).
- `4c7067d6`, `53179734`: `origin/feat/t2` syncs (main syncs #187, #249, #252).
- `a9cb9d8b`: I3-EDIT xcresult summaries (durable test evidence).
- `9d671383`: the milestone Codex review.

## 2. Acceptance → proof

CI links are the three workflows on the PR head: CI (backend, frontend, docker),
iOS (swift test, build + Unit plan, ios gate) and Compat (compat gate, old
clients, old requests, api level, openapi breaking).

### M3-TOKENS · #131 · `45775247`

| Acceptance                                         | Proof                                                                                                                                                                                                                                               |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| nil appearance gives the accent theme and no glyph | `TopicThemeTests/nilAppearanceIsTheDefaultTheme`, `colourlessAppearanceWithAnIconKeepsTheAccentTokens`; `appearance.test.ts › topicStyle › is empty for null, undefined and a colourless appearance`                                                |
| each of the 12 colours resolves in light and dark  | `TopicThemeTests/everyColourResolvesInLightAndDark` (36 colour sets against the §3.1 table); `appearance.test.ts › topicColors.css › carries PALETTE as --topic-<name>-tint\|soft\|on, light and dark`, `has one [data-topic-color] block per name` |
| the glyph falls back to the topic's initial        | `TopicThemeTests/glyphFallsBackToTheInitial`; `appearance.test.ts › glyphOf › falls back to the first grapheme…`; `TopicGlyph.test.tsx`                                                                                                             |
| PWA: the CSS variables emitted                     | `appearance.test.ts › topicStyle › sets the three variables from the colour…`, `… › is what the topic-* utilities read, defaulting to the accent`                                                                                                   |

- Counts: `swift test --filter 'TopicThemeTests|TokenDriftTests'` gave
  `✔ Test run with 7 tests in 2 suites passed`. `make ios-core-test` gave
  `1063 tests in 116 suites passed`, plus 30 and 302. Vitest on the two files
  gave `Tests 12 passed (12)`. `make check-frontend` gave
  `Tests 1364 passed (1364)`.
- CI, all green at `eb9607b3`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45710075840) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45710076006) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45710075831)
- **GAP (accepted in review):** on the PWA the light and dark values are
  asserted on the CSS source, not as computed colours. jsdom compiles neither
  Tailwind nor `prefers-color-scheme`. The built CSS was inspected by hand
  (Codex round 1, Low, stands).

### M3-DB · #201 · `737a25ab`

| Acceptance                                                                                    | Proof                                                                                                                                                                                                                                     |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Migration round trip                                                                          | `alembic downgrade -1` (`e6f3a9b4c215`, 0 columns) / `alembic upgrade head` (`f7a4b0c5d326 (head)`, `color`/`icon` `VARCHAR(16)`, `tags` `jsonb NOT NULL '[]'`), output in the PR; `alembic check`: `No new upgrade operations detected.` |
| 422 paths `appearance.tags.3`, `appearance.icon.value`, `appearance.color`, `appearance.tags` | `test_api_topics.py::test_appearance_errors_have_dotted_paths` (11 cases, PATCH and create)                                                                                                                                               |
| `appearance: null` → 422, `tags: []` accepted                                                 | the same test (the `None` case); `test_appearance_patch_semantics`                                                                                                                                                                        |
| A PATCH of appearance alone bumps `revision` and emits a `topic` feed item                    | `test_appearance_patch_bumps_revision_and_resends_the_topic` (exactly one topic item on `/changes`; a stale `expected_revision` gives 409)                                                                                                |
| `?tag=` matches the stored spelling exactly                                                   | `test_list_topics_tag_filter_matches_the_stored_spelling`; MCP `test_topic_appearance_params`; fixture `listTopics.tag`                                                                                                                   |
| The reminder title carries the emoji and stays ≤ 120 chars                                    | `test_push.py::test_reminder_title_carries_the_emoji_on_both_channels` (Web Push and `apns.render`); `reminder_titles[]` (8 cases); APNs vector `timed_with_icon`                                                                         |
| `DueReminderVectorTests` and `NotificationVectorTests` pass on iOS                            | host `make ios-core-test`: `1064 tests in 116 suites passed`, plus 307, 234, 30 and 3                                                                                                                                                     |
| Both clients' palette tests read the vector file                                              | `appearance.test.ts` "equals the palette of appearance-vectors.json"; `TopicThemeTests.thePaletteIsTheVectorsTwelveNames`, `everyColourResolvesInLightAndDark`. Mutation check: one changed hex fails the vitest and pytest drift tests   |
| D7: exact server emoji predicate, `icons[]` accept and reject cases                           | `appearance-vectors.json` `icons[]` (27 cases), `tags[]` (24); `test_appearance_vectors.py`                                                                                                                                               |
| MCP params                                                                                    | `test_mcp.py::test_topic_appearance_params`, `test_topic_appearance_errors_are_described`, `test_instructions_name_the_colours`                                                                                                           |

- Counts: `make check` gave backend `1246 passed`, frontend
  `Tests 1385 passed (1385)`. `test_api_topics.py` gave `40 passed`,
  `test_mcp.py` `24 passed`, and the push and vector files `67 passed`.
- CI, all green at `d04db877`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45755674780) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45755674782) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45755674764)
- Deviation: the plan named new cases in `notification-vectors.json`. That file
  has no title field, so the emoji title is pinned by `timed_with_icon` and
  `reminder_titles[]` instead (Codex round 1, Low, stands).

### I3-STORE · #211 · `227fcfd9`

| Acceptance                                                                                     | Proof                                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `api/getTopic.json` decodes with and without appearance                                        | `TopicDTOTests.getTopicDecodesWithItsAppearance`, `getTopicDecodesWithoutAnAppearance`; a missing key fails: `aMissingAppearanceKeyFailsToDecode`, `FixtureCoverageTests.responseMissingAnyKeyFailsToDecode` (the M3-DB exemption removed)                                                                                                   |
| `MappingTests` carry the fields to `ViewTopic`                                                 | `MappingTests.feedTopicsCarryTheirAppearanceToTheView`                                                                                                                                                                                                                                                                                       |
| After the migration the next sync re-pulls topics (upgrade test, unchanged pre-existing topic) | `AppearanceUpgradeTests.aStoreSyncedBeforeT2M3RebuildsAndShowsTheThemes` (unthemed before, themed after one sync, `layer_gen + 1`). Mutation check: removing the `rebuilding` statement fails it with 5 issues. Also `onAStoreMidRebuildStagingRestartsAndTheTargetStays`, `aStoreWithNoEpochDoesNotRebuild`, `bothLayersKeepTheSameColumns` |
| The golden validates in pytest                                                                 | `test_request_goldens.py::test_golden_replays[updateTopic.appearance]`, `[createTopic.appearance]`                                                                                                                                                                                                                                           |
| Writes (`TopicWrites.updateAppearance`, `expected_revision`)                                   | `TopicWritesTests.updateAppearanceSendsOnePatchAndAppliesTheTheme`, `aStaleAppearanceSaveIsRefusedAndNothingChanges`, `createSendsTheAppearanceAndStoresIt`; `TopicDTOTests.thePatchIsThreeStatePerField`, `theDetailsSaveCarriesTheAppearance`                                                                                              |
| `DueReminder` local-fallback title (§6.7)                                                      | `DueReminderVectorTests.theTitleIsComposedAsTheServerDoes` over the 8 `reminder_titles[]` cases                                                                                                                                                                                                                                              |
| E4 `StoreMigrationOrderTests`                                                                  | Not due when #211 merged (no `t2m1_*` migration anywhere then). It is now a gate item: §3.5, **PENDING**                                                                                                                                                                                                                                     |

- Counts:
  `swift test --filter 'TopicDTOTests|MappingTests|…|FixtureCoverageTests'` gave
  `✔ Test run with 108 tests in 11 suites passed`. `make ios-core-test` gave
  `1085 tests in 118 suites passed`, plus 307, 234, 30 and 3.
  `test_request_goldens.py` gave `78 passed`.
- UI run (Builder, Topic, Settings, TopicLifecycle UI classes): **23 tests, 21
  passed, 2 failed** (the 2 are flake #89). See §3.6.
- CI, all green at `e05970ff`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45760335517) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45760335502) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45760335623)

### I3-EDIT · #238 · `d1b29181`

| Acceptance                                                         | Proof                                                                                                                                                                                                    |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A duplicate tag (casefolded) is refused                            | `NewTopicModelTests.aDuplicateTagIsRefusedCasefolded`, `TopicSettingsModelTests.aDuplicateOrEleventhTagIsRefusedBeforeSaving`; vectors `casefold_duplicate`, `casefold_full`, `casefold_capital_sharp_s` |
| An 11th tag is refused                                             | `NewTopicModelTests.anEleventhTagIsRefused`, `anEleventhTagTypedButNotAddedIsTheAddFieldsError`; vector `eleventh_tag`                                                                                   |
| Clearing the icon sends `icon: null`                               | `TopicSettingsModelTests.clearingTheIconSendsIconNullWithTheRevision`; I3-STORE's `TopicDTOTests` encode it as `null`                                                                                    |
| Save goes through `TopicWrites.updateAppearance` with the revision | `detailsAndAppearanceGoInOnePatch` (`expectedRevision: 3`)                                                                                                                                               |
| D7: iOS `checkIcon` and the vectors                                | `TopicThemeTests.checkIconMatchesTheVectors` (27 `icons[]`, including `too_long_after_vs16`, `lone_regional_indicator`, `lone_skin_tone`, `digit_vs16`), `checkTagsMatchesTheVectors` (24 `tags[]`)      |

- Counts:
  `swift test --filter 'NewTopicModelTests|TopicSettingsModelTests|TopicThemeTests|BuilderEditingTests|BuilderBindingsTests'`
  gave `✔ Test run with 92 tests in 5 suites passed`. `make ios-core-test` at
  `b5c7ae06` gave 3 / 284 / 1085 / 30 / 307, all passed. Mutation checks:
  removing `!isASCII` fails 2 vector cases.
- UI runs: §3.6 (four runs, JSON committed).
- CI, all green at `ce6d4a1e`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45791660758) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45791660692) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45791660700)

### I3-RENDER · #221 (header) `9b10cba8` and #227 (LA attributes) `3d4592b3`

| Acceptance                                                        | Proof                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The header shows the default when appearance is nil               | `TopicHeaderTests.noAppearanceShowsNoHeader` (nil, `.empty`, the decoded §1.1 defaults), `topicWithoutAppearanceShowsNoHeader`; also `storedThemedTopicShowsItsHeader`, `fullAppearanceShowsGlyphNameChipsAndRule`, `colourWithoutEmojiFallsBackToTheInitial`, `noColourDrawsNoAccentChrome`                            |
| `LiveActivityVectorTests` round-trips the new case                | `LiveActivityVectorTests.startAttributesRoundTripTheAppearance`, `startsCarryTheAttributes` (#227)                                                                                                                                                                                                                      |
| C4: the budget vector re-run with `attributes.appearance`, ≤ 4096 | `start_longest_labels_with_appearance` (3352 B, untruncated); `test_budget_largest_body_with_the_largest_appearance_fits_after_the_first_step` (4109 B raw → 3914 B after `fit` drops `alert_label`); `test_budget_bound_holds_with_the_largest_appearance`; `test_budget_vectors_rerun_with_the_largest_appearance[…]` |
| The start push carries the topic's appearance                     | `test_push_to_start_carries_the_topics_appearance`, `test_push_to_start_of_an_unthemed_topic_sends_the_default_appearance`                                                                                                                                                                                              |

- Counts, #221: `swift test --filter 'TopicHeaderTests|TopicThemeTests'` gave
  `Test run with 15 tests in 2 suites passed`.
  `swift test --filter QuickrDesignTests` gave `242 tests in 29 suites passed`.
  `make ios-core-test` gave 3, 242, 1085, 30 and 307, all passed.
- Counts, #227: `swift test --filter LiveActivityVectorTests` gave
  `11 tests in 1 suite passed`. `tests/test_live_activity_vectors.py` gave
  `22 passed`. `make check` gave `1360 passed`, vitest `1538 passed`.
  `make ios-core-test` gave 3/1, 242/29, 1092/119, 30/11, 328/44.
- UI runs (#221): §3.6.
- CI, #221, all green at `3866ab26`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45767578527) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45767578453) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45767578487)
- CI, #227, at `b0ec2ed4`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45776133192) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45776133618) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45776133023).
  The first `ios gate` attempt was red only because the Unit plan step hit its
  15-minute cap after `Test Succeeded` (#230). The re-run is green (job
  `139776412454`).
- Not in scope here: drawing the tint in `RunActivityWidget` and the widgets is
  T2-WIRE-I. The phone's local LA start passes no appearance (#226).

### F3-EDIT · #215 · `2fa9a265`

| Acceptance                                                                | Proof                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A PATCH sends only the changed appearance fields with `expected_revision` | `TopicMetaFields.test.tsx` › "sends only the changed appearance fields, with expected_revision", "clears the emoji with icon: null", "keeps a dirty form's base: only its own edits, with the revision it started from"; `builder.test.ts` › appearanceChanges |
| Server 422 paths map to the right field                                   | `TopicMetaFields.test.tsx` › "puts the server’s 422 paths on the matching field" (`appearance.tags.1`, `appearance.icon.value`); `builder.test.ts` › builderFieldFor appearance paths                                                                          |
| The tile cache updates optimistically                                     | `mutations.test.ts` › "patches the tile and the detail before the server answers, then takes its reply", "restores the previous appearance when the PATCH fails"                                                                                               |
| D7/E3: the PWA predicate agrees with the vectors                          | `appearance.test.ts` › checkIcon over all 27 `icons[]` (including `too_long_after_vs16`), checkTags over all 24 `tags[]`                                                                                                                                       |

- Counts: `make check-frontend` gave `Tests 1473 passed (1473)`. `make check`
  gave backend `1246 passed`, frontend `1470 passed`. Vitest per file:
  `TopicMetaFields.test.tsx` 17, `builder.test.ts` 32, `mutations.test.ts` 4,
  `appearance.test.ts` 66.
- Screenshots: `f3edit-new-390-light.png`, `f3edit-new-390-dark.png` (§4).
- CI, all green at `75d31630`
  ([comment](https://github.com/Richard-Lynch/quickr/pull/215#issuecomment-7184040933)):
  [run 45765163377](https://github.com/Richard-Lynch/quickr/actions/runs/45765163377)
  ·
  [run 45765163401](https://github.com/Richard-Lynch/quickr/actions/runs/45765163401)
  ·
  [run 45765163429](https://github.com/Richard-Lynch/quickr/actions/runs/45765163429)
- **GAP:** the screenshots show the new-topic form only. No screenshot shows the
  Settings `MetaForm` Appearance card. It is the same `TopicMetaFields`
  component.

### F3-EDIT-REBASE · #220 · `0e72eb5d` (orchestrator-ordered follow-up, §3.4)

| Acceptance (from the ruling)                               | Proof (`TopicMetaFields.test.tsx`)                                                          |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| A schedule save, then a details save, gives no 409         | the schedule-then-details tests (`expected_revision: 8`, the colour edit kept), both orders |
| A change elsewhere to other fields rebases the form        | archive fetched in; another device's rename fetched in, the colour edit stays               |
| A change elsewhere to the same field still gives 409       | the colour conflict test (sent with the old revision 7)                                     |
| An unseen change that left the edits alone is retried once | the retry-on-revision-8 test; an unseen same-field change shows the conflict                |

- Counts: `make check-frontend` gave `Tests 1486 passed (1486)`. The test file
  gave `Tests 24 passed (24)`. Mutation checks: removing the field-level rebase
  fails 3 tests, removing the retry fails 1.
- CI, all green at `d2aa6f4b`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45766682178) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45766682314) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45766682254)

### F3-RENDER · #216 · `c0dad79f`

| Acceptance                           | Proof (`TopicLayout.test.tsx`)                                                                                                                                                                                 |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Default rendering with no appearance | `TopicTabs header: no appearance › renders as on main for the empty appearance` (no glyph, no tags, no `style`, `after:bg-accent`)                                                                             |
| No colour, emoji and/or tags (§4.3)  | `no colour › shows the emoji and neutral chips under the version tag, with no tint`, `shows chips but no glyph (no initial circle) for tags alone`, `shows the emoji with no chips row when there are no tags` |
| A colour                             | `a colour › tints the header and the active tab, and shows the emoji`, `shows the initial on the tint circle when there is no emoji`                                                                           |
| Mobile-width screenshot              | `frender-header-390-light.png`, `frender-header-390-dark.png` (§4)                                                                                                                                             |

- Counts: `TopicLayout.test.tsx` gave `Tests 6 passed (6)`.
  `make check-frontend` gave `Tests 1479 passed (1479)`.
- CI, all green at `2c3a0424`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45765823685) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45765823634) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45765823652)

### M3-UITEST · #251 · `ac266a9f`

| Acceptance                                            | Proof                                                                                                                                                                                                                       |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `testNewTopicWithAppearance` passes once on the clone | run r3 on the head code: 1 test, 1 passed ([`m3a-uitest-UI-own-r3-20261126-125722`](M3a/xcresults/m3a-uitest-UI-own-r3-20261126-125722.summary.json)). r1 and r2 passed on earlier code; each re-run followed a code change |
| Screenshots in `docs/t2/evidence/M3a/`                | `appearance-{editor,header}-{teal,orange,violet}-{light,dark}.png`, `appearance-{editor,header}-teal-xxxl.png` (§4)                                                                                                         |
| GIF/MP4 of the flow                                   | `appearance-flow.mp4`                                                                                                                                                                                                       |
| Clone shut down after each run                        | each run ends in `xcrun simctl shutdown BB9679F1-2E79-4697-A8C4-243B8765AE24` (stated in the PR)                                                                                                                            |

- What the test asserts: the colour is selected, the emoji field value, the
  chips `topic.tags.0/1`, the row summary `Teal · 🏃 · 2 tags`, the header name
  and chips, and the settings summary read back from the stored topic. The
  rule's colour and the presence of a drawn glyph are read from screenshot
  pixels (teal light tint `#19786f` ±24).
- **GAP (justified, #250):** the test can't tell _which_ emoji is drawn. The
  glyph is `accessibilityHidden`. The stored value is proven by the settings
  summary, and `TopicHeaderTests` checks `glyph == .emoji(…)` on the host.
- Not in scope: the tile's glyph and tint bar (T2-WIRE-I), and the themed widget
  gallery case (M2 / T2-WIRE-I).
- CI, all green at `bee5bb74`:
  [CI](https://github.com/Richard-Lynch/quickr/actions/runs/45824965531) ·
  [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45824965331) ·
  [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45824965329).
  The first run failed to compile `BuilderUITests+T2M3.swift:55` in reasonable
  time
  ([job](https://github.com/Richard-Lynch/quickr/actions/runs/45821599012/job/139915025706)).
  It was fixed by rewriting the loops.

### M3-REVIEW · milestone PR

| Acceptance                                                             | Status                                                                                                                                                                                                           |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No open finding inside scope                                           | **PENDING:** every finding is addressed in #268 / #270 (§6), and both are still open                                                                                                                             |
| Every other finding has a `t2-followup` issue, including OQ-7 and OQ-8 | #269 (Codex round 4 on #270); OQ-7 → [#256](https://github.com/Richard-Lynch/quickr/issues/256), OQ-8 → [#257](https://github.com/Richard-Lynch/quickr/issues/257). **PENDING:** link them from the milestone PR |
| `docs/t2/evidence/M3a.md` is complete                                  | this file; **PENDING** sections are marked                                                                                                                                                                       |
| The milestone PR is ready with the five checks green                   | **PENDING**                                                                                                                                                                                                      |
| LA tint and reminder emoji on the device checklist                     | [device-checklist.md › M3a · topic appearance](../device-checklist.md#m3a--topic-appearance)                                                                                                                     |

## 3. Orchestrator rulings and gate items

### 3.1 Spec clarifications (`028d1546`, `f5a9ea1e`)

- `028d1546` "appearance.md clarifications found by M3a WPs (lead-approved)":
  - §2: the 16-code-point limit applies after the VS16 insert;
  - §2: a lone regional indicator and a lone skin-tone modifier are refused on
    every platform (the PWA row was rewritten);
  - §3.2: `icons[]` gains `lone_regional_indicator` and `lone_skin_tone`;
  - §4.2: the shipped M3-TOKENS CSS shape;
  - §4.3: what a topic with an emoji or tags but no colour shows.
- Proof: the three validators agree on every `icons[]` and `tags[]` case.
  - Server: `test_appearance_vectors.py`.
  - PWA: `appearance.test.ts`, 27 + 24 cases.
  - iOS: `TopicThemeTests.checkIconMatchesTheVectors`,
    `checkTagsMatchesTheVectors`.
  - `too_long_after_vs16` was the one case where the clients disagreed at M3-DB
    time. F3-EDIT and I3-EDIT fixed it, and both PRs list it among the passing
    cases.
  - §4.3 is proven by F3-RENDER's "no colour" tests and I3-RENDER's
    `noColourDrawsNoAccentChrome`.
- `f5a9ea1e`: §15, the LA budget worst case is the six-byte-escape labels.
  Proof:
  `test_budget_largest_body_with_the_largest_appearance_fits_after_the_first_step`
  and `test_budget_bound_holds_with_the_largest_appearance` (#227).

### 3.2 A single PATCH

- The ruling (orchestrator-accepted, I3-STORE brief): on iOS the appearance goes
  in the same `PATCH /topics/{id}` as the details, through
  `TopicDetailsChange.appearance` → `TopicUpdateDTO.appearance`, with
  `expected_revision`. No second PATCH.
- Proof:
  - `TopicWritesTests.updateAppearanceSendsOnePatchAndAppliesTheTheme` (one
    request) and `TopicDTOTests.theDetailsSaveCarriesTheAppearance` (#211);
  - `TopicSettingsModelTests.detailsAndAppearanceGoInOnePatch` (#238).
- On the PWA, `MetaForm` already sends one meta PATCH, and #215 adds the
  appearance diff to it.

### 3.3 The field-level 409 rule

- The ruling: one user, so a client's own saves never produce a conflict banner.
  - A newer topic rebases the form unless it changed a field being edited.
  - A same-field change elsewhere is a real conflict.
  - An unseen, unrelated bump is re-sent on the fresh revision.
- PWA: #220 (§2, F3-EDIT-REBASE).
- iOS: #238 implements the same rule.
  - Own saves: `aScheduleSaveThenADetailsAndAppearanceSaveIsNoConflict`,
    `detailsThenAppearanceSavesAreNoConflict`,
    `anArchiveThenAnAppearanceSaveRebasesOnTheStoresCopy`.
  - Field-level conflicts: `aChangeFromElsewhereToTheSameFieldConflicts`,
    `aChangeFromElsewhereToAnotherFieldResendsOnce`,
    `aSyncThatChangedTheEditedFieldKeepsTheConflict`,
    `aNameChangedElsewhereConflicts`.
- The milestone review refined it into the lead's conflict flow (§6): refetch by
  id; at most 3 sends, then a distinct "busy" error; on a real conflict, name
  the field and move the base; same value elsewhere is a resend.
  - **PENDING #268 (iOS):** `aConflictThenASecondSaveSucceeds`,
    `twoUnrelatedWritesInARowStillSave`, `threeContentionsSayBusy`,
    `latestAppliesTheServersTopic`. CI green at `19045bc2`
    ([CI](https://github.com/Richard-Lynch/quickr/actions/runs/45852419139) ·
    [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45852419430) ·
    [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45852419447)).
  - **PENDING #270 (PWA):**
    `shows the conflict naming the field, then a second save overwrites it`,
    `re-sends by id over a slug changed elsewhere while only the colour was edited`,
    `keeps re-sending over two unrelated writes in a row`,
    `gives up after three attempts on a busy topic, with the busy error`.
    - CI green at `035cd8ab`
      ([CI](https://github.com/Richard-Lynch/quickr/actions/runs/45852963756) ·
      [iOS](https://github.com/Richard-Lynch/quickr/actions/runs/45852963710) ·
      [Compat](https://github.com/Richard-Lynch/quickr/actions/runs/45852963669)).
    - The branch has since moved to `7f9208b1` (`f72a1adf`: iOS wording,
      conflicts judged on the sent fields, same value is no conflict; Codex r5:
      no findings). Its CI was still running at the time of writing.
- Residual: #219 (an iOS save tapped right after a sent archive can 409 before
  the store's copy arrives; outbox work).

### 3.4 F3-EDIT-REBASE

The orchestrator made it a mandatory follow-up WP and a milestone gate item
after F3-EDIT. It merged as #220 (`0e72eb5d`); proof in §2. The gate item is
met. I3-EDIT carried the same fix on iOS (§3.3).

### 3.5 Store migration order at the `feat/t2` merge: **PENDING**

- Approved gate item. M1 (#267) merges to `feat/t2` first. At M3a's merge to
  `feat/t2`, the merger:
  - registers `t2m1` before `t2m3` in `StoreSchema.swift`'s `migrations`;
  - adds `t2m1ServerLayerTables` to the `t2m3` stage clear;
  - adds `StoreMigrationOrderTests` (plan E4), plus a test that upgrading a
    store with M1's tables re-pulls cleanly.
- State now:
  - `t2/m3a` has one `t2m3` registration line (`154779a9`, kept on the milestone
    branch by the lead's decision, #211).
  - `StoreSchema+T2M1.swift` exists on `origin/t2/m1` and not yet on
    `origin/feat/t2`.
- Proof to record here: the commit SHA and the test names and counts.
  **PENDING**.

### 3.6 UI tests are not in CI: every local UI run

The CI Unit plan runs no UI tests, so each UI-touching WP ran the affected UI
classes on its own sim clone. JSON paths are relative to
[`M3a/xcresults/`](M3a/xcresults/).

| WP / run                             | Classes                                                | Tests | Passed | Failed   | Skipped | Evidence                                                                                                                                        | uptime start → end |
| ------------------------------------ | ------------------------------------------------------ | ----- | ------ | -------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ |
| I3-STORE (#211)                      | Builder, Topic, Settings, TopicLifecycle               | 23    | 21     | 2 (#89)  | 0       | **GAP:** `ios/build/results/I3STORE-builder-UI-20261126-0535.xcresult`, deleted by cleanup before the durable-evidence rule; counts from the PR | not recorded       |
| I3-RENDER (#221) run 1               | Topic, TopicLifecycle                                  | 10    | 9      | 1 (#225) | 0       | **GAP:** `UI-i3render-20261126-055501/UI.xcresult`, deleted; counts from the PR                                                                 | about 198 (stated) |
| I3-RENDER (#221) deciding run        | Topic                                                  | 9     | 9      | 0        | 0       | **GAP:** `UI-i3render-decide-20261126-070036/UI.xcresult`, deleted; counts from the PR                                                          | 4.70 → 4.04        |
| I3-EDIT (#238) run 1                 | Builder, Settings, Topic                               | 22    | 16     | 6        | 0       | `i3edit-UI-20261126-073324.{summary,tests}.json`                                                                                                | not recorded       |
| I3-EDIT run 2                        | Topic                                                  | 9     | 8      | 1        | 0       | `i3edit-UI-topic-20261126-084257.{summary,tests}.json`                                                                                          | not recorded       |
| I3-EDIT run 3                        | Topic                                                  | 9     | 9      | 0        | 0       | `i3edit-UI-topic2-20261126-090256.{summary,tests}.json`                                                                                         | not recorded       |
| I3-EDIT extra (on `t2/m3a` 3d4592b3) | TopicLifecycle, Timing                                 | 3     | 3      | 0        | 0       | `i3edit-UI-lifecycle-timing-20261126-094030.{summary,tests}.json`                                                                               | not recorded       |
| M3-UITEST r1 own                     | `testNewTopicWithAppearance`                           | 1     | 1      | 0        | 0       | `m3a-uitest-UI-own-20261126-110348.{summary,tests}.json`                                                                                        | 11.15 → 24.29      |
| M3-UITEST regression                 | Builder, Settings, Topic, TopicLifecycle, Tile, Timing | 30    | 27     | 3        | 0       | `m3a-uitest-UI-regression-20261126-110606.{summary,tests}.json` + 3 failure hierarchies                                                         | 15.82 → 12.28      |
| M3-UITEST r2 own + shots             | `testNewTopicWithAppearance` + shots                   | 2     | 1      | 1        | 0       | `m3a-uitest-UI-own-r2-20261126-112840.{summary,tests}.json`                                                                                     | 17.62 → 5.86       |
| M3-UITEST shots, split (timeout)     | 3 shots tests                                          | 3     | 0      | 3        | 0       | `m3a-uitest-UI-shots-timeout-20261126-114712.{summary,tests}.json`                                                                              | 26.44 → 34.76      |
| M3-UITEST shots, final               | 3 light/dark + 1 XXXL                                  | 4     | 4      | 0        | 0       | `m3a-uitest-UI-shots-20261126-121201.{summary,tests}.json`                                                                                      | 174.91 → 29.53     |
| M3-UITEST r3 own (head code)         | `testNewTopicWithAppearance`                           | 1     | 1      | 0        | 0       | `m3a-uitest-UI-own-r3-20261126-125722.{summary,tests}.json`                                                                                     | 47.53 → 10.42      |
| M3-UITEST e2e                        | EndToEnd, EntriesEndToEnd, TapCount                    | 17    | 14     | 0        | 3       | `m3a-uitest-UI-e2e-20261126-123352.{summary,tests}.json`                                                                                        | 86.06 → 8.11       |

The counts for the JSON-backed rows were re-read from the committed
`*.summary.json` files (`totalTestCount`, `passedTests`, `failedTests`,
`skippedTests`), and they match the PR bodies. Every failure is classified:

- I3-EDIT run 1:
  - 2 failures are #89, the system "Save Password?" sheet;
  - 4 were caused by the diff (the keyboard covering Save details and Add
    question). The `TopicUITests.dismissKeyboard` fix makes it assert that the
    keyboard closed.
- I3-EDIT run 2: 1 failure, the schedule preview below the fold. The test now
  scrolls to it.
- M3-UITEST regression:
  - 2 failures are #89;
  - 1 was a bug in the first shots test at XXXL. It was fixed and the shots
    tests were restructured.
- The M3-UITEST shots runs: the 5-minute allowance was exceeded under load
  before the split into per-colour tests.
- No run repeated unchanged tests to get a pass.

### 3.7 e2e run

- #251's run used
  `heavy.sh ios/scripts/uitest-e2e.sh BB9679F1-… -collect-test-diagnostics never`,
  followed by `make ios-integration-down`.
- Result: `Executed 17 tests, with 3 tests skipped and 0 failures`, so 14 passed
  and 3 were skipped.
  - EndToEndUITests: 4 of 7 ran.
  - EntriesEndToEndUITests: 4 of 4.
  - TapCountUITests: 6 of 6.
- The 3 skips are
  `EndToEndUITests/testDemo{ChipAndUndo,OfflineThenSync,SameAsLast}`. They are
  demo-screenshot-only (`QUICKR_UIT_DEMO=1`), not real e2e checks.
- JSON:
  [`m3a-uitest-UI-e2e-20261126-123352.summary.json`](M3a/xcresults/m3a-uitest-UI-e2e-20261126-123352.summary.json).
- **PENDING:** a final e2e run on the gate head (§7).

## 4. Screenshots and recordings

All files are in [`M3a/`](M3a/). The iOS shots come from M3-UITEST's evidence
tests on iOS 26.0 (414 × 900 px). The PWA shots come from a Vite dev server with
`/api/v1` answered from `shared/fixtures/api`.

| File                                                                         | Shows                                                                                                                      |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| [appearance-editor-teal-light.png](M3a/appearance-editor-teal-light.png)     | iOS Appearance editor (New topic), teal selected, emoji and tags, light                                                    |
| [appearance-editor-teal-dark.png](M3a/appearance-editor-teal-dark.png)       | the same, dark                                                                                                             |
| [appearance-editor-teal-xxxl.png](M3a/appearance-editor-teal-xxxl.png)       | the same, teal, at the largest Dynamic Type size                                                                           |
| [appearance-editor-orange-light.png](M3a/appearance-editor-orange-light.png) | iOS Appearance editor, orange, light                                                                                       |
| [appearance-editor-orange-dark.png](M3a/appearance-editor-orange-dark.png)   | the same, dark                                                                                                             |
| [appearance-editor-violet-light.png](M3a/appearance-editor-violet-light.png) | iOS Appearance editor, violet, light                                                                                       |
| [appearance-editor-violet-dark.png](M3a/appearance-editor-violet-dark.png)   | the same, dark                                                                                                             |
| [appearance-header-teal-light.png](M3a/appearance-header-teal-light.png)     | iOS topic header (glyph, name, tag chips, 4 pt teal rule) above the tabs, light                                            |
| [appearance-header-teal-dark.png](M3a/appearance-header-teal-dark.png)       | the same, dark                                                                                                             |
| [appearance-header-teal-xxxl.png](M3a/appearance-header-teal-xxxl.png)       | the same, teal, at the largest Dynamic Type size (chips wrap)                                                              |
| [appearance-header-orange-light.png](M3a/appearance-header-orange-light.png) | iOS topic header, orange, light                                                                                            |
| [appearance-header-orange-dark.png](M3a/appearance-header-orange-dark.png)   | the same, dark                                                                                                             |
| [appearance-header-violet-light.png](M3a/appearance-header-violet-light.png) | iOS topic header, violet, light                                                                                            |
| [appearance-header-violet-dark.png](M3a/appearance-header-violet-dark.png)   | the same, dark                                                                                                             |
| [appearance-flow.mp4](M3a/appearance-flow.mp4)                               | the `testNewTopicWithAppearance` flow: pick a colour, the emoji and two tags, create, open the header (45 s at 2×, 360 px) |
| [f3edit-new-390-light.png](M3a/f3edit-new-390-light.png)                     | PWA new-topic form at 390 px: swatches, the curated emoji grid, the tags field; light                                      |
| [f3edit-new-390-dark.png](M3a/f3edit-new-390-dark.png)                       | the same, dark                                                                                                             |
| [frender-header-390-light.png](M3a/frender-header-390-light.png)             | PWA topic header at 390 px: a teal topic with 🏃 and three tags, the tinted tab rule; light                                |
| [frender-header-390-dark.png](M3a/frender-header-390-dark.png)               | the same, dark                                                                                                             |

Notes:

- The Overview tab in the iOS header shots shows "Could not load stats / Not
  found". `FakeStats` only knows the seeded topics, so this is a fixture
  limitation (#251).
- **GAP:** there are no Live Activity or widget shots. Their tint is rendered in
  T2-WIRE-I, so they are device and T2-WIRE items (§8).

## 5. Known flakes and follow-ups

States are from `gh issue view` at the time of writing.

| Issue                                                      | Title                                                                                                          | State  | Notes                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [#89](https://github.com/Richard-Lynch/quickr/issues/89)   | iOS UI tests: SettingsUITests token tests blocked by the system Save Password sheet                            | CLOSED | Hit in the I3-STORE, I3-EDIT and M3-UITEST runs. Fixed by #232 on `main` (`d3dcdc60`). It reached `feat/t2` through the sync #252 (`edf3d6e5`), and `t2/m3a` through `53179734`. The gate UI run should show the token tests passing                                                             |
| [#225](https://github.com/Richard-Lynch/quickr/issues/225) | Flaky under load: TopicUITests.testCreateATopicOpensItsRecordScreen (q0 card not shown 5 s after Add question) | CLOSED | Root cause: the test helper, not load. `TopicUITests.dismissKeyboard` only tapped the nav bar, which doesn't end editing, so the keyboard covered Add question. Fixed in #238 (drag to dismiss, and it asserts the keyboard is gone). Confirmed in the M3-UITEST regression run (passed, 35.6 s) |
| [#219](https://github.com/Richard-Lynch/quickr/issues/219) | iOS: a save tapped right after a sent archive can 409 before the store copy reaches the settings screen        | OPEN   | from #238; outbox work                                                                                                                                                                                                                                                                           |
| [#226](https://github.com/Richard-Lynch/quickr/issues/226) | Local Live Activity start passes no attributes.appearance (RunActivityCenter); push-to-start does              | OPEN   | from #227; T2-WIRE-I item 3                                                                                                                                                                                                                                                                      |
| [#250](https://github.com/Richard-Lynch/quickr/issues/250) | iOS topic header: expose the glyph to UI tests (accessibility value), so the emoji is assertable               | OPEN   | from #251                                                                                                                                                                                                                                                                                        |
| [#200](https://github.com/Richard-Lynch/quickr/issues/200) | Appearance §2: VS16 insert breaks skin-toned text-presentation emoji (✌🏽 stored as ✌️🏽)                       | OPEN   | from #201; a spec change is proposed there                                                                                                                                                                                                                                                       |
| [#256](https://github.com/Richard-Lynch/quickr/issues/256) | SF Symbol topic icons (needs a PWA mapping)                                                                    | OPEN   | OQ-7, filed by M3-REVIEW                                                                                                                                                                                                                                                                         |
| [#257](https://github.com/Richard-Lynch/quickr/issues/257) | free hex topic colours                                                                                         | OPEN   | OQ-8, filed by M3-REVIEW                                                                                                                                                                                                                                                                         |
| [#269](https://github.com/Richard-Lynch/quickr/issues/269) | PWA: TopicLayout swaps topics when another topic takes a renamed topic's old slug                              | OPEN   | from #270 (Codex round 4, pre-existing)                                                                                                                                                                                                                                                          |
| [#230](https://github.com/Richard-Lynch/quickr/issues/230) | CI: iOS Build + Unit plan step hits its 15-min timeout after the tests pass (budget, not a hang)               | CLOSED | from #227. The step budget was raised on `main` (#231) and synced through #249                                                                                                                                                                                                                   |
| [#217](https://github.com/Richard-Lynch/quickr/issues/217) | SettingsUITests: iOS 'Save Password?' sheet appears after the 3 s dismissal window and blocks the next tap     | CLOSED | found during I3-STORE's UI run (#211); not linked from an M3a PR; the same cause as #89                                                                                                                                                                                                          |
| [#218](https://github.com/Richard-Lynch/quickr/issues/218) | iOS settings: a save tapped while an archive is in flight can get a self-inflicted 409                         | CLOSED | from I3-EDIT; not linked from an M3a PR; superseded by #219                                                                                                                                                                                                                                      |

## 6. Milestone review

- Reviews of `b00f33a7..53179734`:
  - Codex: [M3a-milestone-codex.md](../reviews/M3a-milestone-codex.md).
  - Claude (Opus, `pr-review-toolkit:code-reviewer`):
    [M3a-milestone-claude.md](../reviews/M3a-milestone-claude.md).
- Both reviews found these categories clean: validators, feed and revision
  semantics, the store migration, the LA byte budget, the no-appearance rule,
  tests that can't fail, and scope creep.

| ID  | Source | Severity | Finding                                                                                                                                   | Resolution                                                                                                                                                                                                                                                                 | Fixing PR                                |
| --- | ------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| X1  | Codex  | Medium   | A remote slug change gives a false conflict in the PWA: the refetch by the old slug 404s, and the 409 is reported unchecked               | PWA: the refetch and the PATCH go by id, and `TopicLayout` follows the rename. iOS already fetched by id; that is now asserted (`latestAppliesTheServersTopic`, `writer.latestIds`)                                                                                        | #270, #268 (**PENDING**)                 |
| X2  | Codex  | Medium   | Both clients retry once only, so an unrelated write between the refetch and the retry surfaces as a conflict                              | A bounded loop: refetch and compare on every `stale_revision`, at most 3 sends, then a distinct "busy" error (`twoUnrelatedWritesInARowStillSave`, `threeContentionsSayBusy`; PWA `keeps re-sending over two unrelated writes in a row`, `gives up after three attempts…`) | #268, #270 (**PENDING**)                 |
| C1  | Claude | Medium   | After a same-field conflict the user can never save that field: the base stays on the old revision. The iOS `staleRevision` text is false | On a conflict the base moves to the fresh copy, and the message names the field(s). A second Save overwrites deliberately (`aConflictThenASecondSaveSucceeds`; PWA `shows the conflict naming the field, then a second save overwrites it`). The text was fixed            | #268, #270 (**PENDING**)                 |
| C2  | Claude | Low      | The PWA rebase wipes typed-but-not-added tag text and clears the 422 field errors                                                         | Pending tag text counts as a tags edit, and errors are kept (`reset(…, { keepErrors: true })`): `keeps tag text not added yet and the 422 field errors over a rebase`                                                                                                      | #270 (**PENDING**)                       |
| C3  | Claude | Low      | `// T2-M3` edits outside delimited blocks in non-M3 files: `api.py:212`, `TopicEditing.swift:8–18`, `UITestLaunch.swift:429, :678`        | `_not_nullable` is back in M1's place, referenced through `_not_nullable_late` (`openapi.json` unchanged). `TopicEditing.swift` is delimited. `UITestLaunch.swift` has a comment above the raw-string template and trailing markers                                        | #270 (backend), #268 (iOS) (**PENDING**) |
| C4  | Claude | Low      | An iOS pending-tag 422 lands on `.tags`, not `.newTag`                                                                                    | `AppearanceDraft.field(serverPath:)` maps it to `.newTag` (`aServerErrorOnThePendingTagLandsOnAddATag` in both model suites)                                                                                                                                               | #268 (**PENDING**)                       |

The fix PRs had their own Codex reviews:

- #268, `M3a-rvfix-ios-codex.md`, three rounds:
  - round 2's same-value finding stands by design (a resend);
  - round 3 found no new findings.
- #270, `-codex.md` to `-r5.md`:
  - round 4's slug-reuse finding is #269;
  - round 5 found no findings.

These files land on `t2/m3a` when the PRs merge.

## 7. Final gate runs

Every gate run is **PENDING**. Record the head SHA, the command, the counts
copied from the output, `uptime` at the start and end of sim runs, and the
durable JSON path.

### `make check`

**PENDING** (head `________`): backend `____ passed`, frontend
`Tests ____ passed (____)`, alembic check, openapi and client fresh.

### `make check-ios`

**PENDING** (head `________`).

### UI classes (own clone)

**PENDING**: Builder (including `BuilderUITests+T2M3`), Settings, Topic,
TopicLifecycle, Tile and Timing.

- Tests / passed / failed / skipped: `__ / __ / __ / __`.
- JSON: `M3a/xcresults/m3a-gate-UI-<ts>.{summary,tests}.json`.
- uptime: `____ → ____`.
- Clone shut down: `____`.

### e2e

**PENDING**:
`heavy.sh ios/scripts/uitest-e2e.sh <udid> -collect-test-diagnostics never`,
then `make ios-integration-down`.

- Executed / skipped / failed: `__ / __ / __`.
- JSON: `M3a/xcresults/m3a-gate-e2e-<ts>.{summary,tests}.json`.

### `t2-cleanup.py --machine`

**PENDING**: paste the output here. It must show no orphan clones, DBs or images
of this milestone, and free disk ≥ 40 GB.

```text
PENDING
```

### Milestone PR checks

**PENDING**: backend, frontend, docker, ios gate and compat gate, with links.

## 8. Not verifiable on the simulator

Each item is on
[device-checklist.md › M3a · topic appearance](../device-checklist.md#m3a--topic-appearance).

- **The Live Activity's tinted background and glyph.** The attributes are proven
  by `LiveActivityVectorTests` and the push-to-start tests (#227). The rendering
  is T2-WIRE-I, so this item runs after T2-WIRE. The local start carries no
  appearance yet (#226).
- **Widget tint in full-colour, tinted and accented modes on a real Home
  Screen.** Rendered by T2-WIRE-I, so this item runs after T2-WIRE.
- **The reminder notification title with the emoji prefix.** The composition is
  proven by the server tests and vectors and by `DueReminderVectorTests`. Real
  APNs delivery is device-only.
- **First launch after the upgrade.** A topic themed on another device shows its
  theme after the first sync, because of the store re-pull. This is host-tested
  by `AppearanceUpgradeTests`, but a real upgrade of an installed store,
  together with M1's `t2m1` migration (§3.5), is device-only.
- **The emoji keyboard in the Appearance editor.** The UI test types `🏃` with
  `typeText`. The real emoji keyboard (globe key, skin-tone long-press, flags)
  is device-only.
- **Tile tint and glyph.** T2-WIRE-I, so this item runs after T2-WIRE.
