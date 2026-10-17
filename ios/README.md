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

| Target                      | Does                                                                                                      |
| --------------------------- | --------------------------------------------------------------------------------------------------------- |
| `make ios-gen`              | Generate `ios/quickR.xcodeproj`, the Info.plists and entitlements from `project.yml`                      |
| `make ios-build`            | Simulator Debug build                                                                                     |
| `make ios-core-test`        | `swift test` for `QuickrKit` on the Mac (fast; Core and Data only)                                        |
| `make ios-test`             | Unit test plan on the iOS 26.0 simulator                                                                  |
| `make ios-uitest`           | UI test plan on `IOS_SIM`                                                                                 |
| `make check-ios`            | The local gate: gen, swift test, Unit and UI plans on **both** simulators, lint, Xcode version            |
| `make ios-check-ci`         | What CI runs on a ready PR: gen, build and Unit plan with signing off (`IOS_SIM_CI`, default `iPhone 17`) |
| `make ios-sim-run`          | Build, install and launch; `URL=quickr://...` then opens a link                                           |
| `make ios-shots`            | Clean status bar, light and dark screenshots into `IOS_SHOTS` (default `docs/ios/demo/m0`)                |
| `make ios-demo-record`      | Record a launch and convert it to `IOS_GIF`                                                               |
| `make ios-lint` / `ios-fmt` | swift-format lint / format in place (config in `ios/.swift-format`)                                       |
| `make ios-clean`            | Remove the generated project and all build output                                                         |

Override the simulators with `IOS_SIM_MIN=... IOS_SIM_CUR=...`. Build output
goes to `ios/build/` (DerivedData in `build/dd`, package checkouts in
`build/spm`, test results in `build/results/<plan>-<udid>.xcresult`; read one
with `xcrun xcresulttool get test-results summary --path ...`).

`simctl openurl` with the `quickr://` scheme shows a system "Open in quickR?"
alert, which stays on screen until tapped. Reboot the simulator (or tap it)
before taking screenshots.

## Layout

```
ios/
  project.yml            XcodeGen spec: targets, entitlements, Info.plist keys, scheme, test plans
  Config/Shared.xcconfig optional-includes Local.xcconfig (DEVELOPMENT_TEAM etc.)
  QuickrKit/             Swift package (tools 6.2): QuickrCore, QuickrData, QuickrUI (iOS only) + tests
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

## CI

`.github/workflows/ios.yml` runs on `macos-26` with Xcode 26.6 pinned through
`DEVELOPER_DIR`, and downloads a pinned, checksummed xcodegen release. A push
runs `swift test`; a non-draft PR or a manual dispatch runs `make ios-check-ci`
(Unit plan on the oldest iOS 26.x "iPhone 17" simulator on the runner).

## Interactive loop

`.mobilebuildmcp/config.yaml` points MobileBuildMCP at `ios/quickR.xcodeproj`,
scheme `QuickR` and the `quickR iOS27` simulator. Run `make ios-gen` first. The
`make` targets stay the canonical, reproducible path.
