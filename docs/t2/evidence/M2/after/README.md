# M2 "after" screenshots

The "after" pairs for milestone M2 (active surfaces), one block per UI work
package. PNG; PWA shots are their native 390 px wide.

## F2-HOME: PWA topics page with "Active now"

State, seeded through the API on a backend run from the F2-HOME worktree against
its own test database. Intervals is a timed topic with no steps (a lap
stopwatch), running with two laps recorded, so Lap 3 is open. Morning routine is
timed with three steps, running with Breakfast open. Ankle Checkin (15-minute
interval schedule), Smoke and Lemsip are idle.

| File                               | What it shows                                                                                                                                                                                                                                                                                   |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pwa-topics-light.png`             | Topics page, light: "Active now · 2" first. Each card has its glyph, Pause in the title row, the segment clock large with the total beside it, the headline badge, then the primary (**Lap** on the stopwatch, **Next: Teeth** on the routine) and Stop. The running bar above predates F2-BAR. |
| `pwa-topics-dark.png`              | The same in dark.                                                                                                                                                                                                                                                                               |
| `pwa-active-card-200pct-light.png` | One card with the root font size at 200% (a card under 21rem): Pause moves under the headline and the controls stack, primary over a full-width Stop (active-surfaces.md §3.2, §7).                                                                                                             |

How: `uv run uvicorn app.main:app --port 8297` with `QUICKR_DATABASE_URL` from
`uv run python -m tools.test_database ensure` (after `alembic upgrade head`).
Topics and run events were posted with `X-QuickR-Client: web; level=1`. Then
`PORT=5297 QUICKR_API_TARGET=http://localhost:8297 pnpm dev --strictPort` and a
headless Playwright script: a 390 × 844 context with `colorScheme` set to
light or dark, waiting for `data-testid="active-card"` before the screenshot.
The 200% shot adds `html { font-size: 200% }`. Both servers were stopped
afterwards.

Since F2-BAR, the running bar leaves out every run the topics page shows as an "Active now" card,
so the bar in the two topics shots above is no longer there (see
`pwa-running-bar-topics-absent-light.png`).

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
