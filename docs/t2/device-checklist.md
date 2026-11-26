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

- [ ] **Time Sensitive signing proof (I1-SIGNING, `v0.4.0-rc1`).** The
      orchestrator asks for this once it has tagged `v0.4.0-rc1` from `feat/t2`
      (after M1 merged there with all five checks green). Expected: the
      `testflight.yml` run for the tag signs, exports and uploads; its log shows
      automatic provisioning (`-allowProvisioningUpdates` with the App Store
      Connect key) and no entitlement or profile error;
      `codesign -d --entitlements - <QuickR.app>` on the exported app (or, when
      the export uploads without a local copy, the build's Build Metadata →
      Entitlements in App Store Connect) lists
      `com.apple.developer.usernotifications.time-sensitive = true`. Install the
      rc build (it shows the non-blocking "server is older" note against the
      level-1 server; the T2 features don't work, which is expected) and confirm
      that the Settings → Notifications → QuickR page offers **Time Sensitive
      Notifications**. The lap alert under a Focus is the "Alert under a Focus"
      item below: it needs T2 timers, so a level-2 server, so it runs on the
      `v0.4.0` build. The rc bot PR `compat/testflight-<build>` merges into
      `main` as usual.
- [ ] **Fallback if rc1 fails to sign on the entitlement.** Flip the one
      constant, `RunAlerts.interruptionLevel = .active`
      (`ios/QuickrKit/Sources/QuickrData/Notifications/RunAlerts.swift`), and
      remove the `com.apple.developer.usernotifications.time-sensitive` line
      from the T2-M1 block of `ios/project.yml` (timers2.md §9.1: a TestFlight
      build never fails on the entitlement), in a small PR on `feat/t2`; tell
      the orchestrator; then the Apple portal step at the end of this section.
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
      portal (Certificates, Identifiers & Profiles → Identifiers →
      `com.bahumia.quickr` → Capabilities), enable Time Sensitive Notifications
      on the App ID and save; automatic signing regenerates the profile on the
      next archive. Then restore `.timeSensitive` and the entitlement line in
      one PR, re-run `testflight.yml`. Expected: the build signs and the next
      build sounds under Focus.

## M2 · active surfaces

- [ ] **Live Activity on the real Lock Screen.** Start `Intervals`, lock.
      Expected: the Lock Screen activity shows the segment timer, the lap
      counter, a dominant **Lap** button labelled with the next type, Stop as a
      secondary; the alert countdown line counts down to 0:00.
- [ ] **Dynamic Island.** Expected: compact leading shows the lap counter
      (`L2`), trailing the segment timer; expanded shows Lap primary and Stop. A
      Lap tap from the Island with the app killed registers (the counter
      increments; the second device sees the lap).
- [ ] **Control Center Timer control.** Add the Timer control for `Intervals`.
      Expected: detail reads "Lap → Rest" while a `Run` lap is open; a tap
      performs the lap and the detail flips to "Lap → Run".
- [ ] **Action button Auto.** Assign the Auto shortcut; press with `Intervals`
      running. Expected: a lap is recorded (not a stop); when idle, a start.
- [ ] **Active card on the home screen.** Expected: the running topic sits in
      "Active now" above "Due now", tinted, with inline Lap and Stop; XXXL text
      stacks the buttons; light and dark both legible.
- [ ] **Resume within 15 minutes.** Stop `Smoke` from the tile. Expected: the
      toast and the idle tile offer Resume for 15 minutes; after that, only the
      entry detail does.

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
- [ ] **Resume run by push-to-start on a second device.** With a second iPhone
      signed in, resume the same entry's run on the first. Expected: the Live
      Activity also starts on the second device by push-to-start.
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
