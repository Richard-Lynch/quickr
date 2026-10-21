# A11Y audit: screen by screen (static read)

This is the A11Y work package's audit list (DAG.md line 140: VoiceOver,
accessibility sizes, 44 pt targets). It comes from a static read of
`origin/ios/m3` at 25c6203. Nothing was run and nothing was edited. Each finding
gives a `file:line` reference relative to `ios/`. `UI/` is short for
`QuickrKit/Sources/QuickrUI/`. Line numbers will drift once INTENTS, WIDGETS,
PERF and UIT-6 merge, so re-anchor them before fixing.

**Checks per screen:**

1. Labels and traits.
2. Grouping and reading order.
3. Dynamic Type at AX XXXL.
4. Tap targets under 44 pt.
5. VoiceOver escape, rotor, focus and announcements.
6. Reduce Motion.

**Severity:**

- **High:** a VoiceOver or AX-size user can't finish a core task (logging, undo,
  recording, fixing an error, scheduling).
- **Medium:** the task works but is noticeably degraded.
- **Low:** polish.

**Verify by:**

- **UI test:** an XCUITest assertion, such as an element's label or trait, a
  frame of at least 44 pt, `isHittable` at XXXL, or no overlap.
- **Audit:** `XCUIApplication.performAccessibilityAudit(for:)`, with the audit
  type named. Accessibility Inspector runs the same audit by hand.
- **Manual:** a VoiceOver or Voice Control walkthrough. The audit can't see
  announcements, focus moves or timing. Widgets and notifications are outside
  the app, so they're always manual.

## What already holds (don't redo)

- **Fonts:** every `Font.qr` scales through `relativeTo:`
  (`UI/Tokens/Typography.swift:115-123`).
- **Badges:** `QuickrBadge` wraps at AX sizes
  (`UI/Components/Surfaces.swift:117-131`).
- **Icons:** `QIconView` is hidden from VoiceOver by default
  (`UI/Icons/QIcon.swift:83`).
- **Reduce Motion guard:** a central guard exists: `qrAnimation`,
  `QuickrMotion.animation(_:reduceMotion:)` and `QuickrPressStyle`
  (`UI/Tokens/Motion.swift:17-53`). Toasts, the sync-pill rotation, the Home
  section dot and the form's scroll all use it.
- **Buttons:** `QuickrButtonStyle` keeps a 44 pt minimum hit area
  (`UI/Components/Buttons.swift:71`).
- **Chips:** they carry `.isSelected`, or `.isToggle` with `.isSelected`; they
  have values and hints; quick chips read "Log X"; reaching the multi-select
  limit is announced (`UI/Components/Chips.swift:124-207`).
- **Stepper:** `NumberStepper` has an adjustable action, a value with its unit,
  and labelled ± buttons.
- **Sync pill:** it's at least 44 pt, scaled, and has a label and hint
  (`UI/Components/SyncPill.swift:11-52`).
- **Home:** the header moves into the list at AX sizes. Section headers are
  combined with `.isHeader` and a count.
- **Record:** the VoiceOver escape is wired to the guarded back
  (`App/Record/RecordView.swift:83`). The form header switches through
  `ViewThatFits`. Save moves into the keyboard toolbar at AX sizes.
- **Entries:** rows are combined, with `.isButton`, a hint and a Delete custom
  action (`App/Entries/List/EntriesView.swift:106-116`). The Edit screen handles
  escape (`App/Entries/Edit/EditScreen.swift:168`).
- **Stats:** the range, bucket, version and source pickers switch to menus at AX
  sizes (`App/Stats/OverviewView.swift:174-184`).
- **Builder:** reordering works through a labelled Move up/down menu, not
  drag-only.
- **Sheets and dialogs:** every sheet has an explicit Cancel. Reset's
  destructive second confirmation names what is lost.

## Cross-cutting findings

These are worth fixing once, in the shared code, rather than screen by screen.

| #   | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Cat | Sev         | Verify by                                                                 |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ----------- | ------------------------------------------------------------------------- |
| X1  | **Undo is effectively unreachable with VoiceOver.** Undo toasts close after 6 s, and plain and error toasts after 3.5 s (`UI/Logic/Toasts.swift:41-42`), even with VoiceOver running. The toast host overlays the whole stack (`App/RootView.swift:19`), so VoiceOver reaches a toast only after every element on the screen (all of Home's tiles). The announcement (`UI/Components/ToastView.swift:102`) says only the title, with no message and no mention that Undo is available. **Fix:** under `UIAccessibility.isVoiceOverRunning`, use no timeout (or a long one) and say "Undo available" in the announcement. Also add a root `accessibilityAction(.magicTap)` (or a named action) that runs the newest toast's action. | 2,5 | **High**    | UI test through a launch flag that holds toasts; Manual for VoiceOver     |
| X2  | **Errors are silent to VoiceOver.** No screen uses `AccessibilityFocusState` or posts an announcement, apart from toasts and the chip limit. Affected: Record's failed Save (F1), onboarding's connect failure (O1), Edit's save banner (E3), new topic and topic settings banners (TP6), the token sheet, the reset outcome, the push test result, and Home's banner. **Fix:** one helper that announces, and focuses the first error or banner, used everywhere an error appears.                                                                                                                                                                                                                                                | 5   | **High**    | Manual; UI test that the error element exists                             |
| X3  | `QuickrButtonStyle` forces `.lineLimit(1)` (`UI/Components/Buttons.swift:60`), so capsule labels clip at XXXL. Examples: "Connect", "Export CSV", "Test this device", "Discard for good", the full-width Save. **Fix:** allow two lines, or `ViewThatFits`, at AX sizes.                                                                                                                                                                                                                                                                                                                                                                                                                                                           | 3   | Medium      | Audit `.textClipped`                                                      |
| X4  | `withAnimation` without the Reduce Motion guard: `App/Home/HomeView.swift:235` (with the `.move(edge: .top)` transition at :284); `App/Topics/Builder/QuestionsEditorView.swift:58,74,146,181,185,189`; `App/Topics/Builder/VersionsView.swift:127`; `App/Topics/Builder/EditQuestionsScreen.swift:94`; `App/Topics/NewTopicScreen.swift:58`. **Fix:** a `withQRAnimation(_:reduceMotion:)` helper next to `qrAnimation`, plus a lint grep for bare `withAnimation(` in `App/`.                                                                                                                                                                                                                                                    | 6   | Medium      | Manual, or a UI test with a Reduce Motion launch flag (see the test plan) |
| X5  | Segmented pickers don't grow with Dynamic Type: topic tabs (B1), the schedule kind (`App/Topics/ScheduleEditorView.swift:23`), and the builder's Edit/Preview (`App/Topics/Builder/QuestionsEditorView.swift:21`). **Fix:** promote Overview's `segmentedOrMenu` (`App/Stats/OverviewView.swift:174-184`) to `QuickrUI` and use it everywhere.                                                                                                                                                                                                                                                                                                                                                                                     | 3   | High (tabs) | Audit `.dynamicType`; UI test                                             |
| X6  | Fixed-size icons that don't scale: `QuickrIconButton`'s 20 pt (`UI/Components/Buttons.swift:162`), the tile's 24 pt plus (`UI/Components/TileView.swift:74`), the toast tone icon (`UI/Components/ToastView.swift:69-71`), the "Same as last time" 36 pt frame (`UI/Form/FormView.swift:217-218`), and the alert glyph (`App/Settings/ServerForm.swift:97`). **Fix:** `@ScaledMetric`.                                                                                                                                                                                                                                                                                                                                             | 3   | Low         | Audit `.dynamicType`                                                      |

## Screen by screen

### Root and navigation

| #   | Finding                                                                                       | Cat | Sev  | Verify by       |
| --- | --------------------------------------------------------------------------------------------- | --- | ---- | --------------- |
| R1  | The toast overlay comes last in reading order. See X1.                                        | 2,5 | High | Manual          |
| R2  | In the "Store failed" fallback, the "quickR" title isn't a header (`App/RootView.swift:136`). | 1   | Low  | UI test (trait) |

### Onboarding (`App/Settings/OnboardingView.swift`, `ServerForm.swift`, `ServerSetup.swift`)

| #   | Finding                                                                                                                                                                                                  | Cat | Sev    | Verify by                                     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ------ | --------------------------------------------- |
| O1  | A connect failure (`ServerForm.swift:94-119`) isn't announced or focused. VoiceOver stays on Connect, and the error sits above it in reading order (X2).                                                 | 5   | High   | UI test (exists) and Manual                   |
| O2  | "Checking the server…" (`ServerForm.swift:89-93`) isn't announced.                                                                                                                                       | 5   | Medium | Manual                                        |
| O3  | `.accessibilityElement(children: .combine)` (`ServerForm.swift:118`) folds the interactive "Details" disclosure (`ServerForm.swift:102`) into the error element.                                         | 2   | Medium | Audit `.elementDetection`/`.trait`; Manual    |
| O4  | Going from the server step to the reminders step (`OnboardingView.swift:40-41, 90`) doesn't move focus to the "Connected" header (`OnboardingView.swift:67-70`).                                         | 5   | Medium | Manual                                        |
| O5  | The "Server address" Text (`ServerForm.swift:19`) duplicates the field's label (`ServerForm.swift:24`), so it's read twice. The helper text (`ServerForm.swift:35`) should be a hint.                    | 1,2 | Low    | Manual                                        |
| O6  | The label "Client ID (….access)" (`ServerForm.swift:47`, `SettingsView.swift:182`) reads punctuation aloud. **Fix:** `accessibilityLabel("Client ID")` and `accessibilityInputLabels` for Voice Control. | 1   | Low    | Audit `.sufficientElementDescription`; Manual |

### Home (`App/Home/HomeView.swift`, `UI/Components/TileView.swift`, `UI/Components/DueBadge.swift`)

| #   | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Cat | Sev      | Verify by                                           |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | -------- | --------------------------------------------------- |
| H1  | The search clear ✕ has no frame or content shape, so its tap target is the 14 pt glyph (`HomeView.swift:219-225`).                                                                                                                                                                                                                                                                                                                                                        | 4   | Medium   | Audit `.hitRegion`; UI test (frame ≥ 44)            |
| H2  | A tile's open button is a background Button labelled with the title (`TileView.swift:54-58`). The title and meta texts (`TileView.swift:37-47`) stay separate elements. VoiceOver reads the title twice, and the due badge and "Last …" line are never part of the button. **Fix:** fold the title, badge and last line into the button's label, and hide the texts.                                                                                                      | 1,2 | Medium   | UI test (count elements with the title); Manual     |
| H3  | No sort priority is set between the background button and the content in front of it.                                                                                                                                                                                                                                                                                                                                                                                     | 2   | Low      | Manual                                              |
| H4  | At XXXL the number quick-log leaves about 30 pt for the value. The ± buttons are up to 56 pt each and the ✓ about 64 pt (`TileView.swift:139`, `UI/Components/NumberStepper.swift:58-61`), inside a tile that gives a fixed 84 pt to the Log block (`TileView.swift:78`, `UI/Tokens/Metrics.swift:19`). The digits clip. **Fix:** at AX sizes, stack the ✓ under the stepper, or the Log block under the body. This matches the TILES backlog item "stacked tile layout". | 3   | **High** | UI test (value width at XXXL); Audit `.textClipped` |
| H5  | A quick-log number error appears inline and silently (`TileView.swift:150-154`) (X2).                                                                                                                                                                                                                                                                                                                                                                                     | 5   | Medium   | Manual                                              |
| H6  | One-word quick chips use `lineLimit(1)` with `minimumScaleFactor(0.6)` (`UI/Components/Chips.swift:72-73`). At XXXL, in two columns of about 104 pt, "Moderate" still truncates.                                                                                                                                                                                                                                                                                          | 3   | Medium   | Audit `.textClipped`; UI test                       |
| H7  | Section titles use `lineLimit(1)` with a 0.6 scale factor (`HomeView.swift:375-376`), so "UNSCHEDULED" may truncate.                                                                                                                                                                                                                                                                                                                                                      | 3   | Low      | Audit `.textClipped`                                |
| H8  | The filter panel animation and transition aren't guarded (X4).                                                                                                                                                                                                                                                                                                                                                                                                            | 6   | Low      | Manual                                              |
| H9  | The error banner isn't announced (`HomeView.swift:87-88`).                                                                                                                                                                                                                                                                                                                                                                                                                | 5   | Low      | Manual                                              |

### Record and form (`App/Record/*`, `UI/Form/*`)

| #   | Finding                                                                                                                                                                                                                                                                                                                    | Cat | Sev      | Verify by                              |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | -------- | -------------------------------------- |
| F1  | A failed Save sets the errors and scrolls (`UI/Form/FormModel.swift:255-270, 315-321`), but keyboard focus moves only for typed fields. Chip and picker questions and the banner get no VoiceOver focus and no announcement, and `QuickrHaptic.failure` is unused. A VoiceOver user hears nothing after tapping Save (X2). | 5   | **High** | Manual; UI test (error element exists) |
| F2  | An inline field error isn't tied to its control: it isn't in the field's value or hint (`UI/Form/AnswerField.swift:56-61`).                                                                                                                                                                                                | 1   | Medium   | Manual                                 |
| F3  | "Log another" rebuilds the form with `.id(...)` (`App/Record/RecordView.swift:39`), so VoiceOver focus is lost. **Fix:** focus the first question.                                                                                                                                                                         | 5   | Medium   | Manual                                 |
| F4  | Auto-save calls `dismiss()` (`App/Record/RecordView.swift:21`) as the toast announcement is posted, so the pop likely cuts off "Logged X".                                                                                                                                                                                 | 5   | Medium   | Manual                                 |
| F5  | The "Same as last time" row: the summary is `lineLimit(1)` (`UI/Form/FormView.swift:229`), and the icon, text and Fill/Undo HStack never stacks at AX sizes.                                                                                                                                                               | 3   | Medium   | Audit `.textClipped`; UI test at XXXL  |
| F6  | The choice picker's selected value is `lineLimit(1)` (`UI/Form/AnswerField.swift:237`).                                                                                                                                                                                                                                    | 3   | Low      | Audit `.textClipped`                   |
| F7  | Question labels aren't headers (`UI/Form/AnswerField.swift:82-87`), so long forms have no heading navigation.                                                                                                                                                                                                              | 1   | Low      | UI test (trait)                        |
| F8  | Backlog (RECORD): at AX sizes with the keyboard up, the sticky Save bar covers much of the form. **Fix:** hide it while the keyboard is visible, since Save is already in the keyboard toolbar at AX sizes.                                                                                                                | 3   | Medium   | UI test at XXXL                        |
| F9  | Backlog (DS): `NumberStepper`'s fixed 52 pt trailing unit padding let the value touch the unit at XXXL ("30min"). This looks **already fixed**: the unit now sits at its own scaled width, with trailing padding of 12 or 14 (`UI/Components/NumberStepper.swift:67-98`). Confirm at XXXL, then close the backlog item.    | 3   | Low      | UI test at XXXL; Audit `.textClipped`  |

### Undo toasts (`UI/Components/ToastView.swift`, `UI/Logic/Toasts.swift`, `UI/QuickLog/EntryToasts.swift`)

| #   | Finding                                                                                                                        | Cat | Sev      | Verify by                             |
| --- | ------------------------------------------------------------------------------------------------------------------------------ | --- | -------- | ------------------------------------- |
| T1  | Fixed timeouts under VoiceOver, and the toast comes last in reading order (X1).                                                | 5   | **High** | UI test (hold flag); Manual           |
| T2  | The announcement is the title only: no message, and no mention that Undo is available (`ToastView.swift:102`).                 | 5   | Medium   | Manual                                |
| T3  | Error toasts close after 3.5 s (`EntryToasts.swift:154-162`, `Toasts.swift:46`) and the timing can't be adjusted (WCAG 2.2.1). | 5   | Medium   | Unit test on `Toast.duration`; Manual |
| T4  | Every Dismiss button is labelled just "Dismiss" (`ToastView.swift:47`), so stacked toasts can't be told apart.                 | 1   | Low      | Audit `.sufficientElementDescription` |
| T5  | The single HStack of text, Undo and ✕ narrows the text column at XXXL; the icon is fixed (X6).                                 | 3   | Low      | UI test at XXXL                       |

### Sync (`App/Sync/SyncPillButton.swift`, `SyncSheet.swift`)

| #   | Finding                                                                                                                                                                                  | Cat | Sev    | Verify by       |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ------ | --------------- |
| S1  | Discard swaps the row's buttons in place for Keep and Discard for good (`SyncSheet.swift:180-200`). VoiceOver focus is left on a button that no longer exists, and nothing is announced. | 5   | Medium | Manual          |
| S2  | "Sync now" shows no busy state and announces nothing (`SyncSheet.swift:79-90`).                                                                                                          | 5   | Low    | Manual          |
| S3  | The sheet's headline isn't a header (`SyncSheet.swift:71`).                                                                                                                              | 1   | Low    | UI test (trait) |

### Topic tabs (`App/Entries/TopicTabsView.swift`): the backlog item

| #   | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Cat | Sev      | Verify by                             |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | -------- | ------------------------------------- |
| B1  | **Backlog (found by STATS): at AX XXXL the topic tabs stay small while the rest of the screen grows.** The cause is confirmed: a `.segmented` Picker (`TopicTabsView.swift:16-19`) with no Dynamic Type branch. A segmented control caps its text size. **Fix:** at AX sizes, use the shared `segmentedOrMenu` (X5) as a menu picker. Or, if the tabs should stay visible, use a scaled custom bar: a `ViewThatFits` HStack falling back to a VStack of Buttons with `.isButton`/`.isSelected` and a 44 pt minimum height. `EntriesTests.swift:101` queries `segmentedControls["topic.tabs"]` and must change with the fix. | 3   | **High** | UI test at XXXL; Audit `.dynamicType` |

### Entries list (`App/Entries/List/EntriesView.swift`)

| #   | Finding                                                                                                                                                                                                                                                                                                                                                                                                                                    | Cat | Sev    | Verify by            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --- | ------ | -------------------- |
| L1  | **Backlog (flake `EntriesTests.testAccessibilityXXXL`):** Delete exists only as a swipe action (`EntriesView.swift:108`) and a custom action (`EntriesView.swift:116`). XCUITest can't invoke the custom action, and rows about 400 pt tall at XXXL put the revealed button under the home indicator. **Fix:** add a `.contextMenu` Delete, and have the test long-press instead of swiping by coordinates (`EntriesTests.swift:118-131`). | 5   | Medium | UI test              |
| L2  | The long, date-ordered list has no custom rotor (by day).                                                                                                                                                                                                                                                                                                                                                                                  | 5   | Low    | Manual               |
| L3  | The version and source pickers sit in an HStack (`EntriesView.swift:186`) with no AX fallback.                                                                                                                                                                                                                                                                                                                                             | 3   | Medium | Audit `.textClipped` |
| L4  | The `EntryFooter` HStack (`EntriesView.swift:470`) puts two badges and the relative time on one line, with no wrap.                                                                                                                                                                                                                                                                                                                        | 3   | Medium | Audit `.textClipped` |
| L5  | Notes use `lineLimit(2)` (`EntriesView.swift:306`), and answer values use `lineLimit(2)` (`EntriesView.swift:437`) in every cell at AX sizes.                                                                                                                                                                                                                                                                                              | 3   | Low    | Audit `.textClipped` |

### Entry details and Edit (`App/Entries/EntryDetailsSection.swift`, `App/Entries/Edit/EditScreen.swift`)

| #   | Finding                                                                                                               | Cat | Sev      | Verify by            |
| --- | --------------------------------------------------------------------------------------------------------------------- | --- | -------- | -------------------- |
| E1  | The details summary is `lineLimit(1)` (`EntryDetailsSection.swift:75`), which truncates the date and source at XXXL.  | 3   | Medium   | Audit `.textClipped` |
| E2  | The details error icon is hidden and has no text (`EntryDetailsSection.swift:77`), so the error state is visual only. | 1   | Medium   | UI test              |
| E3  | Save errors land in a top banner (`EditScreen.swift:178-207`) with no focus move and no announcement (X2).            | 5   | **High** | Manual               |
| E4  | The `EditNotice` heading isn't `.isHeader` (`EditScreen.swift:312`).                                                  | 1   | Low      | Audit `.trait`       |

### CSV export (`App/Entries/Export/EntriesExportButton.swift`)

| #   | Finding                                                                                                 | Cat | Sev | Verify by            |
| --- | ------------------------------------------------------------------------------------------------------- | --- | --- | -------------------- |
| C1  | "Export CSV" can clip (X3).                                                                             | 3   | Low | Audit `.textClipped` |
| C2  | Nothing is announced when the export starts; the button only disables (`EntriesExportButton.swift:34`). | 5   | Low | Manual               |

### Stats overview (`App/Stats/OverviewView.swift`, `OverviewCards.swift`, `StatsCharts.swift`)

| #   | Finding                                                                                                                                                                                                                                                         | Cat | Sev      | Verify by                     |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | -------- | ----------------------------- |
| ST1 | There's no `accessibilityChartDescriptor` anywhere. Each chart reads as one long joined `accessibilityValue` (`StatsCharts.swift:99, 193, 329`), with no navigation per bucket and no Audio Graph. **Fix:** an `AXChartDescriptorRepresentable` per chart kind. | 2   | **High** | Manual                        |
| ST2 | Stacked bars use an ISO 8601 string as the x value (`StatsCharts.swift:169`), so automatic mark labels may read raw timestamps. **Fix:** a label and value on each mark.                                                                                        | 1,2 | Medium   | Manual                        |
| ST3 | The line chart draws Area, Line and Point marks per bucket (`StatsCharts.swift:54-67`), so elements may be tripled. **Fix:** hide the Area and Rule marks.                                                                                                      | 2   | Medium   | Manual                        |
| ST4 | The histogram's `.accessibilityElement(children: .ignore)` (`StatsCharts.swift:327`) removes the bars from VoiceOver.                                                                                                                                           | 2   | Medium   | Manual                        |
| ST5 | Fixed chart heights (170 and 150 in `QuickrKit/Sources/QuickrCore/Charts/ChartModels.swift:64,109`; 100 at `StatsCharts.swift:316`) and `.fixedSize()` x-axis labels (`StatsCharts.swift:183`) overlap at XXXL.                                                 | 3   | Medium   | UI test; Audit `.textClipped` |
| ST6 | The version and source picker HStack (`OverviewView.swift:140`) has no AX fallback.                                                                                                                                                                             | 3   | Medium   | Audit `.textClipped`          |
| ST7 | The "Most common" and "Recent" rows aren't combined (`OverviewCards.swift:202, 225`), and "Most common" values are `lineLimit(1)` (`OverviewCards.swift:203`).                                                                                                  | 2,3 | Low      | Manual                        |

### Topics (`App/Topics/NewTopicScreen.swift`, `TopicSettingsView.swift`, `ScheduleEditorView.swift`)

| #   | Finding                                                                                                                                                                | Cat | Sev      | Verify by                     |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | -------- | ----------------------------- |
| TP1 | The weekday row is an HStack of seven buttons (`ScheduleEditorView.swift:102`), about 46 pt each at XXXL, so their labels clip. **Fix:** wrap into a grid at AX sizes. | 3   | **High** | UI test; Audit `.textClipped` |
| TP2 | The day presets have `minHeight: 36` (`ScheduleEditorView.swift:134`) in a non-wrapping HStack (`ScheduleEditorView.swift:128`).                                       | 3,4 | Medium   | Audit `.hitRegion`            |
| TP3 | "Remove time" is a bare symbol of about 22 pt (`ScheduleEditorView.swift:74-81`).                                                                                      | 4   | Medium   | Audit `.hitRegion`            |
| TP4 | The schedule-kind picker is segmented (`ScheduleEditorView.swift:23`) (X5).                                                                                            | 3   | Medium   | Audit `.dynamicType`          |
| TP5 | The interval field has `maxWidth: 90` (`ScheduleEditorView.swift:157`), so it clips at XXXL.                                                                           | 3   | Low      | Audit `.textClipped`          |
| TP6 | An error only scrolls to its banner (`NewTopicScreen.swift:58`); the topic settings banners (`TopicSettingsView.swift:59, 98`) aren't focused or announced (X2).       | 5   | **High** | Manual                        |

### Builder (`App/Topics/Builder/*`)

| #   | Finding                                                                                                                                                                                                                                        | Cat | Sev    | Verify by            |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ------ | -------------------- |
| BD1 | Moving a question works through a menu (`QuestionsEditorView.swift:179-196, 391-403`). Add `accessibilityAction(named:)` Move up and Move down on the question header (`QuestionsEditorView.swift:145`), and keep focus on the moved question. | 5   | Medium | Manual               |
| BD2 | The option trash button (`QuestionsEditorView.swift:382-389`) and the move menu (`QuestionsEditorView.swift:400-402`) are under 44 pt.                                                                                                         | 4   | Medium | Audit `.hitRegion`   |
| BD3 | An archived option is shown only by strikethrough and opacity (`QuestionsEditorView.swift:371, 426`); its label doesn't say "archived".                                                                                                        | 1   | Medium | UI test              |
| BD4 | The side-by-side number fields (`QuestionsEditorView.swift:266, 270, 279, 304`) and the Options header (`QuestionsEditorView.swift:340`) have no AX fallback.                                                                                  | 3   | Medium | Audit `.textClipped` |
| BD5 | The Edit/Preview picker is segmented (`QuestionsEditorView.swift:21`) (X5).                                                                                                                                                                    | 3   | Medium | Audit `.dynamicType` |
| BD6 | The version header HStack (`VersionsView.swift:129`) and the intro-and-button HStack (`VersionsView.swift:27`) are cramped at XXXL.                                                                                                            | 3   | Medium | Audit `.textClipped` |
| BD7 | The preview title is `lineLimit(1)` (`BuilderPreviewView.swift:28`), and the type badge reads "INT" (`VersionsView.swift:185`). **Fix:** label it "Whole number".                                                                              | 1,3 | Low    | Audit                |
| BD8 | Unguarded animations (X4).                                                                                                                                                                                                                     | 6   | Medium | Manual               |

### Settings, token sheet and reset (`App/Settings/*`)

| #   | Finding                                                                                                                                                                                                                                            | Cat | Sev    | Verify by                              |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | ------ | -------------------------------------- |
| SE1 | The token sheet's error (`SettingsView.swift:193-195`) and `tokenError` (`SettingsView.swift:116-118`) aren't announced or focused (X2).                                                                                                           | 5   | Medium | Manual                                 |
| SE2 | The token sheet has `interactiveDismissDisabled` while a secret is typed (`SettingsView.swift:210`). Check that the VoiceOver escape does nothing and leaves no secret behind; Cancel is reachable (`SettingsView.swift:201`).                     | 5   | Low    | Manual                                 |
| SE3 | "Zero Trust ▸ Access ▸ Service Auth" (`SettingsView.swift:191`) and "Settings ▸ Notifications ▸ quickR" (`NotificationPermission.swift:69`): VoiceOver reads "▸" as "right-pointing small triangle". **Fix:** an `accessibilityLabel` with commas. | 1   | Low    | Manual                                 |
| SE4 | The sync section header, an HStack of text and a badge (`App/Settings/App/AppSyncSection.swift:59-67`), squeezes at AX sizes. The sync problem text and the end of "Sync now" (`AppSyncSection.swift:30-51`) aren't announced.                     | 3,5 | Low    | Audit `.textClipped`; Manual           |
| SE5 | The reset outcome texts (`ResetFlow.swift:182-191`) aren't announced after the dialogs close; VoiceOver returns to the disabled "Reset local data…" button. No UI test covers the reset dialogs.                                                   | 5   | Medium | UI test (`settings.resetDone`); Manual |
| SE6 | Each licence is one huge Text element (`App/Settings/App/LicencesView.swift:38`).                                                                                                                                                                  | 2   | Low    | Manual                                 |
| SE7 | The "Reminders" title in the notification explainer isn't `.isHeader` (`NotificationPermission.swift:52`), and its status change after the system prompt isn't announced (`NotificationPermission.swift:62-87`).                                   | 1,5 | Low    | UI test (trait); Manual                |
| SE8 | In the push device row, "Test this device" clips (X3), and its result appears silently (`App/Notifications/Registration/PushDeviceRow.swift:36-41`).                                                                                               | 3,5 | Medium | Audit `.textClipped`; Manual           |

### Notifications and widgets (manual only)

| #   | Finding                                                                                                                                                                                                                                                                                                                                                             | Cat | Sev | Verify by |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- | --- | --------- |
| N1  | The number action title `"✓ <value> <unit>"` (`QuickrKit/Sources/QuickrData/Notifications/NotificationCategory.swift:209`) reads "check mark 72 kg", and Voice Control has to match the glyph. **Fix:** "Log 72 kg". This needs a backend change too, because the title comes from the shared vectors. **Fixed** (ios/m3-a11y-lows: backend, vectors, PWA and iOS). | 1   | Low | Manual    |
| N2  | Option labels are cut to 64 scalars plus "…" (`NotificationCategory.swift:63, 177-183`). This is acceptable; just confirm it on a device.                                                                                                                                                                                                                           | 1   | Low | Manual    |
| W1  | The widget's "quickR" caption and topic name (`Widgets/TopicWidget.swift:44-48`) are two VoiceOver elements. **Fix:** combine them. The name has no line limit or scale factor (`TopicWidget.swift:47`), so it clips in `.systemSmall` at AX sizes. Re-check after WIDGETS merges.                                                                                  | 2,3 | Low | Manual    |

## Test plan

**Today:**

- `performAccessibilityAudit` runs once, in
  `TileUITests.testTilesWorkAtAnAccessibilityTextSize`. It checks
  `.dynamicType`, `.elementDetection`, `.hitRegion` and
  `.sufficientElementDescription`, filtered to the tiles' frames.
- XXXL launches set
  `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`
  inline in each file's private `launch(...)`. There's no shared helper.
- Tests with an XXXL launch:
  - `HomeTests.testAccessibilityXXXL`
  - `RecordUITests.testRecordAtAnAccessibilityTextSize`
  - `FormUITests.testWorkoutFormWorksAtAnAccessibilityTextSize`
  - `SyncUITests.testSheetAtAccessibilityXXXL`
  - `EntriesTests.testAccessibilityXXXL` (the flake, L1)
  - `EntriesExportUITests`
  - `StatsUITests`
  - `EditTests`
  - `TopicUITests.testSettingsAtTheLargestTextSize`
  - `SettingsUITests.testOnboardingWorksAtAnAccessibilityTextSize`
  - `AppSettingsUITests.testAccessibilityXXXL`
- Not covered at XXXL: Builder, Versions, the topic tabs, reset, the push row
  and the token sheet.
- No test turns on Reduce Motion.

**Proposed for A11Y:**

1. **Shared helpers** in `UITests/`:
   - `launch(axSize:)`.
   - `assertAccessible(_ app:, types:, ignoring:)`, which wraps
     `performAccessibilityAudit`. The default types are `.dynamicType`,
     `.textClipped`, `.hitRegion`, `.elementDetection`,
     `.sufficientElementDescription` and `.trait`. Leave out `.contrast` until
     the palette is checked; its issues should be tracked separately.
2. **One audit per screen at XXXL**, in the existing XXXL tests:
   - Home (the whole screen, not just the tiles);
   - Record and Form;
   - the sync sheet;
   - the topic tabs with Overview, Entries and Versions;
   - Edit;
   - New topic and the schedule editor;
   - the Builder;
   - onboarding and Settings.

   Each one starts with an explicit allow-list of known issues, given by finding
   id. A fix removes its entry, so the list only shrinks.

3. **Targeted UI assertions** where the audit is blind or flaky:
   - H1: the clear button's frame is at least 44 pt.
   - H4: the stepper's value field is wider than the value.
   - B1: the tabs are a menu, or at least 44 pt tall, at XXXL.
   - L1: Delete through the context menu.
   - TP1: every weekday label is hittable and unclipped.
   - X1: with a debug flag that holds toasts, Undo stays and is hittable.
   - The header traits for R2, S3, F7 and SE7.
4. **Reduce Motion:** add a DEBUG-only `-QuickrReduceMotion` launch flag that
   overrides `\.accessibilityReduceMotion` at the root. A smoke test then
   toggles the Home filter and opens a toast, and checks that the state changes
   immediately. Back it with the X4 lint grep for bare `withAnimation(` in
   `App/`.
5. **Manual VoiceOver and Voice Control script**, run on device D and recorded
   in the PR:
   - X1 and X2;
   - F1, F3 and F4;
   - O1 and O4;
   - ST1 to ST4;
   - S1;
   - BD1;
   - N1 and N2;
   - W1.

## Split for the App/ phase

Three agents work in parallel, one per slice, each on its own branch from `ios/m3-a11y`
(after 4a016cd and the r1 fixes). Each slice:

- owns the App/ and UI-test files listed for it, and fixes every High and Medium finding on its
  screens;
- adds its screens' XXXL audits with `assertAccessible`;
- reports its Low findings to the orchestrator for the STATUS backlog, except trivial ones,
  which it fixes.

### Slice A: Home, Record, Form, Sync, toasts, onboarding, Settings

- **App files:**
  - `App/Home/**`, `App/Record/**`, `App/Sync/**`, `App/Undo/**`;
  - `App/Settings/**`, including `App/Settings/App/**`;
  - `App/Notifications/Registration/PushDeviceRow.swift` and `AppDelegate.swift`;
  - `App/RootView.swift` and `App/AppEnvironment.swift`.
- **QuickrUI files:**
  - `UI/Form/**`, `UI/QuickLog/**`, `UI/Record/**`;
  - `UI/Components/{TileView,Chips,NumberStepper,ToastView,SyncPill,Surfaces,Buttons}.swift`;
  - `UI/Logic/Toasts.swift`.
- **Findings:**
  - X1: the magic tap goes into `AppDelegate`, which becomes a `UIResponder` and overrides
    `accessibilityPerformMagicTap()` to call `ToastCenter.performNewestAction()`, returning
    false when there's no toast so the system's own magic tap still works;
  - X2 call sites: Form, ServerForm, the token sheet, Home's banner, reset, the push row;
  - X4: the HomeView call sites;
  - R2, O1–O6, H1–H9, F1–F8, T1–T5, S1–S3, SE1–SE8.
- **Tests:** `HomeTests`, `TileUITests`, `RecordUITests`, `FormUITests`, `SyncUITests`,
  `SettingsUITests`, `AppSettingsUITests`, `LaunchTests`. Slice A also writes the **Reduce
  Motion launch test** (Home: the filter panel and a toast with `-QuickrReduceMotion`).
- **Simulator check:** confirm on the simulator that the magic tap reaches the delegate from a
  focused element inside the SwiftUI hierarchy, and that the system's own magic tap still works
  when no toast is up.

#### Slice A status (branch `ios/m3-a11y-a`)

**Fixed:**

- **X1:** the magic tap.
  - The `AppDelegate`, now a `UIResponder`, overrides `accessibilityPerformMagicTap()` and
    declines when no toast has an action.
  - An actionable toast's own elements carry `.accessibilityAction(.magicTap)`.
  - Focus is never moved to a toast; its announcement says "Undo available".
- **X2 call sites:** Form, ServerForm, the token sheet, the Settings token row, the reset
  outcome, the push test result, the sync problem, Home's banner and the quick-log number error.
- **X3 and X6:** in shared code.
- **X4:** HomeView.
- **R2.**
- **O1–O6.**
- **H1, H2, H4–H9.**
- **F1–F7:**
  - F8 was already done: Save moves into the keyboard toolbar.
  - F9 is now fixed for real: the stepper puts the field over − and + at AX sizes.
- **T1–T4:** in shared code.
- **S1–S3.**
- **SE1, SE3–SE5, SE7, SE8.**

**Tests:**

- `assertAccessible` at XXXL in `HomeTests`, `TileUITests`, `RecordUITests`, `FormUITests`,
  `SyncUITests`, `SettingsUITests` and `AppSettingsUITests`.
- `HomeTests.testReduceMotionKeepsEverythingWorking`.
- `MagicTapTests`.
- `FormModelTests` for the VoiceOver request rules.

**Allow-listed, with reasons:**

- The system navigation bar's Done on the sync sheet (`.dynamicType`). Bar items stop growing
  at a cap, and the Large Content Viewer covers them.
- E1 in `RecordUITests`, until slice B's fix merges.

**Accepted:** at AX sizes the server address field wraps (vertical axis), and a line break
added with nothing else is Return, which connects. Pasting a lone line break, or the identical
address plus one, therefore connects that same address, exactly as Go would. Only a UIKit text
view could tell a paste from Return (Codex r3; documented in `ServerForm.swift`).

**To the STATUS backlog (Low):**

- H3: the tile's sort priority.
- T5: the toast's single row at XXXL.
- SE6: a licence read as one element.
- SE2: a manual check that the token sheet's VoiceOver escape keeps no secret.
- The Home section's pulse dot doesn't stop if Reduce Motion is switched on while it runs.

**Device D:** check both magic-tap paths, and where error focus lands
(`docs/ios/DEVICE-DAY.md`, through m6-builder).

### Slice B: Entries, Edit, Export, Stats and the topic tabs

- **App files:** `App/Entries/**` (including `TopicTabsView.swift` and
  `EntryDetailsSection.swift`) and `App/Stats/**`.
- **QuickrUI files:** `UI/Edit/**`, and `QuickrCore/Charts/ChartModels.swift` for the chart
  heights.
- **Findings:**
  - B1: `QuickrSegmentedPicker` replaces both the tabs' Picker and Overview's private
    `segmentedOrMenu`, which is deleted;
  - L1–L5, including the context-menu Delete that fixes the `EntriesTests` XXXL flake;
  - E1–E4 (X2 in Edit);
  - C1–C2;
  - ST1–ST7 (chart descriptors).
- **Tests:** `EntriesTests`, `EditTests`, `EntriesExportUITests`, `StatsUITests`,
  `Entries/EntriesEndToEndUITests`.

### Slice C: Topics, Builder, Schedule

- **App files:** `App/Topics/**`, including `Builder/**` and `VersionsView.swift`.
- **QuickrUI files:** `UI/Topics/**`.
- **Findings:**
  - TP1–TP6 (X2 in NewTopic and TopicSettings, and X5 for the schedule kind picker);
  - BD1–BD8 (X5 for Edit/Preview, and X4 for the Builder, NewTopic and EditQuestions call
    sites).
- **Tests:** `TopicUITests`, `BuilderUITests`, including Versions at XXXL.

### Cross-slice touch points

1. **Topic tabs in other slices' tests (B):** at AX sizes the tabs become a menu, so
   `app.segmentedControls["topic.tabs"]` no longer matches.
   - Slice B adds `UITests/TopicTabsSupport.swift` with a `selectTopicTab(_:in:)` helper that
     works for both a segmented control and a menu.
   - B switches every `topic.tabs` query that can run at an AX size to that helper. Today the
     queries are in `EditTests:191`, `EntriesTests:101`, `HomeTests:62`, `LinksUITests:16` and
     `StatsUITests:63,67`.
   - B makes those one-line edits in A's `HomeTests` and the shared `LinksUITests` too. These
     are the only cross-slice file edits.
2. **Versions (C) is reached through the tabs (B):** until B merges, C's Versions XXXL test opens
   Versions by deep link (`quickr://…/versions`, as `LinksUITests` does). It switches to the
   helper afterwards.
3. **Shared QuickrUI components:** Buttons, Surfaces, Typography, Motion and Accessibility belong
   to slice A after the shared-code commit.
   - B or C asks A for any change there, or makes it in a separate small commit that A
     reviews.
   - New shared helpers go in new files, not in existing ones.
4. **`UITests/AccessibilitySupport.swift`:** frozen during the App/ phase, and owned by slice A.
   A helper a slice needs, such as a screen's allow-list or a preset, goes in a new file of its
   own, for example `UITests/EntriesAccessibility.swift`. A change to `assertAccessible` goes
   through A.
5. **Motion lint:** the slices convert their own `withAnimation` call sites (A: HomeView; C:
   Builder, NewTopic, EditQuestions). The last slice to merge sets the
   `QUICKR_MOTION_LINT` default to `strict` in `scripts/lint-motion.sh`.
6. **This document and STATUS:** each slice marks its own finding ids as fixed, in its own
   sections only. Lows for the backlog go to the orchestrator by message, not as edits to
   STATUS, which would conflict.
7. **Merge order:** C, then B (the tabs helper), then A (the delegate, plus the strict motion
   lint once the others have landed). Any order works if the touch points above are kept.

## Suggested order

1. The High items:
   - X1 (VoiceOver undo);
   - X2 (the error-focus helper, used in F1, O1, E3 and TP6);
   - B1 and X5 (the tabs and the shared segmented-or-menu);
   - H4 (the tile at XXXL);
   - TP1 (weekdays);
   - ST1 (chart descriptors).
2. The shared fixes: X3, X4 and X6.
3. The Medium items, screen by screen, along with each screen's audit test.
4. The Low items.
