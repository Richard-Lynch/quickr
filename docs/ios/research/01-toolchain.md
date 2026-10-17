# Research 01: toolchain, project structure, build/sign/install, CI, demo capture

Researched 2026-10-17. Sources are listed at the end and referenced as [n].

## Recommendations

1. **Upgrade this Mac to macOS Tahoe 26.6+ before installing Xcode.** It is on
   **macOS 15.6.1**. Xcode 26.4 and later need Tahoe 26.2+, Xcode 27 (shipped
   2026-09-14, Swift 6.4) needs Tahoe 26.6+. On Sequoia the newest option is
   **Xcode 26.3** (iOS 26.2 SDK) [1][2]. That is enough for the simulator, but
   it probably can't deploy to a phone that already runs iOS 27. Target: **Xcode
   27.1** on Tahoe. Fallback: Xcode 26.3 for simulator-only work.
2. **Project generation: XcodeGen (2.46.0)** [3]. Commit `ios/project.yml`.
   Gitignore `*.xcodeproj`. Put most code in a **local SwiftPM package**
   (`ios/Packages/QuickRKit`). The app and its extensions become thin shells.
3. **Build and test with plain `xcodebuild` plus `simctl`/`devicectl`, driven by
   `make ios-*`.** No fastlane. Upload to TestFlight with
   `xcodebuild -exportArchive` (`destination=upload`) and an App Store Connect
   API key [4]. That also makes signing headless.
4. **APNs: one token-based `.p8` key with environment "Sandbox & Production"**
   [5]. Store the environment per device token on the backend.
5. **CI: a separate `.github/workflows/ios.yml` on `macos-26`, path-filtered to
   `ios/**`.** It runs a build and the unit tests only, with no signing. The
   repo is **private**, so macOS minutes cost $0.062/min, counted at a 10× rate
   against included minutes [6][7]. Keep the job short.
6. **Dependencies:** swift-openapi-generator 1.14.1, swift-openapi-runtime
   1.13.1 and swift-openapi-urlsession 1.3.2 [8]. Run the generator as a **CLI
   step with committed output**, not as a build plugin. Add GRDB 7.11.1 if the
   architecture agent picks SQLite over SwiftData. Add swift-snapshot-testing
   1.19.6 as a test-only dependency. Nothing else.
7. **Fonts:** all three are OFL 1.1. Bundle **static instances** cut from the
   variable fonts with `fonttools` (a scripted step), and register them through
   `UIAppFonts`.
8. **App icon:** script 1024 px PNGs (light, dark, tinted) from `favicon.svg`
   with `rsvg-convert` into an asset catalog. A layered `.icon` file made in
   Icon Composer is optional polish and needs a human with the GUI.

## 1. Project generation

| Option            | Diff-friendly                         | Agent-editable                                         | Notes                                                                                                        |
| ----------------- | ------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| **XcodeGen**      | YAML, about 150 lines                 | Yes, and it generates Info.plists and `.entitlements`  | Synced-folder support (2.44+, fixed in 2.45.x) [3]. Mature and boring. Install with `brew install xcodegen`. |
| Tuist             | Swift manifests                       | Yes, but needs `tuist edit`/compile; heavier toolchain | Its paid server features don't matter here. Weekly churn (4.214 canary). More moving parts than we need.     |
| Pure `.xcodeproj` | `project.pbxproj` churn and conflicts | Poor: agents hand-editing pbxproj is fragile           | Synced folders reduce churn, but adding targets or capabilities still means editing pbxproj.                 |
| SwiftPM only      | Excellent                             | Excellent                                              | Can't declare app or app-extension targets, entitlements or App Groups. So it needs a host project anyway.   |

**Layout:**

```
ios/
  project.yml                 # XcodeGen spec (only checked-in project source)
  Packages/QuickRKit/         # Package.swift: QuickRCore (models, due logic, validation),
                              #   QuickRAPI (generated client + transport), QuickRStore (offline store/outbox),
                              #   QuickRUI (brand, components), QuickRIntents (shared AppIntents)
  App/                        # @main, screens wiring, Assets.xcassets, Fonts/
  Widgets/                    # WidgetKit + interactive AppIntents (com.bahumia.quickr.widgets)
  NotificationContent/        # optional UNNotificationContentExtension (answer UI)
  Tests/Unit/  Tests/UI/      # XCTest/Swift Testing + XCUITest
  TestPlans/Unit.xctestplan  TestPlans/UI.xctestplan
  scripts/                    # icon/fonts/openapi/demo helpers
```

- In `project.yml`, set `entitlements:` for the app and widget targets with
  `com.apple.security.application-groups: [group.com.bahumia.quickr]`. The app
  target also gets `aps-environment: development`. Set
  `DEVELOPMENT_TEAM: $(QUICKR_TEAM_ID)` from an uncommitted `.xcconfig`.
- Notification answer actions work through `UNNotificationCategory` actions in
  the app itself. A content extension is needed only for custom answer UI. A
  service extension isn't needed unless the server sends mutable content.
- Give `QuickRCore` the platforms `.iOS(.v26), .macOS(.v15)`. Then `swift test`
  runs the pure logic on this Mac now, with only the Command Line Tools (CLT
  16.4, Swift 6.1.2), before Xcode exists. **Verify** that Swift Testing or
  XCTest is available under the CLT. If it isn't, that work waits for Xcode.

## 2. Simulator CLI flow

```bash
cd ios && xcodegen generate                         # deterministic; run before every build
SIM="iPhone 17"; DEST="platform=iOS Simulator,name=$SIM,OS=latest"
xcodebuild -project quickR.xcodeproj -scheme quickR -destination "$DEST" \
  -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm build | xcbeautify  # optional formatter
xcodebuild test -project quickR.xcodeproj -scheme quickR -testPlan Unit -destination "$DEST" \
  -derivedDataPath build/dd -resultBundlePath build/Unit.xcresult
xcodebuild test ... -only-testing:QuickRTests/DueLogicTests        # one class (or /testMethod)
xcodebuild build-for-testing ... ; xcodebuild test-without-building ...  # split for speed
xcrun xcresulttool get test-results summary --path build/Unit.xcresult   # machine-readable result

xcrun simctl bootstatus "$SIM" -b                   # boot and wait
xcrun simctl install "$SIM" build/dd/Build/Products/Debug-iphonesimulator/quickR.app
xcrun simctl launch "$SIM" com.bahumia.quickr
xcrun simctl openurl "$SIM" "quickr://t/water/record"          # deep link (custom scheme)
xcrun simctl push "$SIM" com.bahumia.quickr scripts/push-due.apns  # JSON {"aps":{...},"topic_slug":"water"}
```

- `simctl push` takes a JSON file. A top-level `"Simulator Target Bundle"` key
  lets you omit the bundle ID [9]. On Apple-silicon Macs the simulator also
  receives **real sandbox APNs tokens**, so the backend's sandbox path can be
  tested end to end without a device.
- To get the simulator runtime with Xcode 26 or later:
  `xcodebuild -downloadPlatform iOS`.

**Clean screenshots and demos:**

```bash
xcrun simctl ui "$SIM" appearance dark                  # or light
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork wifi
xcrun simctl io "$SIM" screenshot --mask=black docs/ios/demo/home-dark.png
xcrun simctl io "$SIM" recordVideo --codec=h264 --mask=black --force build/demo.mp4 & REC=$!
#   ... drive the flow (XCUITest run, or openurl/push sequence) ...
kill -INT $REC; wait $REC                               # SIGINT finalises the mp4
ffmpeg -y -i build/demo.mp4 -vf "fps=15,scale=360:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" docs/ios/demo/flow.gif
xcrun simctl status_bar "$SIM" clear
```

`ffmpeg` and `rsvg-convert` are already installed via Homebrew. For scripted
demo flows, the best driver is an XCUITest "demo" test plan run while
`recordVideo` captures it. That gives a repeatable flow and repeatable GIFs.
Notification permission can't be pre-granted through `simctl privacy`, so UI
tests should accept the SpringBoard alert (an interruption monitor).

## 3. Device install and distribution

**Development install (terminal only, after the one-time GUI steps):**

```bash
xcodebuild -project quickR.xcodeproj -scheme quickR -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=$QUICKR_TEAM_ID build
xcrun devicectl list devices --json-output build/devices.json         # parse JSON, not text [10]
xcrun devicectl device install app --device "$QUICKR_DEVICE" build/dd/Build/Products/Debug-iphoneos/quickR.app
xcrun devicectl device process launch --device "$QUICKR_DEVICE" --terminate-existing com.bahumia.quickr
```

- `devicectl manage pair` pairs a cabled device [10]. After the first cabled
  pairing, the device can be reached over Wi-Fi on the same network. Turn on
  "Connect via network" in Xcode's devices window (called Device Hub in Xcode
  27).
- The device must be unlocked for `devicectl` commands.
- **Developer Mode:** Settings → Privacy & Security → Developer Mode. The toggle
  appears only after the phone has been connected to Xcode, and turning it on
  needs a reboot.
- **Automatic signing:** `-allowProvisioningUpdates` creates or renews the
  certificate, the App IDs (app and widgets), the App Group and the profiles. It
  also turns on the Push and App Groups capabilities from the `.entitlements`
  file. It needs **either** an Apple ID signed in through Xcode ▸ Settings ▸
  Accounts (a one-time GUI step) **or** the
  `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` flags
  with an ASC API key, which is fully headless [11].
- Recommendation: do the Xcode sign-in once, because that also makes local
  device builds smooth. Use the API key for TestFlight uploads.

**TestFlight (headless):**

```bash
xcodebuild archive -scheme quickR -destination 'generic/platform=iOS' -archivePath build/quickR.xcarchive \
  -allowProvisioningUpdates $ASC_AUTH_FLAGS
xcodebuild -exportArchive -archivePath build/quickR.xcarchive -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates $ASC_AUTH_FLAGS
# ExportOptions.plist: method=app-store-connect, destination=upload, teamID, signingStyle=automatic
```

- `notarytool` is for macOS only.
- `altool --upload-app` is deprecated in favour of `--upload-package`, but
  `altool` is still the supported upload CLI [12].
- `-exportArchive` with `destination=upload` (Xcode 15+) is simpler [4], so use
  `altool` only as the fallback.
- Bump `CURRENT_PROJECT_VERSION` per upload. A good scheme is
  `$(git rev-list --count HEAD)` passed on the command line.
- **fastlane: no** (2.241.1 exists). Nothing it does here (`match`, `pilot`) is
  missing from about 20 lines of shell.

**Free personal team (before enrollment):** simulator work is fully
unrestricted. Device installs are possible, with these limits:

- Profiles expire after 7 days.
- No Push Notifications capability [13].
- App Groups are unreliable.
- Small App ID quotas.

So the free team can only usefully run an **app-only** build without push or the
widget. Not worth wiring up. Plan for simulator-only until enrollment.

## 4. APNs auth key (user steps)

1. Go to developer.apple.com → Certificates, IDs & Profiles → **Keys** → **+**.
   Name it "quickR APNs" and tick **Apple Push Notifications service (APNs)**.
2. Configure: Environment **Sandbox & Production**. Key restriction: **Team
   Scoped**, or Topic Specific for `com.bahumia.quickr` [5].
3. Download `AuthKey_<KEYID>.p8`. **It can only be downloaded once.** Record the
   Key ID and the Team ID.
4. Give it to the backend as secrets (path or contents, key ID, team ID, topic
   `com.bahumia.quickr`). Never commit it.

**Which builds hit which APNs host:**

| Build                                                               | `aps-environment` | APNs host                    |
| ------------------------------------------------------------------- | ----------------- | ---------------------------- |
| Simulator, Xcode/devicectl Debug installs (development profile)     | `development`     | `api.sandbox.push.apple.com` |
| TestFlight and App Store (distribution profile; export rewrites it) | `production`      | `api.push.apple.com`         |

The app should send its environment along with its token. The backend sends to
the matching host and drops tokens that come back with
`BadDeviceToken`/`Unregistered`.

## 5. GitHub Actions

- The `macos-26` (arm64) image (2026-09-07) has Xcode 26.0.1–**26.6 (default)**,
  with iOS 26.2, 26.4 and 26.5 simulators (iPhone 17 and others) [14].
- Xcode 27 was published as a separate `xcode-27` image label (preview, July)
  [15]. **Re-check before relying on it.**
- Pin the Xcode version explicitly so local and CI builds match.
- **Cost:** a private repo is charged $0.062/min. Included minutes count at 10×
  (Free plan: 2,000 included = about 200 macOS minutes a month) [6][7]. Target
  under 8 minutes a run and cancel superseded runs.

```yaml
# .github/workflows/ios.yml
name: iOS
on:
  pull_request:
    paths: ["ios/**", "openapi.json", ".github/workflows/ios.yml"]
  push:
    branches: [main, feat/ios-app]
    paths: ["ios/**", "openapi.json", ".github/workflows/ios.yml"]
concurrency: { group: ios-${{ github.ref }}, cancel-in-progress: true }
permissions: { contents: read }
jobs:
  ios:
    runs-on: macos-26
    timeout-minutes: 30
    env: { DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer }  # match local
    steps:
      - uses: actions/checkout@<sha>
      - run: brew install xcodegen
      - uses: actions/cache@<sha>
        with:
          path: ios/build/spm
          key: spm-${{ hashFiles('ios/**/Package.resolved') }}
      - run: make ios-check-ci   # xcodegen generate + openapi drift check + build-for-testing + Unit test plan
        env: { CODE_SIGNING_ALLOWED: "NO" }
```

- Path-filtered workflows report "pending" if they are made a _required_ check.
  If branch protection needs them, use a `dorny/paths-filter` job inside an
  always-run workflow instead.
- Add the existing generated-client drift idea: CI regenerates the Swift client
  from `openapi.json` and fails on `git diff`.

## 6. Dependency policy (toolchain view)

- **Generated API client:** run the swift-openapi-generator CLI, for example
  `swift run --package-path ios/Tools swift-openapi-generator generate ...`.
  Commit the output, mirroring `make client`.
  - This avoids the build plugin's trust prompt and
    `-skipPackagePluginValidation` in CI, and it keeps builds fast.
  - The scouting hazards (`answers` map, `anyOf` values) still need either spec
    tweaks or hand-written types for those schemas.
- GRDB 7.11.1 only if it's chosen for the store. swift-snapshot-testing 1.19.6,
  test-only, for brand and dark-mode regressions.
- Formatting and linting: **swift-format** (ships with the Xcode 16+ toolchain,
  run as `swift format`) avoids another install. SwiftFormat 0.64 and SwiftLint
  0.65.1 are optional.
- **Tools, not packages:** XcodeGen (brew), `xcbeautify` (brew, optional),
  `xcodes` 2.1.0 (optional, for installing pinned Xcode versions).

## 7. Fonts

- Bricolage Grotesque, Instrument Sans and JetBrains Mono are all **SIL OFL
  1.1** [16]. Bundling them in an app is allowed.
  - Ship `OFL.txt` (in-app Acknowledgements plus `ios/App/Fonts/LICENSES/`).
  - Don't sell the fonts on their own.
  - Check each `OFL.txt` for a Reserved Font Name. If a font has one, a modified
    (instanced or subset) file must not keep that name.
- Variable fonts register fine through `UIAppFonts`. But SwiftUI's `.fontWeight`
  doesn't reliably drive a custom font's `wght` axis, and Bricolage also has
  `opsz` and `wdth` axes. Selecting an axis value needs CoreText variation
  attributes [17].
- **Recommendation:** script static instances with
  `uvx fonttools varLib.instancer` for the weights we use (for example Bricolage
  600/700, Instrument Sans 400/500/600, JetBrains Mono 400/600). List them in
  `UIAppFonts` through `project.yml` `info.properties`. Wrap them in a
  `Font.brand(.title)` helper that uses `Font.custom(name, size:, relativeTo:)`
  so Dynamic Type works.
  - Source TTFs come from the Google Fonts repo (the `@fontsource` packages only
    ship woff2).

## 8. App icon

- **Scriptable path (recommended):**
  1. Make a full-bleed variant of `favicon.svg`: drop `rx="116"`, because iOS
     masks the corners itself.
  2. Render it:
     `rsvg-convert -w 1024 -h 1024 icon.svg | magick - -alpha off AppIcon-1024.png`.
  3. Produce dark (dark background, orange glyph) and tinted (grayscale glyph on
     transparent) variants.
  4. Write `Assets.xcassets/AppIcon.appiconset/Contents.json` with the single
     universal 1024 size and luminosity appearances.
- **Icon Composer `.icon`** (Xcode 26+) gives true Liquid Glass layers. Xcode
  renders every size from it at build time, and the target's App Icon name must
  match the file name [18].
  - Its `ictool` CLI (inside Icon Composer.app) only _exports previews_ [19].
  - Authoring is a GUI job: import the SVG layers. The JSON format is
    undocumented.
  - Treat it as optional polish done by a human. Keep the asset catalog as the
    fallback.

## 9. Makefile targets

Add to the root `Makefile`, with logic in `ios/scripts/*.sh`. Every target first
runs a guard:

```make
IOS := cd ios &&
define need_xcode
	@xcodebuild -version >/dev/null 2>&1 || { echo "ios: full Xcode not found (xcode-select -p = $$(xcode-select -p)). Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch"; exit 1; }
	@command -v xcodegen >/dev/null || { echo "ios: brew install xcodegen"; exit 1; }
endef
```

`xcodebuild` exists as a CLT stub that errors, so the check must run `-version`,
not just look for the command.

| Target               | Does                                                                                                                                                                                 |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ios-gen`            | `xcodegen generate` (needs only xcodegen, no Xcode)                                                                                                                                  |
| `ios-client`         | Regenerate the Swift OpenAPI client from `openapi.json`                                                                                                                              |
| `ios-core-test`      | `swift test --package-path ios/Packages/QuickRKit --filter QuickRCore` (CLT-only, macOS host)                                                                                        |
| `ios-build`          | Simulator Debug build                                                                                                                                                                |
| `ios-test`           | `Unit` test plan on the simulator                                                                                                                                                    |
| `ios-uitest`         | `UI` test plan                                                                                                                                                                       |
| `check-ios`          | gen, client drift check, format lint, build, Unit and UI. This is the local gate.                                                                                                    |
| `ios-check-ci`       | Same as `check-ios` without UI tests and with `CODE_SIGNING_ALLOWED=NO`                                                                                                              |
| `ios-sim-run`        | Boot, install, launch. `URL=` runs `openurl`.                                                                                                                                        |
| `ios-push`           | `simctl push` with `P=scripts/push/*.apns`                                                                                                                                           |
| `ios-shots`          | Status-bar override plus light and dark screenshots into `docs/ios/demo/`                                                                                                            |
| `ios-demo-record`    | `recordVideo` around the `Demo` test plan, then ffmpeg to GIF                                                                                                                        |
| `ios-device-install` | Device build with `-allowProvisioningUpdates`, then `devicectl` install and launch. Reads `QUICKR_TEAM_ID` and `QUICKR_DEVICE` from `ios/Local.xcconfig` or `.env.ios` (gitignored). |
| `ios-testflight`     | Archive, then export with upload (needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`)                                                                                               |
| `ios-icons`          | Generate the icons above                                                                                                                                                             |
| `ios-fonts`          | Generate the font instances                                                                                                                                                          |

Keep the existing `check` as backend plus frontend. Don't add `check-ios` to it,
so `make check` keeps working on machines without Xcode.

## 10. Human steps and what blocks on them

| #   | Step                                                                                                                                                                                                                             | Needed by                                                                    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| H1  | **Upgrade macOS to Tahoe 26.6+.** Otherwise accept Xcode 26.3 and simulator-only work.                                                                                                                                           | Before H2                                                                    |
| H2  | **Install Xcode** (App Store or xcodes): `sudo xcode-select -s /Applications/Xcode.app`, `sudo xcodebuild -license accept`, `sudo xcodebuild -runFirstLaunch`, `xcodebuild -downloadPlatform iOS`. Also `brew install xcodegen`. | **M0/M1: any iOS build** (simulator)                                         |
| H3  | **Enroll in the Apple Developer Program** (individual). Approval takes from hours to about 2 days. Note the Team ID.                                                                                                             | Device installs with push and widgets, APNs, TestFlight                      |
| H4  | **Sign in to Xcode ▸ Settings ▸ Accounts** with the enrolled Apple ID (GUI, once).                                                                                                                                               | First device build                                                           |
| H5  | **Phone:** cable it in, tap "Trust", turn on Developer Mode and reboot, keep it unlocked. Optionally enable "Connect via network". Tell Claude the phone's iOS version.                                                          | Device milestone                                                             |
| H6  | **APNs `.p8` key** (section 4). Place it outside the repo.                                                                                                                                                                       | Server-sent push on a device (the simulator can use sandbox once H3 is done) |
| H7  | **App Store Connect:** create the app record (`com.bahumia.quickr`). Users and Access ▸ Integrations ▸ **Team API key** (App Manager role). Download `AuthKey_*.p8` once and note the Key ID and Issuer ID.                      | TestFlight milestone                                                         |
| H8  | **Cloudflare:** tunnel, Access application, service token (client ID and secret) for the app.                                                                                                                                    | Remote hosting milestone                                                     |
| H9  | (Optional) Icon Composer layered icon. Repo secrets for any future signed CI.                                                                                                                                                    | Polish                                                                       |

**Before Xcode (now):** write `project.yml`, the package and all Swift code. Run
`swift build`/`swift test` on the macOS-compatible core with the CLT. Write the
scripts, icons, fonts and CI YAML. The CI job can be the _first real compile_:
push the branch and let `macos-26` build it.

**After Xcode, before enrollment:** everything in the simulator, including UI
tests, deep links, widgets in the simulator, `simctl push`, demos and GIFs.

**After enrollment:** device installs, real APNs and TestFlight.

## Open risks

- **macOS 15.6.1 vs the Xcode requirements.** Xcode 26.3 may not deploy to an
  iPhone on iOS 27. Unverified; it depends on device-support files. The fix is
  H1.
- Local and CI Xcode versions can drift (CI defaults to 26.6, local might be 27
  or 26.3). Pin `DEVELOPER_DIR` in CI and assert the version in
  `make check-ios`.
- Whether Swift Testing is available under the CLT is unverified, and so is
  `Font.custom` axis support. Verify both when the code is first compiled.
- Private-repo macOS minutes cost 10×. A chatty CI could use up the free
  allowance.

## Sources

1. Apple, Xcode system requirements table —
   https://developer.apple.com/support/xcode/ ;
   https://developer.apple.com/xcode/system-requirements
2. B. Crosley, "Xcode 27 Is Out: Requirements, Targets, and What Broke"
   (2026-09) — https://blakecrosley.com/blog/xcode-27-release
3. XcodeGen releases 2.44–2.46.0 —
   https://github.com/yonaskolb/XcodeGen/releases
4. Devin docs, TestFlight via xcodebuild + ASC key —
   https://docs.devin.ai/onboard-devin/environment/testflight.md ; Apple forum
   https://developer.apple.com/forums/thread/742458
5. APNs key environment/restriction options —
   https://docs.mattermost.com/developers/contribute/more-info/mobile/push-notifications/ios
   ; https://support.pushy.me/hc/en-us/articles/360055971272
6. GitHub, Actions runner pricing —
   https://docs.github.com/en/billing/reference/actions-runner-pricing
7. GitHub, Actions billing —
   https://docs.github.com/en/billing/concepts/product-billing/github-actions ;
   Bitrise 2026 runner pricing —
   https://bitrise.io/blog/post/best-github-actions-runners-in-2026-and-hidden-pricing-traps-to-avoid
8. Latest releases via GitHub API (2026-10-17): apple/swift-openapi-generator,
   -runtime, -urlsession; groue/GRDB.swift; pointfreeco/swift-snapshot-testing;
   nicklockwood/SwiftFormat; realm/SwiftLint; XcodesOrg/xcodes;
   fastlane/fastlane
9. simctl push / Simulator Target Bundle —
   https://sarunw.com/tips/testing-remote-push-notification-in-ios-simulator/ ;
   https://www.donnywals.com/testing-push-notifications-in-the-simulator-with-xcode-11-4/
10. Apple, "Interacting with devices using the command line" —
    https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line
    ; https://zenn.dev/scenee/articles/df3a6d9fb18465
11. Apple forums, automatic signing in CI with ASC key —
    https://developer.apple.com/forums/thread/764554 ;
    https://developer.apple.com/forums/thread/760819
12. altool upload status —
    https://help.apple.com/asc/appsaltool/en.lproj/static.html ;
    https://newly.app/guides/app-store-connect-cli
13. Personal team lacks Push — https://developer.apple.com/forums/thread/768748
    ; capability matrix
    https://developer.apple.com/help/account/reference/supported-capabilities-ios
14. runner-images macos-26-arm64 README —
    https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md
15. runner-images xcode-27 releases —
    https://newreleases.io/project/github/actions/runner-images/release/xcode-27%2F20260728.0060
16. Google Fonts (OFL):
    https://fonts.google.com/specimen/Bricolage+Grotesque/license ;
    https://fonts.google.com/specimen/Instrument+Sans/license ;
    https://fonts.google.com/specimen/JetBrains+Mono/license
17. Variable fonts in SwiftUI —
    https://swiftpackageregistry.com/frzi/swift-variablefonts ;
    https://blakecrosley.com/blog/sf-pro-typography-system
18. Apple, "Creating your app icon using Icon Composer" —
    https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
    ; https://useyourloaf.com/blog/adding-icon-composer-icons-to-xcode/
19. ictool CLI —
    https://mjtsai.com/blog/2025/10/02/how-to-export-a-mac-icon-file-with-the-proper-margins/
