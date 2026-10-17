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

## Integration tests

`make ios-integration` runs the sync integration suite (gate G4 in
`docs/ios/specs/sync-protocol.md` §13.2) against real backends built from **this
worktree's** `backend/`. It needs docker, `curl` and `python3`. It brings the
stacks up, runs `ios/scripts/integration-smoke.sh` (the harness checking itself
with curl), then `swift test --filter QuickrDataIntegrationTests`, and tears
everything down on exit, pass or fail (`QUICKR_IT_KEEP=1` keeps the stacks up).
Until that target exists it says so and stops after the smoke test.

| Target                      | Does                                                                      |
| --------------------------- | ------------------------------------------------------------------------- |
| `make ios-integration`      | Up, smoke, integration tests, down                                        |
| `make ios-integration-up`   | Start (or restart clean) the stacks and write `ios/build/integration.env` |
| `make ios-integration-down` | Stop them and delete their data                                           |
| `make ios-sim-clone`        | Print the UDID of this worktree's own simulator, creating it on first use |

**What runs.** Compose project `quickr-it-<worktree dir>-<hash of its path>`,
from `docker-compose.integration.yml`. One throwaway Postgres (tmpfs) holds two
databases. Two backends run from the same image: **server a** and **server b**.
Each one has its own database, so the `server_id` and epoch differ.
`backend/tools/faultproxy.py` runs in front of them and routes to server a by
default. Every port is bound to 127.0.0.1.

**Ports.** Docker picks free host ports (`127.0.0.1::<container port>`) on every
start, and `integration-up.sh` reads them back with `docker compose port`, so
worktrees never race for ports and nothing collides with the dev stack (:8100,
:5433, :8080). Two worktrees can run at once. If startup fails or is interrupted
before the env file is written, `integration-up.sh` removes the stack again.

**`ios/build/integration.env`** holds `KEY=value` lines, one per line, with each
value shell-escaped (`printf %q`; URLs, ids and ports need no escaping). Source it
from a shell; prefer the environment over parsing it. `make ios-integration`
exports these variables to `swift test`:

| Variable                                | Value                                                                                                                             |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `QUICKR_IT_BASE_URL`                    | The proxy, e.g. `http://127.0.0.1:55012`. The app's server URL in tests. API paths start with `/api/v1`                           |
| `QUICKR_IT_BASE_URL_2`                  | Server b, directly (a different server)                                                                                           |
| `QUICKR_IT_DIRECT_URL`                  | Server a, directly (to check server state without going through the proxy rules)                                                  |
| `QUICKR_IT_PROXY_CONTROL_URL`           | The proxy's control API                                                                                                           |
| `QUICKR_IT_SERVER_ID` / `_2`            | `X-QuickR-Server-Id` of server a / b                                                                                              |
| `QUICKR_IT_ROTATE_EPOCH`                | Script path. Run it with `a` or `b` to rotate that server's epoch (S9, outbox 38)                                                 |
| `QUICKR_IT_PROJECT`, `QUICKR_IT_PORT_*` | Compose project name and raw ports                                                                                                |
| `QUICKR_IT_REQUIRED=1`                  | Set only by `make ios-integration`. When it is set, integration tests must **fail**, not skip, if the variables above are missing |

Plain `swift test` doesn't set these variables, so the integration tests skip
themselves there. Tests that run on a simulator through `xcodebuild` would need
the variables passed as `TEST_RUNNER_<name>`. Host `swift test` is the intended
runner.

**Fault proxy control API** (JSON, at `QUICKR_IT_PROXY_CONTROL_URL`):

| Request                                            | Effect                                                                                                                             |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `POST /reset`                                      | Remove all rules (releasing held requests), clear the log, route back to server a. Call it in every test's setup                   |
| `POST /rules` (rule)                               | Add a rule, `201` with the rule (including its `id`); `400 {"error"}` if invalid                                                   |
| `GET /rules`, `GET /rules/{id}`                    | List the rules, or get one. Each rule shows `hits`, `waiting` (held right now), `exhausted` and `released`                         |
| `DELETE /rules`, `DELETE /rules/{id}`              | Remove the rules, or one (releasing its held requests)                                                                             |
| `POST /rules/{id}/release`                         | Let the rule's held requests (and any later ones) go to the server; returns `released_now`                                         |
| `GET /log`, `DELETE /log`                          | Get the log of every proxied request, or clear it (see below)                                                                      |
| `GET /upstream`, `PUT /upstream {"name":"a"\|"b"}` | Show the server the proxy routes to, or switch it. Switching to `b` makes "the URL now reaches a different server" (S8, outbox 49) |
| `GET /health`                                      | `{"ok": true}`                                                                                                                     |

A rule is
`{"action": ..., "method": "*", "path": "*", "sticky": false, "times": 1, ...}`.
`method` is matched case-insensitively. `path` is an `fnmatch` glob against the
path without its query string (`*` also matches `/`), e.g.
`/api/v1/topics/*/entries`. The first rule that matches and is not exhausted
applies. A rule applies `times` times (one-shot by default), or forever when
`sticky` is true. Every field is type-checked (integers must be JSON integers,
header values such as `retry_after` and `content_type` must not contain CR/LF),
and an invalid rule gets a JSON 400 and is not installed. The actions are:

| `action`         | Behaviour                                                                                                                                                                                                                           | Extra fields                                                                                                      |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `pass`           | Forward unchanged (a counted no-op)                                                                                                                                                                                                 |                                                                                                                   |
| `drop_response`  | Forward, wait for the server's full answer (it has committed), then reset the client connection. Outbox 59, "maybe delivered"                                                                                                       |                                                                                                                   |
| `drop_request`   | Reset the connection without forwarding                                                                                                                                                                                             |                                                                                                                   |
| `garble`         | Forward, then corrupt a **2xx** body. `Content-Length` stays correct, so the HTTP is valid and only the body is bad                                                                                                                 | `garble`: `truncate` (default), `drop_field` (removes top-level `field`, default `revision`), `not_json`, `empty` |
| `captive`        | `200 text/html` captive-portal page, without forwarding                                                                                                                                                                             | `body`, `content_type`                                                                                            |
| `status`         | Answer `status` (default 503) without forwarding                                                                                                                                                                                    | `status`, `retry_after`, `body`, `content_type`                                                                   |
| `strip_identity` | Forward, then remove `X-QuickR-Server-Id` and `X-QuickR-Epoch`                                                                                                                                                                      |                                                                                                                   |
| `delay`          | Sleep `delay_ms`, then forward                                                                                                                                                                                                      | `delay_ms`, `phase`: `request` (before the server sees it, the default) or `response` (after it commits)          |
| `hold`           | Park the request **before** it reaches the server until `POST /rules/{id}/release`. The request still reaches the server after the client has given up. This is the deterministic "POST delayed in the network" of outbox 12 and 51 | Poll `GET /rules/{id}` until `waiting` ≥ 1                                                                        |

Each **log** entry is
`{"seq", "at", "method", "path" (with query), "rule", "action", "upstream" ("a"/"b", or null if never forwarded), "upstream_status" (the server's status, or null), "status" (what the client got, or null), "state"}`.
`state` is one of `in_flight`, `held`, `responded`, `dropped` or `client_gone`.
To count what really reached the server (for example outbox 32: exactly 3
PATCHes), filter on `upstream_status != null`.

**Simulators.** Parallel worktrees must not share a simulator: one worktree's
`ios-test` would erase or relaunch the app under another one's UI test. Each WP
should use its own device:

```sh
make ios-test IOS_SIM_MIN="$(ios/scripts/sim-clone.sh)"
make ios-uitest IOS_SIM="$(ios/scripts/sim-clone.sh 'quickR iOS27')"
ios/scripts/sim-clone.sh --delete               # when the worktree is done
```

The clone is named `<source> <worktree dir>-<hash of its canonical path>`, so
running the script again finds the same device, and `--delete` can only ever
remove this worktree's clone. A lock serialises concurrent runs; it records its
owner's PID and host, and is taken over only when that owner has exited. If the source simulator is shut down, the script copies it with
`simctl clone`. If it is booted (in use), the script never touches it and
creates a fresh device with the same device type and runtime instead.

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
