# M2 "after" screenshots

The "after" pairs for milestone M2 (active surfaces), one block per UI work
package. PNG; PWA shots are their native 390 px wide.

## F2-HOME: PWA topics page with "Active now"

State, seeded through the API on a backend run from the F2-HOME worktree against
its own test database. Intervals is a timed topic with no steps (a lap
stopwatch), running with two laps recorded, so Lap 3 is open. Morning routine is
timed with three steps, running with Breakfast open. Ankle Checkin (15-minute
interval schedule), Smoke and Lemsip are idle.

| File                               | What it shows                                                                                                                                                                                                                                                                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pwa-topics-light.png`             | Topics page, light: "Active now · 2" first. Each card has its glyph, Pause in the title row, the segment clock large with the total beside it, the headline badge, then the primary (**Lap** on the stopwatch, **Next: Teeth** on the routine) and Stop. No running bar (reshot in I2-UITEST, after F2-BAR). |
| `pwa-topics-dark.png`              | The same in dark.                                                                                                                                                                                                                                                                                            |
| `pwa-active-card-200pct-light.png` | One card with the root font size at 200% (a card under 21rem): Pause moves under the headline and the controls stack, primary over a full-width Stop (active-surfaces.md §3.2, §7).                                                                                                                          |

How: `uv run uvicorn app.main:app --port 8297` with `QUICKR_DATABASE_URL` from
`uv run python -m tools.test_database ensure` (after `alembic upgrade head`).
Topics and run events were posted with `X-QuickR-Client: web; level=1`. Then
`PORT=5297 QUICKR_API_TARGET=http://localhost:8297 pnpm dev --strictPort` and a
headless Playwright script: a 390 × 844 context with `colorScheme` set to
light or dark, waiting for `data-testid="active-card"` before the screenshot.
The 200% shot adds `html { font-size: 200% }`. Both servers were stopped
afterwards.

The two topics shots were reshot in I2-UITEST, after F2-BAR, so they show no running bar: since
F2-BAR the bar leaves out every run the topics page shows as an "Active now" card (see also
`pwa-running-bar-topics-absent-light.png`). Same state as above, built in the page with the app's
own fake run server (`src/test/fakeRunServer.ts`, one per timed topic; only `/api/v1/` faked), the
recipe of F2-CONTROLS' Playwright script: Vite from the I2-UITEST worktree on port 5393, a
390 × 844 context at 2× with the system Chrome, downscaled to 390 px wide. The server was stopped
afterwards.

## F2-BAR: the running bar

The app's own fake server (`src/test/fakeRunServer.ts`) is installed in the page, and only
`/api/v1/` is faked. Vite runs from the F2-BAR worktree on its own port, with a 390 × 844
Playwright context at 2×. The bar is shot on a topic's overview page, because the topics page
leaves listed runs out.

| File                                      | What it shows                                                                                                           |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `pwa-running-bar-lap-light.png`           | A stopwatch topic (no steps) in Lap 3: the bar's primary is **Lap** with the flag, as on the run panel. No Stop (§6.3). |
| `pwa-running-bar-lap-dark.png`            | The same in dark.                                                                                                       |
| `pwa-running-bar-next-light.png`          | A routine on its first step: **Next: Breakfast**.                                                                       |
| `pwa-running-bar-long-light.png`          | A long step name at 200% root font size: the button moves to its own line and wraps, so the title is never cut off.     |
| `pwa-running-bar-topics-absent-light.png` | The topics page with the run shown as an "Active now" card: no running bar, so the primary shows once.                  |

## I2-UITEST: iOS home, run screen, lap flow and timed widgets

The iOS "after" pairs of M2-BEFORE's `before/ios-*.png`, same names, same state and the same
method: a throwaway XCUITest (`AfterShotsUITests`, **not committed**: M2-BEFORE's
`BeforeShotsUITests` with the new ids) against the UI-test fake server. Mood is due, Lemsip and
Bailed idle, Workout published as a stopwatch (timed, no steps), started from its tile with one lap.
`XCUIScreen.main.screenshot()` attachments, status bar overridden to 9:41, downscaled to 600 px.
Taken at this WP's merge of `t2/m2` `ba46bba7` (`d7e2c02b`, with 062ded78), on the clone
`D7EC0EB0-F465-4CA2-8583-43E380D4C902`, result bundle
`ios/build/results/UI-20261126-073446-JNW3zR/UI.xcresult` (`testAfterShots`, `testAfterShotsXXXL`
passed), shut down after the run.

| File                                       | What it shows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ios-home-light.png`                       | Home, light: "Active now · 1" first, Workout's card (segment clock with the total, "Running · Lap 2", Pause, **Lap** with Stop beside it); then "Due now" with Mood.                                                                                                                                                                                                                                                                                                                                                                                                        |
| `ios-home-dark.png`                        | The same in dark.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ios-home-xxxl.png`                        | The same at AccessibilityXXXL (dark): the card stacks Pause under the headline and Lap over Stop.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ios-run-light.png`                        | The run screen, light: header clock and "Lap 2 0:14", the hero **Lap**, Stop and Pause as secondaries, the lap table (no controls in it).                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `ios-run-dark.png`                         | The same in dark.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ios-run-xxxl.png`                         | The same at AccessibilityXXXL (dark): the secondaries stack.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `ios-lap-flow.mp4`, `ios-lap-flow.gif`     | `RunUITests.testLapIsPrimaryWithChunkyControls`, recorded with `simctl io recordVideo`: Start on the tile, the card, the run screen, Lap, Pause, Resume, Stop opens the answers form. Bundle `ios/build/results/UI-20261126-073336-FBnoaQ/UI.xcresult`.                                                                                                                                                                                                                                                                                                                     |
| `widgets/widgets-timed-<mode>-<state>.png` | `WidgetViewsUITests.testTimedWidgetsShowTheLapPrimary`, per mode (`light`, `dark`, `tinted`, `ax` = AccessibilityXXXL): `lap` (stopwatch: Lap + Stop), `typedlap` (the typed fixture; Lap until M1's lap types), `auto` (small: one Auto chip, Stop on a stopwatch), `step` (small: Next: Breakfast), `paused`, `alert` (#223: Intervals on a typed lap, "Rest 2 · lap 4", the pending "Go" alert beside the total; every labelled part asserted inside the widget's frame, nothing clipped in any mode). Bundle `ios/build/results/UI-20261126-074206-fOyepw/UI.xcresult`. |

Live Activity states are not here: the Lock Screen and island views need an `ActivityViewContext`
and live only in the widget extension, so the app's gallery cannot render them (issue #202). They
stay on `docs/t2/device-checklist.md`.

## M2-RESUME: Resume on the toast, the idle tile and the run screen; "Resuming…"

Against the UI-test fake server's TikTok (`-QuickrSeedTikTok`: no steps, lap types Run and Rest,
no questions, so Stop saves at once), on the clone `FB902170-F048-4853-9805-4E53B478435E`,
status bar 9:41, downscaled to 600 px. The debug overlays of the UI-test launch show: the run
controls at the top (`-QuickrRunControls`), the sync controls and the clock/pull controls at the
bottom. Shots from a throwaway XCUITest (`ResumeShotsUITests`, **not committed**), light from
session 2 (`xcresults/M2-RESUME-s2-shots-light.*`), dark and AccessibilityXXXL from session 3
(`xcresults/M2-RESUME-s3-shots-dark.*`).

| File                                        | What it shows                                                                                                                                            |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ios-resume-stop-toast-<mode>.png`          | Stop on the card saved the run: "Saved TikTok: 0:09" with **Resume**; the idle tile already offers "Resume · 0:09" under its meta line (§3.2, §3.3).       |
| `ios-resume-idle-tile-<mode>.png`           | The toast gone: the idle tile with Start and "Resume · 0:09" (`tile.tiktok.reopen`) for 15 minutes on the run clock.                                     |
| `ios-resume-resuming-card-<mode>.png`       | Offline, the stop acked, Resume tapped: the card in "Active now" says **Resuming…** and has no controls row until the ack (§1.2 row 11, timers2.md §5.3). |
| `ios-resume-resuming-run-<mode>.png`        | Its run screen: the `run.state` badge **Resuming…**, the clock running from the entry's timing, no controls; the lap row's type badge ("Run").           |
| `ios-resume-flow.gif`, `ios-resume-flow.mp4` | `RunUITests.testStopToastOffersResume`, recorded with `simctl io recordVideo` (session 1, `xcresults/M2-RESUME-s1-gif.*`): start, the run screen ("Lap → Rest", typed lap badges), Lap, Stop, the toast's Resume, the card back as "Running · Rest 1 · lap 2", the run screen, Stop again, the entry with its gap pause ("Paused 0:01"). |

`<mode>`: `light`, `dark`, `xxxl` (AccessibilityXXXL, dark).
