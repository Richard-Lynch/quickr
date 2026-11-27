# M2 "before" screenshots

The evidence baseline for milestone M2 (active surfaces): how the home screen
and the run screen look **before** any M2 work package lands. The "after" pairs
are captured by the UI WPs. All files are PNG, downscaled to 600 px wide (PWA
shots are their native 390 px).

Taken at `t2/m2` commit `ced539af1a27c78cf2e0a3b0de153c192b3d1a2e` (the
milestone branch before any WP merge; its app code is `feat/t2`'s
`b9c566cbe5dd12b7223eadf25e1ec4ebdaa4e2c9`).

## iOS (simulator, iPhone clone of "quickR iOS-26-0", UI-test fake server)

State, built through the app against the in-process fake server
(`-QuickrUITest`): Mood on a daily schedule whose slot has just passed (the due
topic), Workout published as a timed topic with no steps (a lap stopwatch) and
started from its tile, one lap recorded, so the tile reads "Running · m:ss / Lap
2 s"; Morning (timed, with steps) and two new topics (Lemsip, Bailed) idle.

| File                 | What it shows                                                                                                                                                              |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ios-home-light.png` | Home, light: the "Due now" section, the running Workout tile with Stop as the tile's block and the lap line in the tile, the idle tiles. No "Active now" section.          |
| `ios-home-dark.png`  | The same in dark (the state of the user's own screenshot).                                                                                                                 |
| `ios-home-xxxl.png`  | The same at the AccessibilityXXXL text size (dark), scrolled to the running tile (the due Mood tile's chips and Log block end above it; one tile is a screen tall).        |
| `ios-run-light.png`  | The run screen of the lap topic, light: header clock, the lap table with Lap 1 done and Lap 2 current, the Lap / Skip / Pause row inside the card, Stop in the bottom bar. |
| `ios-run-dark.png`   | The same in dark.                                                                                                                                                          |
| `ios-run-xxxl.png`   | The same at AccessibilityXXXL (dark).                                                                                                                                      |

How: a throwaway XCUITest (`ios/UITests/BeforeShotsUITests.swift`, **not
committed**) drove the app and attached `XCUIScreen.main.screenshot()` at each
state, switching `XCUIDevice.shared.appearance`; the XXXL test launched with
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.
The status bar was overridden with
`xcrun simctl status_bar <udid> override --time 9:41 …` before the run.

```
make ios-gen
ios/scripts/common.sh xcb -destination id=<udid> -testPlan UI build-for-testing
UDID=$(ios/scripts/sim-clone.sh --wait)
IOS_RESULT_BUNDLE=<path>.xcresult ios/scripts/test.sh UI "$UDID" \
  -only-testing:QuickRUITests/BeforeShotsUITests -collect-test-diagnostics never
xcrun xcresulttool export attachments --path <path>.xcresult --output-path <dir>
xcrun simctl shutdown "$UDID"
sips --resampleWidth 600 <attachment> --out ios-<view>-<mode>.png
```

Result bundles (scratchpad, not kept): the light and dark pairs from
`scratchpad/t2/m2/before/results/BeforeShots-20261125-221456.xcresult`
(`testBeforeShots` passed; its XXXL sibling failed on a tap and was rerun), the
XXXL pair from
`scratchpad/t2/m2/before/results/BeforeShots-20261125-223242.xcresult`
(`testBeforeShotsXXXL`, 1 test, 1 passed). Both on the clone
`7D8390A4-A833-4F56-82CD-276797F10BD1`, shut down after each run.

## PWA (Chromium via Playwright, 390 × 844)

State, seeded through the API on a backend run from this worktree against its
own test database: Ankle Checkin on a 15-minute interval schedule, due (the "Due
now" section); Smoke-interactive, a timed topic with no steps, with a running
run and one lap ("Running · m:ss / Lap 2"); Smoke, Demo, Lemsip and Bailed idle
with one entry each.

| File                   | What it shows                                                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `pwa-topics-light.png` | Topics page, light: the running bar at the top, "Due now", the running tile with Stop as its block, idle tiles.         |
| `pwa-topics-dark.png`  | The same in dark.                                                                                                       |
| `pwa-run-light.png`    | Record page's run panel, light: total clock, lap table, the Lap / Skip / Pause row in the card, Stop in the bottom bar. |
| `pwa-run-dark.png`     | The same in dark.                                                                                                       |

How: `uv run uvicorn app.main:app --port 8299` with `QUICKR_DATABASE_URL` from
`uv run python -m tools.test_database ensure` (migrated with
`alembic upgrade head`); topics, entries and run events posted with `curl`-style
requests (`X-QuickR-Client: web; level=1`);
`PORT=5299 QUICKR_API_TARGET=http://localhost:8299 pnpm dev`; Playwright
`browser_resize 390×844`, `browser_emulate_media colorScheme`,
`browser_take_screenshot`.
