# M2 screens: shared brief

Read this before starting any M2 screen package (HOME, TILES, LINKS, SETTINGS,
RECORD, SYNC-UX, UIT-2). It collects the APIs that M1, WIRE and FORM provide,
plus the conventions every package follows. Package scopes are in
[DAG.md](../DAG.md) (§M2); PWA parity rules are in [PLAN.md](../PLAN.md).

## The session (WIRE)

Screens get the session from the environment:

```swift
@Environment(AppEnvironment.self) var env
let session = env.session   // AppSession, @MainActor @Observable
```

### Reading data (HOME, TILES)

Observations are keyed by `session.binding`, so they restart whenever the server
or store generation changes:

```swift
.task(id: session.binding) {
    guard let store = session.store else { return }
    for try await topics in store.observeTopics(refresh: session.refresh.stream()) { … }
}
```

- Other observations: `observeEntries(topicId:limit:refresh:)` and
  `observeOutbox(refresh:)`.
- Sync state for the pill: `session.syncStatus`, plus `session.phase`
  (`.starting`, `.noServer`, `.ready`, `.failed(String)`).

### Writing (TILES, RECORD)

Each call enqueues durably through `Outbox`, then requests a flush. It returns
only after the commit.

```swift
try await session.log(topic:answers:capturedAt:notes:version:origin:) -> UUID
try await session.update(entryId:topicId:patch:baseRevision:)
try await session.delete(entryId:topicId:undoable:)
try await session.undoDelete(entryId:)
try await session.undoLog(entryId:)
```

Errors:

- `SessionError.noStore` before onboarding;
- `OutboxError.entryDeleted` ("This entry was deleted"): show it, don't retry;
- `StoreError.retired`.

To send immediately (TILES's `sendNow`), use
`session.scheduler?.sendNow(itemId:wait:)` with 2.5 s or 8 s, per outbox.md.

### Settings and onboarding (SETTINGS)

- **Connect:** `await session.connect(baseURL:) -> ConnectResult`. It rebinds
  and rebuilds the sender.
- **Cloudflare Access:** credentials go through `AccessCredentialsProvider`,
  passed in `AppSession.Configuration(credentials:)` from `AppEnvironment.live`.
  SETTINGS adds the Keychain implementation; today it's a nil stub. Never store
  secrets in `AppSettings` or `UserDefaults`.
- **Reset:** `session.coordinator.resetWarning()`, then
  `performReset(confirmed:)`. The session follows via `.storeReset`.

### Sync UX (SYNC-UX)

- Pull to refresh: `session.coordinator.sync(reason: .pullToRefresh)`.
- Scene phases are already wired to `didBecomeActive()` and
  `didEnterBackground()`.
- Background refresh:
  1. `coordinator.sync(reason: .background)`;
  2. then `scheduler?.flushNow(reason: .backgroundRefresh)`;
  3. with `backgroundTimeExpiring(within:)` in the expiration handler.
- `NWPathMonitor` should call `scheduler?.requestFlush(.networkAvailable)`.

## The form (FORM)

`QuickrUI/Form` provides:

- `FormModel(questions:mode:)`, with modes `.create(last:)`,
  `.fix(answers:problem:)` and `.edit(answers:)`;
- `FormView(model:onAutoSave:footer:)`;
- `AnswerField`.

`onAutoSave` is async and returns a `Bool`; the chips stay disabled until it
returns. `submit()` returns the body. Its notes for RECORD, EDIT and TILES are
in FORM's report, summarized here:

- RECORD builds `FormModel(.create(last:))`, shows `metaErrors` in Details and
  validates meta with `EntryMetaValidation`.
- At accessibility text sizes, hide the sticky Save bar while the keyboard is
  up.

## Design system (DS)

Use the `QuickrUI` tokens, controls (ChipGrid, NumberStepper, toast) and tiles.

- Light and dark mode; Dynamic Type up to the AX sizes.
- `NumberStepper` needs `@ScaledMetric` unit padding (backlog). Fix it if TILES
  touches it.

## Conventions every package follows

- **Worktree and branch:** `ios/m2-<pkg>`, cut from `ios/m2-ui`. Never push.
  Report SHAs to the lead.
- **Builds:** `-jobs 4` / `--jobs 4`, which is the default through the scripts.
- **Simulators:** boot only through the scripts. The cap is 2 machine-wide; use
  `IOS_SIM_WAIT=1` to queue. Shut your clone down when you finish.
- **Tests:**
  - Host tests go under `swift test`, which runs with the STRICT pool. Never
    block a pool thread: no semaphores, `sync`-into-async, or `Thread.sleep` in
    async code.
  - Real-time bounds go under `TimingTests`, which runs only with
    `QUICKR_TIMING_TESTS=1`.
  - Bound every wait (`eventually` or `within`), so a regression fails instead
    of hanging.
- **Accessibility:** every screen has accessibility identifiers, VoiceOver
  labels and an AX-size check (one UI test at XXXL).
- **Parity:** match the PWA's behaviour. Where iOS deviates on purpose, list
  each deviation in your report.
- **Demo:** light and dark screenshots into `docs/ios/demo/m2/<pkg>-*.png`. Look
  at them before reporting.
- **Gates:** `make ios-core-test`, `ios-lint` and `check-ios` on one 26.0 clone
  (or its steps). If you touch data paths, also run `make ios-integration`.
- **Codex** reviews every package, so mutation-check your key logic.
