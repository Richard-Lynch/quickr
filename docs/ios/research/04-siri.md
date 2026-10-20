# Research 04: Siri, App Intents and Apple Intelligence for quickR

Date: 2026-10-17. Target iOS 26.0; Xcode 27.1 / iOS 27 SDK. Feeds PLAN §2, §10
Q3, M4 and DAG INTENTS. "AI hw" = Apple Intelligence iPhone (15 Pro+), AI on.

## Recommendations (summary)

1. **Multi-question topics _can_ now be logged by voice and in a snippet.** Use
   one `LogTopicIntent` that asks each question with `requestValue` /
   `requestDisambiguation`, then shows an **interactive confirmation snippet**
   (`requestConfirmation(snippetIntent:)`, iOS 26) with option chips, toggles
   and ± steppers. Free-text questions are voice-only. Drop PLAN limitation 5.
2. **On AI hardware, add a one-utterance path:** ask "What do you want to log?",
   then map the reply to typed answers with the **on-device Foundation Model**
   and a `DynamicGenerationSchema` built from the topic's questions (iOS 26). It
   works offline. Then ask only for the missing or invalid fields.
3. **Don't adopt an App Schema domain.** No domain fits. Journaling is
   Shortcuts-only; Notes/Reminders would be a misfit. So quickR stays
   **App-Shortcut-driven** for Siri, on both iOS 26 and 27.
4. **Pull forward from "deferred":** `IndexedEntity` on `TopicEntity` (iOS 18+)
   and `UndoableIntent` (iOS 26). Both are cheap and both are on the 26.0 floor.
5. **iOS 27 behind `@available`:** `SyncableEntity`, `allowedExecutionTargets`,
   view annotations, and AppIntentsTesting in the test target. Everything else
   ships on 26.0.
6. **Every write intent** commits to the outbox before returning and uses
   `supportedModes = [.background]`. Only `OpenRecordIntent` uses the
   foreground.

## 1. What's new (iOS 26 and iOS 27)

| Capability                                                                                                                                    | Min iOS                             | AI hw?        | Use for quickR                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | ------------- | ---------------------------------------------- |
| Interactive snippets: `SnippetIntent`, `ShowsSnippetIntent`, `requestConfirmation(…snippetIntent:)`, `reload()` [1][2][3]                     | 26.0                                | No            | **Yes**: confirmation form and result card     |
| `requestChoice(between:dialog:view:)` [1]                                                                                                     | 26.0                                | No            | Yes: "Log / Edit / Cancel"                     |
| `supportedModes` (`.background`, `.foreground(.immediate/.dynamic/.deferred)`), `continueInForeground` [1][4]                                 | 26.0                                | No            | Yes                                            |
| `UndoableIntent` (`undoManager`) [1]                                                                                                          | 26.0                                | No            | Yes: undo by entry id                          |
| `@Property(indexingKey:)`, `@ComputedProperty`, `@DeferredProperty` [1]                                                                       | 26.0                                | No            | Indexing keys on `TopicEntity`                 |
| Visual Intelligence (`SemanticContentDescriptor`, `.visualIntelligence.semanticContentSearch`) [1]                                            | 26.0                                | Yes           | No (we have no image content)                  |
| Shortcuts **Use Model** (on-device, PCC, ChatGPT) [12]                                                                                        | 26.0                                | Yes           | Free for users: model output → our intents     |
| Foundation Models (`LanguageModelSession`, `DynamicGenerationSchema`) [9]                                                                     | 26.0                                | Yes           | Yes: utterance → answers                       |
| `IndexedEntity` + `CSSearchableIndex.indexAppEntities` [5]                                                                                    | 18.0                                | No*           | Yes                                            |
| Controls (`ControlWidgetButton`), Action button binding                                                                                       | 18.0                                | No            | Already in WIDGETS                             |
| App Schemas: `@AppIntent/@AppEntity/@AppEnum(schema:)`; primary vs Shortcuts-only domains; use-case groups [6][7]                             | macro 18.0; Siri AI uses them on 27 | Yes (Siri AI) | No fitting domain (§3)                         |
| **New Siri ("Siri AI")**: personal context, on-screen awareness, in-app actions, multi-turn [5][7][8][13]                                     | 27.0                                | Yes           | Only through schemas; App Shortcuts still work |
| View annotations `.appEntityIdentifier(_:)`, `appEntityUIElements` [5][14]                                                                    | 27.0 (NSUserActivity form 18.2)     | Yes           | Low value without a schema                     |
| `IntentDonationManager.donate(intent:result:)`, `OwnershipProvidingEntity`, `IntentValueQuery`, `.system.searchInApp` [5]                     | 27.0                                | Yes           | Optional `searchInApp` later (M5)              |
| `SyncableEntity`, `EntityCollection`, `@UnionValue`, `RelevantEntities`, `ValueRepresentation`, `Duration`/`PersonNameComponents` params [10] | 27.0                                | No            | `SyncableEntity` only                          |
| `allowedExecutionTargets` (`.main`, `.appIntentsExtension`, `.widgetKitExtension`) [10]                                                       | 27.0                                | No            | Pin the writers' process                       |
| **AppIntentsTesting** (`IntentDefinitions`, `makeIntent(…).run()`, `entities(matching:)`, `spotlightQuery`) [11]                              | Xcode 27, iOS 27 runtime            | No            | Yes: INTENTS tests                             |

Notes:

- *`IndexedEntity` feeds Spotlight on every device. Semantic search and Siri
  reasoning over the index need AI hardware.
- The personal-context and in-app-action Siri promised for iOS 18/26 slipped
  repeatedly. Treat it as **iOS 27 only** [13][15].
- Apple's snippet guide warns: "When someone performs an action with Siri AI
  that invokes your app intent, the system might not display `IntentDialog` or
  `ShowsSnippetView`" [3]. So the dialog text must carry the result on its own.

## 2. Multi-question topics by voice

**Verdict: yes, with an in-`perform()` dialogue loop plus a confirmation
snippet.** Parameters are static, but `perform()` can prompt as often as it
likes. Each prompt is a Siri turn ("multi-turn parameter resolution"). Apple's
iOS 27 sessions add no "dynamic parameter" API. Siri AI's free-form multi-turn
is reserved for schema intents [8][16].

Flow for `LogTopicIntent(topic)`:

1. **Resolve the topic.** The phrase parameter, else
   `$topic.requestDisambiguation(among:)`, else `requestValue`.
2. **Pick the AI path.** If
   `SystemLanguageModel.default.availability == .available`:
   `let text = try await $utterance.requestValue("What's your \(topic) entry?")`.
   Build a `DynamicGenerationSchema` from the pinned version:
   - int/double → number property;
   - enum → `anyOf` of option labels;
   - multi → `arrayOf` choices;
   - string → string.

   Generate on-device, then run Core validation. Skip this path on `rateLimited`
   (background apps are rate-limited [9]) or on any error.

3. **Ask for what's missing.** For each required question still missing or
   invalid, use one hidden "slot" parameter per type:
   - `numberSlot: Double?` → `requestValue("How many hours did you sleep?")`.
     Siri parses the spoken number. The unit goes in the dialog.
   - `optionSlot: QuestionOptionEntity?` →
     `requestDisambiguation(among: options, dialog:)`. The query reads the
     "current question" from a `@Dependency`.
   - `textSlot: String?` → `requestValue`.
   - multi-select → use `requestChoice` repeatedly with "Done" as an option. The
     snippet's toggles are the better UI.
4. **Confirm.**
   `try await requestConfirmation(actionName: .log, snippetIntent: EntryDraftSnippetIntent(draftID:))`.
   The snippet shows every answer, including optional ones, with
   `Button(intent: SetDraftAnswerIntent(...))` chips, `Toggle(intent:)` for
   multi-select and ± buttons for numbers. After each tap, the system re-runs
   the snippet's `perform()` [2][3]. The draft lives in the App Group store,
   never in parameters.
5. **Commit.** Enqueue to the outbox, then return
   `.result(dialog: "Logged Sleep: 7.5 h, good")` plus a static result snippet.
   `source = ios.siri`.

**Limits:**

- Snippets support only buttons and toggles: no text fields or pickers [2][3].
  Free text needs voice or the record screen. "Edit in app" calls
  `continueInForeground` (requires `.foreground(.dynamic)` in modes).
- Treat ~30 s of _processing_ as the budget [10]. Whether waiting for the user
  counts toward it is undocumented, so the **spike must measure it** with a
  6-question topic.
- Repeated `requestValue` on the same parameter isn't documented; the spike must
  prove it too. Fallback: one slot parameter per question index (`q1…q8` per
  type).
- A Widget, Control or Action button run can't prompt. Those surfaces call
  `RepeatLastEntryIntent`, `LogEntryIntent` with full values, or
  `OpenRecordIntent`.

## 3. Assistant schemas / domains

- **Primary domains** (Siri AI): Audio, Calendar, Camera, Clock, Mail, Maps,
  Messages, Notes, Phone, Photos, Reminders and System/in-app search.
- **Shortcuts-only domains:** Books, Browser, Files, **Journaling**,
  Presentation, Reader, Spreadsheet, Whiteboard and Word processor [6].
- **There is no health or measurement domain.**

`.journal.createEntry` (message, title, entryDate, location, mediaItems) [17]:

- It "doesn't make your conforming types discoverable by Apple Intelligence and
  Siri" [18].
- It takes free text, not typed answers.

Notes/Reminders would conflict with "Only apply schemas for actions and content
that genuinely match the domain's intended purpose" [7]. Some schemas also come
in use-case groups that must be adopted whole [7].

**Recommendation:** adopt none for logging. The only cheap fit is
`.system.searchInApp` ("search quickR for migraines"), once M5's entry search
exists. A schema would buy multi-turn Siri AI and phrase-free invocation [8].
Without one, Siri AI reaches custom intents only through App Shortcuts [16]
(a forum reply, consistent with [8]). Re-check the domain list each WWDC.

## 4. Offline and execution

- **Intent code** is ours. It reads GRDB and writes the outbox, so it is fully
  offline. Sync is best-effort after the commit.
- **Foundation Models** run on-device with no network in the path [9]. They are
  unavailable if the device isn't eligible, AI is off, or the model is still
  downloading. Background sessions can be rate-limited [9].
- **Classic Siri / App Shortcuts:** phrase matching is on-device. Offline
  behaviour isn't documented for iOS 27, so the M4-DEV checklist runs Siri in
  airplane mode.
- **Siri AI** routes between on-device and Private Cloud Compute [19], so
  schema-driven requests may need the network. Ours don't depend on it.
- **Processes:**
  - Siri/Shortcuts runs launch the app in the background, unless the intent is
    in an extension.
  - Widget/Control button intents run in the widget extension.
  - Snippets keep the app alive in the background while visible [3].
  - On iOS 27, `allowedExecutionTargets` makes this explicit [10].
  - PLAN's GRDB multi-process rules already cover this.
- **Time:** about 30 s per intent [10].

## 5. Recommendation for quickR

### Entities and queries (package `QuickrData/Intents`)

- **`TopicEntity: IndexedEntity`**:
  - `@Property(indexingKey: \.displayName) name`;
  - `EntityStringQuery` + `EnumerableEntityQuery` over GRDB, excluding archived
    topics;
  - index after each sync and on topic change;
  - `@available(iOS 27, *) extension TopicEntity: SyncableEntity` (the server id
    is already stable).
- **`QuestionOptionEntity`**, with an `@IntentParameterDependency` query on the
  topic, or the current question for the slots.
- **`EntryEntity`** as a return value for Shortcuts chaining.

### Intents

| Intent                                                | Parameters                                | Modes                                                                 | Notes                                                                      |
| ----------------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `LogEntryIntent`                                      | topic, option?, number?                   | `.background`                                                         | Quick-log topics; widgets/Controls; `UndoableIntent`                       |
| `LogTopicIntent` (new)                                | topic; hidden slots; `utterance: String?` | `[.background, .foreground(.dynamic)]`                                | §2 loop + snippet; any topic; `UndoableIntent`                             |
| `RepeatLastEntryIntent`                               | topic                                     | `.background` (`.foreground(.dynamic)` when it falls back to prefill) | Action button; PLAN §2 rules                                               |
| `OpenRecordIntent`                                    | topic                                     | `.foreground(.immediate)`                                             | `onAppIntentExecution`                                                     |
| `WhatsDueIntent`                                      | —                                         | `.background`                                                         | Dialog + snippet listing due topics, with `Button(intent: LogTopicIntent)` |
| `EntryDraftSnippetIntent`, `EntryResultSnippetIntent` | draftID / entryID                         | —                                                                     | `SnippetIntent`, not discoverable                                          |
| `SetDraftAnswerIntent`, `StepDraftNumberIntent`       | draftID, questionID, value                | `.background`                                                         | Snippet buttons only (`isDiscoverable = false`)                            |

`LogEntryIntent` and `LogTopicIntent` share one commit function. Undo deletes by
entry id through the outbox (PLAN §3).

### App Shortcuts

Phrase rules [20][21]:

- every phrase contains `\(.applicationName)`;
- at most one parameter per phrase, and it must be an `AppEntity`/`AppEnum`;
- at most 10 App Shortcuts per app;
- call `updateAppShortcutParameters()` after topic changes;
- add app-name synonyms through `INAlternativeAppNames` (e.g. "Quicker").

Phrases:

- "Log \(\.$topic) in \(.applicationName)" → `LogTopicIntent`. Quick-log topics
  pass straight to its single question.
- "Same \(\.$topic) as last time in \(.applicationName)" →
  `RepeatLastEntryIntent`.
- "Record \(\.$topic) in \(.applicationName)" → `OpenRecordIntent`.
- "What's due in \(.applicationName)" → `WhatsDueIntent`.

Negative phrases go in `negativePhrases`.

### iOS 26.0 vs iOS 27

- **26.0:** everything above, including snippets, `requestChoice`, modes,
  `UndoableIntent`, `IndexedEntity` and the Foundation Models path (runtime
  availability check).
- **27 (`@available`):** `SyncableEntity`, `allowedExecutionTargets` (writers
  `[.main, .widgetKitExtension]`), and `.appEntityIdentifier` on the topic
  tiles/record screen (cheap; future-proof if a schema appears).
  `.system.searchInApp` after M5.
- Not adopted: Visual Intelligence, `LongRunningIntent`, `RelevantEntities`.

### Testing

| Layer                                                           | Where                                                                                                                                                          |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Commit/validation/draft logic                                   | `swift test` (macOS), Core/Data unit tests                                                                                                                     |
| Intents end-to-end                                              | **AppIntentsTesting** XCUITest bundle (`IntentDefinitions(bundleIdentifier:)`, `makeIntent().run()`, `spotlightQuery`) [11]. Simulator first; device fallback. |
| Phrases                                                         | Xcode **App Shortcuts Preview** (phrase matching), then Siri on the simulator by typing to Siri                                                                |
| Snippets, Shortcuts app, prompts                                | Shortcuts app on the simulator (prompts appear as sheets)                                                                                                      |
| FM path                                                         | Simulator on an Apple silicon Mac with Apple Intelligence enabled; device for latency                                                                          |
| Siri voice, Siri AI, offline, Action button, multi-process soak | **Device only** (M4-DEV): airplane mode, app killed, 6-question topic timing                                                                                   |

### Changes to PLAN and DAG

- **§2 App Intents row:**
  - add `LogTopicIntent` (voice loop + `requestConfirmation` snippet + FM path),
    snippet intents, `WhatsDueIntent`;
  - move `IndexedEntity`, `UndoableIntent` and dependent option entities out of
    "deferred";
  - add "no App Schema; App Shortcuts only; iOS 27 extras behind `@available`".
- **02-architecture §8:** replace "Intent parameters are static… documented
  limitation" with §2. Note the Siri AI dialog/snippet caveat.
- **§11 limitation 5:** replace it with "Free-text answers are voice-only in
  Siri; snippets have no text fields. Siri AI (iOS 27) can't drive custom
  intents conversationally without a schema; none fits."
- **M4 validation:**
  - add "Siri: log a 3-question topic by voice, offline";
  - add "Snippet edit + confirm";
  - add "AI path on an AI device".
- **INTENTS WP:**
  - size M → **L**;
  - add a 1-day **spike first**: repeated `requestValue`, the 30 s budget with
    user waits, FM latency/rate-limit in the background, snippet re-perform
    cost;
  - depends on VAL and the record form's answer model;
  - adds the AppIntentsTesting target (needs the iOS 27 runtime).

## Sources

1. WWDC25 "Explore new advances in App Intents".
   https://developer.apple.com/videos/play/wwdc2025/275/
2. Apple, `SnippetIntent` (iOS 26.0).
   https://developer.apple.com/documentation/appintents/snippetintent
3. Apple, "Displaying static and interactive snippets".
   https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets
4. Apple, `supportedModes` (iOS 26.0).
   https://developer.apple.com/documentation/appintents/appintent/supportedmodes
5. WWDC26 "Explore advanced App Intents features for Siri and Apple
   Intelligence". https://developer.apple.com/videos/play/wwdc2026/343/
6. Apple, "App schema domains".
   https://developer.apple.com/documentation/appintents/app-schema-domains
7. Apple, "Making actions and content discoverable by Apple Intelligence".
   https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence
8. WWDC26 Apple Intelligence group lab (schemas enable multi-turn; App Shortcuts
   for the rest). https://developer.apple.com/videos/play/wwdc2026/8011/
9. Apple, Foundation Models: `DynamicGenerationSchema` (iOS 26.0) and
   `GenerationError.rateLimited` ("only… if your app is running in the
   background").
   https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema
   ·
   https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:)
10. WWDC26 "Discover new capabilities in the App Intents framework".
    https://developer.apple.com/videos/play/wwdc2026/345/
11. WWDC26 "Validate your App Intents adoption with AppIntentsTesting".
    https://developer.apple.com/videos/play/wwdc2026/295/
12. Apple Support, "Use Apple Intelligence in Shortcuts".
    https://support.apple.com/guide/shortcuts/tpg3vrvwmclv
13. WWDC26 "Build intelligent Siri experiences with App Schemas"; WWDC26 iOS
    guide. https://developer.apple.com/videos/play/wwdc2026/240/ ·
    https://developer.apple.com/wwdc26/guides/ios/
14. Apple, "Providing contextual cues to Apple Intelligence and Siri".
    https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri
15. Macworld/Cult of Mac on the iOS 26.4 Siri delays.
    https://www.cultofmac.com/news/ios-26-4-ai-siri-delays-problems
16. Apple Developer Forums 836572 (non-schema intents and Siri AI multi-turn;
    community answer). https://developer.apple.com/forums/thread/836572
17. Apple, `JournalIntent.createEntry`.
    https://developer.apple.com/documentation/appintents/assistantschemas/journalintent/createentry
18. Apple, "Journaling" domain.
    https://developer.apple.com/documentation/appintents/app-schema-domain-journaling
19. Reporting on the iOS 27 Siri architecture and device support (secondary).
    https://mer.vin/2026/06/apple-wwdc26-siri-ai-and-gemini-backed-foundation-models-on-device-and-private-cloud-compute/
20. Apple, `AppShortcutsProvider`.
    https://developer.apple.com/documentation/appintents/appshortcutsprovider
21. WWDC22 "Implement App Shortcuts with App Intents"; WWDC23 "Spotlight your
    app with App Shortcuts".
    https://developer.apple.com/videos/play/wwdc2022/10170/ ·
    https://developer.apple.com/videos/play/wwdc2023/10102/
22. Apple newsroom, WWDC26 developer tools.
    https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/


## Amendment (M1 SKEL findings, 2026-10-18)

- Declare App Intents once, in the static `QuickrData` package, and do **not** add an `AppIntentsPackage`. On iOS 26.0, linkd rejects the package include for a static library ("did not match any imported symbol") and drops every intent: no App Shortcuts, and widgets can't be configured. iOS 27 accepts it, so a 27 simulator hides the bug. Xcode merges the static library's metadata into each linking binary (app, widget, NSE).
- `AppIntentsTesting` can't load on the iOS 26 runtime. Its tests live in `QuickRIntentsTests` and run on iOS 27+ only.
- Set `ENABLE_DEBUG_DYLIB: NO` (Xcode 27): otherwise metadata extraction randomly skips.
- Read the topic source through `IntentTopicSource`, not `@Dependency`.

## Spike (INTENTS, 2026-10-20)

Measured on the iOS 27.0 simulator (Xcode 27.1) with DEBUG-only spike intents
(`App/Intents/Spike/IntentSpike.swift`) and opt-in tests
(`QuickRIntentsTests/IntentSpikeTests`, `TEST_RUNNER_QUICKR_INTENT_SPIKE=1`).
Timings come from the intents' own App Group log.

| #   | Question                                     | Finding                                                                                                                                                                                                                                                                                                                                                                                  | Consequence                                                                                                                                                                                                                                               |
| --- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | Repeated `requestValue` on one parameter     | **Works.** Run from the Shortcuts app, `$slot.requestValue` called 3 times in one `perform()` prompted 3 times and returned 3 values. The prompt is a system sheet over the running app (SpringBoard's tree, not the app's), and **its field is prefilled with the parameter's current value** (typing "2" after answering "1" gave 21).                                                     | One hidden slot parameter per type is enough (no `q1…q8`). Dialogs must name the question; the prefilled value is a default the user replaces (voice Siri replaces it).                                                                                   |
| S2  | Does waiting for the user count toward ~30 s | **No.** A 44.5 s wait before the second answer, 54.4 s in total, and the intent completed.                                                                                                                                                                                                                                                                                              | A multi-question loop is bounded by processing, not by how long the user takes.                                                                                                                                                                         |
| S3  | Processing budget                            | **30.0 s, enforced by cancellation.** Intents working 35 s and 65 s were cancelled at 30.03 s / 30.01 s (`Task.sleep` threw); the caller got `LNConnectionErrorDomain` 1014 "timeout". 10 s completed.                                                                                                                                                                                  | Each write intent commits the outbox item first and well inside 30 s; everything after the commit (flush, reload) is best-effort and cancellation-aware, as outbox.md §10 already says (4 s).                                                                |
| S4  | AppIntentsTesting and prompts                | **It can't answer them.** `run()` of a prompting intent fails at once: `AppIntentsServicesExecutionErrorDomain` 206 "requested value for parameter 'slot', which is not supported by AutoConfirmingPerformDelegate". It has no API for responses either.                                                                                                                                 | AppIntentsTesting covers entity queries and intents run with full values. The question loop, the draft and validation are plain QuickrData code with host tests; the prompting itself is checked in the Shortcuts app (S1's harness) and on device.   |
| S5  | Foundation Model latency and rate limits     | **Not measurable here.** `SystemLanguageModel.default.availability` on this Mac is `unavailable(modelNotReady)`, and the simulator uses the host's model. No latency or `rateLimited` data.                                                                                                                                                                                               | Ship the FM path behind the runtime availability check, falling back to the question loop on any non-`available` state or error. Latency and background rate limits move to **M4-DEV** (AI device).                                                     |
| S6  | New Siri not showing snippets/dialogs        | **Device only.** Siri AI needs iOS 27 on Apple Intelligence hardware; the simulator has neither.                                                                                                                                                                                                                                                                                      | As planned: every result's dialog text carries the outcome on its own. **M4-DEV** checks it.                                                                                                                                                             |

Still open for INTENTS itself (checked while building, in the Shortcuts app on
the simulator): `requestConfirmation(snippetIntent:)` and the cost of a
snippet's re-`perform()` after each tap.
