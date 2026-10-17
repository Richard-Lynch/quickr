# quickR for iOS

The native SwiftUI app. Plans and decisions are in `docs/ios/` (start with
`PLAN.md`); this file covers building, testing and running.

## Requirements

- **Xcode 27.x** selected (`xcode-select -p`). The deployment target is iOS 26.0
  and the code uses no iOS 27-only API, so CI's Xcode 26.6 builds the same
  sources.
- **xcodegen** (`brew install xcodegen`); `xcbeautify` and `ffmpeg` are
  optional.
- Two simulators, both iPhone 17: **`quickR iOS-26-0`** (iOS 26.0, the minimum)
  and **`quickR iOS27`** (iOS 27.0). Create them if missing, for example
  `xcrun simctl create "quickR iOS-26-0" "iPhone 17" com.apple.CoreSimulator.SimRuntime.iOS-26-0`.

Every `make ios-*` target first checks that `xcodebuild -version` works and that
`xcodegen` exists, and stops with a clear message if not. `make check` (backend
and PWA) never needs Xcode.

No Apple Developer team is needed for simulator work. For device builds later,
copy `Local.xcconfig.example` to `Local.xcconfig` (gitignored) and set
`DEVELOPMENT_TEAM`.

## Make targets

Run from the repo root. `IOS_SIM` (default `quickR iOS-26-0`) takes a simulator
name or UDID.

| Target                      | Does                                                                                                                                                                                          |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make ios-gen`              | Generate `ios/quickR.xcodeproj`, the Info.plists and entitlements from `project.yml`                                                                                                          |
| `make ios-build`            | Simulator Debug build                                                                                                                                                                         |
| `make ios-core-test`        | `swift test` for `QuickrKit` on the Mac (fast; Core and Data only)                                                                                                                            |
| `make ios-test`             | Unit test plan on the iOS 26.0 simulator                                                                                                                                                      |
| `make ios-uitest`           | UI test plan on `IOS_SIM`                                                                                                                                                                     |
| `make check-ios`            | The local gate: gen, swift test, Unit and UI plans on **both** simulators, lint, Xcode version                                                                                                |
| `make ios-check-ci`         | What CI runs on a ready PR: gen, build and Unit plan with signing off, on an iPhone with an **iOS 26.x** runtime (fails if none; `IOS_SIM_CI` picks the preferred model, default `iPhone 17`) |
| `make ios-sim-run`          | Build, install and launch; `URL=quickr://...` then opens a link                                                                                                                               |
| `make ios-shots`            | Clean status bar, light and dark screenshots into `IOS_SHOTS` (default `docs/ios/demo/m0`)                                                                                                    |
| `make ios-demo-record`      | Record a launch and convert it to `IOS_GIF`                                                                                                                                                   |
| `make ios-lint` / `ios-fmt` | swift-format lint / format in place (config in `ios/.swift-format`). `check-ios` fails without swift-format; `ios-lint` only warns                                                            |
| `make ios-resolve`          | Update the package pins (see below)                                                                                                                                                           |
| `make ios-clean`            | Remove the generated project and all build output                                                                                                                                             |

Override the simulators with `IOS_SIM_MIN=... IOS_SIM_CUR=...`. Build output
goes to `ios/build/` (DerivedData in `build/dd`, package checkouts in
`build/spm`, test results in `build/results/<plan>-<udid>.xcresult`; read one
with `xcrun xcresulttool get test-results summary --path ...`).

`simctl openurl` with the `quickr://` scheme shows a system "Open in quickR?"
alert, which stays on screen until tapped. Reboot the simulator (or tap it)
before taking screenshots.

## Package versions

Once `QuickrKit` has remote dependencies (GRDB in M1), **one** lockfile is tracked:
`ios/QuickrKit/Package.resolved`. Host SwiftPM (`swift test`) and Xcode both resolve from it:

- Xcode 27 seeds its resolution from a local package's lockfile. Verified with a GRDB probe: it
  checked out the pinned older version, not the newest match.
- `make ios-gen` also copies it into the generated, gitignored
  `quickR.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Builds run with `-onlyUsePackageVersionsFromResolvedFile` and `swift test` with
  `--only-use-versions-from-resolved-file`, so a pin that no longer satisfies `Package.swift`
  fails the build instead of silently moving.
- After the Xcode runs, `check-ios` and `ios-check-ci` check that Xcode's workspace pins still
  match the tracked file (`scripts/resolved-check.sh`).

To add or bump a dependency, edit `QuickrKit/Package.swift`, run `make ios-resolve` (it runs
`swift package update`, regenerates, and checks that Xcode resolves to the same pins), then
commit `ios/QuickrKit/Package.resolved`.

## Layout

```
ios/
  project.yml            XcodeGen spec: targets, entitlements, Info.plist keys, scheme, test plans
  Config/Shared.xcconfig optional-includes Local.xcconfig (DEVELOPMENT_TEAM etc.)
  QuickrKit/             Swift package (tools 6.2): QuickrCore, QuickrData, QuickrUI (iOS only),
                         QuickrTestSupport and ProcessHelper (test-only) + tests
  App/                   QuickR app target (bundle id com.bahumia.quickr)
  AppTests/              QuickRTests (unit, hosted in the app)
  UITests/               QuickRUITests
  Widgets/               QuickRWidgets extension (com.bahumia.quickr.widgets)
  NotificationService/   QuickRNotificationService (com.bahumia.quickr.notification-service)
  TestPlans/             Unit.xctestplan (app + package tests), UI.xctestplan
  scripts/               the shell behind `make ios-*`
```

Generated and gitignored: `quickR.xcodeproj`, the targets' `Info.plist` and
`.entitlements` files, `build/`, `Local.xcconfig`. Edit `project.yml`, then
`make ios-gen`.

The app and both extensions share the App Group `group.com.bahumia.quickr` and
the keychain group `$(AppIdentifierPrefix)com.bahumia.quickr.shared`.
`aps-environment` is added in M3.

The test plans reference targets by XcodeGen's deterministic ids. If a test
target is renamed or added, regenerate and update the `identifier` in the
`.xctestplan` from `project.pbxproj`.

## Data layer: Swift 6 and GRDB

`QuickrData` uses GRDB 7 (pinned in `QuickrKit/Package.resolved`). The app, the widget extension
and the NSE all link it; each has a `StoreLink.swift` that opens a pool and reads through a
repository, and `QuickRTests` runs the app's copy on the simulator. The rules, so the three
processes and every work package use one pattern:

- **Connections.** One `DatabasePool` (WAL) per store file per process, opened with
  `StoreDatabase.openPool(at:)` and its `configuration(label:)` (busy timeout for the other
  processes). `DatabasePool`, `DatabaseQueue` and `any DatabaseReader`/`DatabaseWriter` are
  `Sendable`, so a pool can be shared by any actor or task. Tests use
  `TestDatabase.store()`/`registry()` (in-memory, real migrators); multi-process tests use files.
- **Repositories** are `Sendable` structs holding `any DatabaseReader` (or `DatabaseWriter`),
  behind the protocols in `QuickrData/Contracts/Repositories.swift`. Their methods are `async`
  and call `try await reader.read { db in ... }` / `writer.write { db in ... }`: the database work
  runs on GRDB's own queue, never on the caller's executor (in particular not the main actor).
  `GRDBSyncStateRepository` is the template.
- **Values out, never records or rows.** Closures build `Sendable` value types (QuickrCore models,
  `StoreRecords`) inside the read and return them. `Row`, `Database` and statements never escape
  a closure.
- **No awaits inside a transaction.** A closure passed to `read`/`write` is synchronous; network
  calls, lease waits and `UNUserNotificationCenter` calls happen before or after it
  (sync-protocol.md §5.2 rule 3). The one exception is the synchronous
  `setNotificationCategories`, called inside the registry write (notifications.md §5.2).
- **Columns.** Instants are `REAL` Unix seconds, converted with
  `Date(timeIntervalSince1970:)` (never GRDB's default `Date` string encoding); lease-time
  deadlines are `(boot_id, ct)` pairs; ids are lowercase UUID strings (`UUID.wireString`). The
  schema and its conventions are in `StoreSchema.swift` (store) and the same file's
  `RegistrySchema` (registry).
- **Migrations** are `StoreSchema.migrator()` and `RegistrySchema.migrator()`; any process may run
  them. They are append-only once a build ships.

API contracts live next to the schema: wire DTOs (`*DTO.swift`, explicit `CodingKeys`, no key
strategy), `WireCoding` (dates in with 0–6 fractional digits and `Z` or an offset, out as UTC with
`+00:00`), and the `Endpoints` table keyed by `operationId`. `FixtureCoverageTests` decodes every
`shared/fixtures/api/*.json` through it, so a new fixture without a DTO fails `swift test`.

`QuickrTestSupport` (test targets only) has `Fixtures` (reads `shared/fixtures` from the checkout
via `#filePath`, on the Mac and the simulator; `QUICKR_FIXTURES_DIR` overrides), `FakeTransport`,
`FakeClock`, `FakeLeaseClock`, `FakeNotificationCenter` and `TestDatabase`. `ProcessHelper` is the
child process for the multi-process tests (`swift run ProcessHelper version`).

## CI

`.github/workflows/ios.yml` runs on `macos-26` with Xcode 26.6 pinned through
`DEVELOPER_DIR`, and downloads a pinned, checksummed xcodegen release. A push
runs `swift test`; a non-draft PR or a manual dispatch runs `make ios-check-ci`
(Unit plan on an "iPhone 17" simulator with an iOS 26.x runtime, the oldest one available;
`ios/scripts/sim-ios26.sh` fails the job if the runner has none).

## Interactive loop

`.mobilebuildmcp/config.yaml` points MobileBuildMCP at `ios/quickR.xcodeproj`,
scheme `QuickR` and the `quickR iOS27` simulator. Run `make ios-gen` first. The
`make` targets stay the canonical, reproducible path.
