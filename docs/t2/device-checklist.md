# T2 device checklist (run on the TestFlight build)

**Status:** draft (revision 3, 2026-11-25, after review round 2), seeded by the
programme plan ([t2-plan.md](../specs/t2-plan.md)); each milestone appends its
own simulator-blind items from its evidence file. The user runs it on a real
iPhone with the TestFlight build from the release tag and ticks each box, or
files a `t2-followup` issue with what was seen. Checkboxes stay empty until
then.

## Deploy order (read first)

The server self-hosted via compose will set `min_client_level.ios = 2` and
force-update every older build the moment it is deployed. So:

0. **Ignore rc builds unless asked.** When M1 merged to `feat/t2` the
   orchestrator tagged `v0.4.0-rc1` (ghcr images + a TestFlight build; nothing
   deployed). Against the old level-1 server an rc build shows the non-blocking
   "server is older" note and the T2 features won't work. Install it only when
   the orchestrator asks (the time-sensitive signing proof, M1 item 2 below).
1. Tag `v0.4.0` on `main` (T2-RELEASE).
2. Wait for CI to publish the TestFlight build and **install it on the phone**
   (the TestFlight bot PR lists it in `compat/supported-clients.json`).
3. Only then the server deploy = bump `quickr_build` + both image digests in the
   IaaC repo `inventories/host_vars/quickr.yml` (orchestrator-owned, after you
   confirm the TestFlight build is installed). The old build `20261028.170408`
   must never meet the new server before its replacement is installed.
4. Open the app once online so the store re-pulls; then run the items below.

Setup for the items: two timed topics, `Smoke` (laps renamed to `Cig`, one alert
`t/2` with `t = 60s`) and `Intervals` (lap types `Run`/`Rest`, variable
`t = 60s`, alerts `t/2` "Half way" and `t` "Done" on `Rest`), one with colour
`teal` and emoji 🚬, the other `orange` and 🏃; a second device (or the PWA)
signed in to the same server.

## M1 · timers v2

- [ ] **Locked-screen lap alert, sound and haptic.** Start `Intervals`, tap Lap
      so the open lap is `Rest 1`, lock the phone. Expected: at 30 s a
      notification "Half way · Rest 1" with the default sound and the system
      haptic; at 60 s "Done · Rest 1". The Live Activity countdown reached 0:00
      at the same moments.
- [ ] **Alert under a Focus (time-sensitive).** Enable a Focus that silences
      notifications (allow Time Sensitive), repeat the previous item. Expected:
      both alerts still sound. If the build fell back to `.active` (I1-SIGNING),
      expected instead: no sound under Focus, and the portal step below is
      pending.
- [ ] **Alert with the app killed.** Start `Intervals`, Lap to `Rest`, swipe the
      app away from the app switcher, lock. Expected: the 30 s and 60 s alerts
      still fire (they are scheduled local notifications).
- [ ] **Stale alerts after a lap on another device (OQ-11, expected
      limitation).** Phone locked on `Rest 1`; on the second device tap Lap.
      Expected: the phone's pending alerts for `Rest 1` still fire (stale);
      after unlocking and opening the app they are re-planned for the current
      segment.
- [ ] **Reopen re-creates the Live Activity on a second device.** On the second
      device stop `Smoke`, then tap Resume. Expected: this phone's Live Activity
      for `Smoke` reappears by push-to-start within a few seconds and shows
      Running with a pause row for the gap.
- [ ] **Apple portal step (only if I1-SIGNING fell back).** In the developer
      portal, enable Time Sensitive Notifications on the App ID, regenerate the
      profile, re-run `testflight.yml`. Expected: the next build sounds under
      Focus.

## M2 · active surfaces

Checked against `t2/m2` after I2-LA (#138) and I2-WIDGETS (#136); spec
[active-surfaces.md](../specs/active-surfaces.md) §3–§5. An item, or a part of
one, marked **(pending <WP>)** depends on work not yet in `t2/m2` when this was
written; the release build has it, so run it as written, and if the behaviour is
missing, check that the named WP merged before filing.

Extra setup for M2: two timed topics **without lap types** (the §5.3 Auto
carve-out applies to them): `Dishwasher` (no steps: a stopwatch) and `Morning`
(steps `Shower`, `Breakfast`). Neither has questions, so Stop saves at once.
Before the activity items, unlock the phone, open quickR, then close it.

- [ ] **Live Activity layout on the real Lock Screen.** Start `Morning`, lock.
      Expected, top to bottom (§4.2: two text rows and one button row, so iOS's
      160 pt Lock Screen limit never truncates it): `Morning` with "1 of 2" at
      the trailing edge; the ticking segment timer (large), "Shower", and at the
      trailing edge the total in muted text; then one button row: **Next:
      Breakfast** filled (prominent, accent) at half the width, **Pause** and
      **Stop** (Stop in red) bordered at a quarter each. Tap Next: the badge
      reads "2 of 2" and the primary becomes **Lap** (the last step is open, so
      Lap is primary and Stop never is). Pause: the timers freeze and Pause
      reads **Resume**. With VoiceOver on, the buttons read "Next: Breakfast"
      (then "Lap"), "Pause", "Stop Morning" (§1.3; the shipped Stop reads
      "Stop": #143). Repeat with Settings → Accessibility → Display & Text Size
      → Larger Text at the largest size: the text stops growing at the widgets'
      cap (xxLarge), the button row is still fully visible and every label,
      "Next: Breakfast" included, reads in full (shrunk is fine, cut off is
      not). Stop: the activity shows "Saved · m:ss" and no buttons.
- [ ] **Live Activity lap fields (pending I2-LA-FIELDS).** Start `Intervals`,
      lock. Expected: the second row's text is the headline ("Run 1 · lap 1"
      style, §4.1) and the trailing badge "L1"; the primary reads **Lap → Rest**
      (VoiceOver: "Lap, then Rest"). Tap it so `Rest 1` is open: under the
      total, "⏰ Half way · 0:30" counts down in the warning colour and stays at
      0:00 once reached (the activity itself makes no sound: the M1 alert items
      cover the sound). While paused the alert line is hidden.
- [ ] **Dynamic Island.** Start `Morning` (iPhone with a Dynamic Island).
      Expected: compact leading shows the step number ("1"), compact trailing
      and minimal the segment timer. Long-press for the expanded view: segment
      timer leading, total trailing, "Shower" in the centre, and one row with
      **Next: Breakfast** prominent at two thirds and **Stop** at one third (no
      Pause in the Island). Start `Dishwasher` instead: compact leading is the
      timer glyph and the expanded primary is **Lap**.
- [ ] **Dynamic Island lap counter (pending I2-LA-FIELDS).** Start `Intervals`.
      Expected: compact leading shows the lap counter ("L1", then "L2" after a
      Lap); expanded trailing shows the alert countdown under the total while
      `Rest` is open.
- [ ] **Lap tap from the Lock Screen with the app killed.** Phone online (Wi-Fi
      or cellular). Start `Dishwasher`, swipe quickR away in the app switcher,
      lock. Tap **Lap** on the Lock Screen activity (the phone stays locked; no
      Face ID prompt). Expected: within a second or two the segment timer
      restarts from 0:00 and the label moves to the next lap ("Lap 2"), the
      total keeps running. Wait about 10 s, then refresh the second device: it
      shows the lap. Opening quickR shows the lap row in the table. Repeat once
      from the expanded Dynamic Island.
- [ ] **Timer control on a timer without lap types reads "Stop" (§5.3).** In
      Control Center, add the quickR **Timer** control and pick `Dishwasher`.
      Expected: idle, the control reads "Timer: Dishwasher" / "Start" with a
      play icon; press it: the run starts (the Live Activity appears) and the
      control reads **"Stop"** with a stop icon, although the app's and the
      activity's primary is Lap. Press it again: the run stops and saves, and
      the control reads "Start". With `Morning`: "Next: Breakfast" (chevron
      icon) while `Shower` is open, then "Stop" on `Breakfast`.
- [ ] **Timer control on a lap-typed timer (pending I1-WRITES, I2-LA-FIELDS).**
      Configure a second Timer control for `Intervals`, start it. Expected: the
      detail reads "Lap → Rest" (flag icon) while a `Run` lap is open; a press
      performs the lap (not a stop) and the detail flips to "Lap → Run". No
      press of this control ever stops `Intervals`.
- [ ] **Action button Auto.** Settings → Action Button → Shortcut → quickR
      **Advance Timer**, topic `Dishwasher`, action Auto. Expected: idle, a
      press starts the run; the next press stops it (v1 Auto on a timer without
      lap types); a press may show quickR's short confirmation. Then set the
      topic to `Intervals` **(pending I1-WRITES)**: while it runs, a press
      records a lap (the Live Activity's lap moves on), never a stop.
- [ ] **Active card on the home screen (pending I2-HOME).** Start `Intervals`
      and open the home screen. Expected: an "Active now" section, with a
      pulsing timer glyph, sits above "Due now", and `Intervals` appears only
      there. Its card is tinted, with a leading bar; it shows the name with a
      small **Pause** text button, the **segment** timer big and "total m:ss"
      small beside it, a "Running · …" badge, the alert line while one is
      pending, and one controls row: the primary (**Lap → Rest**) filling the
      row and **Stop** at a fixed width beside it. A tap on the card outside the
      buttons opens the run screen. Pause: the badge reads "Paused · …", the
      clock dims, the button reads **Resume**. At the largest accessibility text
      size the primary stacks over Stop (both full width) and Pause moves under
      the badge. Light and dark both legible. Stop: the section disappears.
- [ ] **Resume within 15 minutes (pending M1, M2-RESUME).** `Smoke` has no
      questions, so Stop saves at once. Start `Smoke`, run it about a minute,
      stop it from its active card. Expected: the toast "Saved Smoke: m:ss"
      offers **Resume**; tap it: the same run is running again (its total
      carries on from the stop) and the run screen shows a pause row for the
      gap; this phone's Live Activity comes back. Stop again, dismiss the toast:
      the idle tile shows "Resume · m:ss" under its meta line. Turn on airplane
      mode, tap that Resume: the card shows "Resuming…" with no controls row;
      turn airplane mode off: once the server acks, the ordinary running card
      with its controls. Stop again and wait 15 minutes: neither the toast nor
      the tile offers Resume any more (the entry detail's "Resume run" is the M4
      item). The ended Live Activity ("Saved · m:ss") never offers Resume
      (§4.4).
- [ ] **Smart Stack and StandBy (observe only).** Put the small Topic widget for
      `Dishwasher` in a Home Screen Smart Stack, then start the run. Charge the
      phone locked and in landscape for StandBy. Expected: nothing to pass or
      fail. Note whether the Smart Stack rotates to the widget or to the
      activity, and how StandBy shows the Live Activity (scaled Lock Screen
      layout; the system derives it, quickR adds no StandBy view). File a
      `t2-followup` issue only for clipped buttons, unreadable text or a tap
      that does nothing.

## M3a · appearance

- [ ] **Widget tint with colour and emoji.** Add the small and medium topic
      widgets for `Smoke` (teal, 🚬). Expected: in full-colour mode the accent
      bar and glyph are teal/🚬; in tinted and accented Home Screen modes the
      glyph stays legible and the tint follows the system.
- [ ] **Live Activity tint and glyph.** Start `Smoke`, lock. Expected: the
      activity background is the teal `tintSoft`, the glyph 🚬 precedes the
      name. (Attributes are set at start: change the colour mid-run and expect
      no change until the next run.)
- [ ] **Reminder notification title with emoji prefix.** Schedule a reminder on
      `Smoke` for a minute ahead, lock. Expected: the title reads "🚬 Smoke".
- [ ] **Tag filter.** Tag `Smoke` with `habit`; on home use the tag filter.
      Expected: only tagged topics show; the chip appears on the tile footer and
      the topic header.

## M3b · photos

- [ ] **Photo upload from the camera roll.** In `Smoke` settings → Appearance,
      pick a HEIC photo. Expected: upload completes under a few seconds on
      Wi-Fi, the header shows the 512 px image, the tile shows the thumb.
- [ ] **Thumbnail in a widget and the Live Activity.** After the upload,
      Expected: the topic widget and the next run's Live Activity show the photo
      thumb from the App-Group cache (no network needed: enable airplane mode
      and reload the widget).
- [ ] **Slow link.** On cellular with Low Data Mode, upload a 4–5 MB photo.
      Expected: progress, then success or a clear failure notice; nothing
      half-rendered.

## M4 · content display

- [ ] **Resume run from the entry detail.** Open the latest `Smoke` entry (older
      than 15 min, under 7 days). Expected: "Resume run" is offered; it reopens
      the run, the run screen shows the gap pause, and the Live Activity appears
      on this device.
- [ ] **VoiceOver over the stats.** On the `Intervals` Overview with VoiceOver
      on, swipe through the activity strip and the lap-type bars. Expected:
      "Week of … : N entries" and per-type values are spoken.

## PWA installed on iOS (Add to Home Screen)

- [ ] **Alert tone after a tap gesture.** Open the installed PWA, start
      `Intervals`, tap Lap to `Rest`. Expected: at 30 s a toast, vibration and a
      short tone (the tap unlocked audio); the silent switch mutes the tone.
- [ ] **Notification when permitted.** With notifications granted to the PWA.
      Expected: the alert also arrives as a notification while the page is open.
- [ ] **No alert while backgrounded.** Switch to another app before 60 s.
      Expected: nothing fires until the PWA is foregrounded again, then the
      pending alert shows at once (requirement: PWA alerts only while open).
- [ ] **Mute toggle.** App settings → mute alerts. Expected: toast only, no tone
      or vibration.

## Sign-off

- [ ] Every item above is ticked or has a `t2-followup` issue linked here.
- [ ] `docs/t2/evidence/*.md` reference this run (date, build number).
