# T2 device checklist (run on the TestFlight build)

**Status:** draft (revision 4, 2026-11-26, M1-DEV: M1 items given a build,
setup, steps, expected result and spec reference; the 7-day reopen and R23
items added), seeded by the programme plan
([t2-plan.md](../specs/t2-plan.md)); each milestone appends its own
simulator-blind items from its evidence file. The user runs it on a real
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
The items below (M1-DEV) need T2 timers, so a level-2 server: they run on
the **`v0.4.0`** TestFlight build after deploy order step 3, and the PWA items
at the end of this file on the `v0.4.0` web build. Only the signing proof
and its fallback above run on `v0.4.0-rc1`. Common setup for the alert items: Settings →
Notifications → QuickR has Allow Notifications, Sounds and Time Sensitive
Notifications on, the ring/silent switch is on ring, and the phone and the
second device both show the server time (no manual clock). An alert is a
local notification whose title is the topic name (`Intervals`) and whose body
is `"{alert label} · {segment label}"`; it is planned for the open segment
only, never while paused, and an alert whose instant passed while the app
couldn't plan is missed, not fired late (timers2.md §9.1).

- [ ] **Real notification centre with permission (R23, I1-ALERTS note).**
      `SystemNotificationCenterTests` (R23) runs on the simulator, but the real
      `UNUserNotificationCenter.add` of an interval-triggered,
      time-sensitive request with notification permission granted is
      unverified there; this item and the next prove it. Build: `v0.4.0`.
      Setup: the common setup; a fresh install has been through the
      notification permission prompt (Allow). Steps: start `Intervals`, tap
      Lap so the open lap is `Rest 1`, keep the app in the foreground and
      watch. Expected: at 30 s of `Rest 1` a banner `Intervals` / "Half way ·
      Rest 1" with sound and the alert haptic (foreground presentation is
      `.banner, .sound`); at 60 s "Done · Rest 1"; both fire within about 1 s
      of the run screen's segment timer reading 0:30 and 1:00, and both are
      grouped under the topic in Notification Center. Spec: timers2.md §9.1,
      §12.3 R23.
- [ ] **Locked-screen lap alert, sound and haptic.** Build: `v0.4.0`. Setup:
      the common setup, no Focus on. Steps: start `Intervals`, tap Lap so the
      open lap is `Rest 1`, lock the phone at once and leave it. Expected: at
      30 s of `Rest 1` a Lock Screen notification `Intervals` / "Half way ·
      Rest 1" with the default sound and the system haptic; at 60 s "Done ·
      Rest 1", same sound. The Live Activity's alert countdown line reaches
      0:00 at the same moments (the server computes `alert_at`). Spec:
      timers2.md §9.1, §12.5 item 1.
- [ ] **Alert under a Focus (time-sensitive).** Build: `v0.4.0` (needs a
      level-2 server, so not rc1; revision 5). Setup: the common setup; a
      Focus (for example Do Not Disturb) that silences notifications, QuickR
      not in its allowed apps, and the Focus's **Time Sensitive
      Notifications** allowed; turn the Focus on. Steps: repeat the previous
      item. Expected: both alerts still light the Lock Screen and sound, and
      each is marked Time Sensitive. If the build fell back to `.active`
      (I1-SIGNING), expected instead: both alerts are silenced by the Focus
      (delivered quietly to Notification Center), and the Apple portal step
      at the end of this section is pending. Spec: timers2.md §9.1 (OQ-6),
      §12.5 item 1.
- [ ] **Alert with the app killed.** Build: `v0.4.0`. Setup: the common setup.
      Steps: start `Intervals`, tap Lap so the open lap is `Rest 1`, within
      the first 20 s swipe QuickR away in the app switcher, lock the phone.
      Expected: "Half way · Rest 1" at 30 s and "Done · Rest 1" at 60 s still
      fire with sound: they were handed to the system as scheduled local
      notifications before the app died, and nothing has to run to deliver
      them. Spec: timers2.md §9.1.
- [ ] **Stale alerts after a lap on the PWA while the phone is locked (OQ-11,
      expected limitation).** Build: `v0.4.0` on the phone, the PWA signed in
      to the same server. Setup: the common setup. Steps: on the phone start
      `Intervals`, tap Lap so the open lap is `Rest 1`, lock the phone; about
      10 s into `Rest 1`, tap Lap on the PWA (the run is now on `Run 2`,
      which has no alerts); leave the phone locked. Expected (accepted, not a
      bug): the phone still fires "Half way · Rest 1" at 30 s and "Done ·
      Rest 1" at 60 s of the old segment, because a Live Activity push runs
      no app code and the alerts are only re-planned by the app. Meanwhile
      the Live Activity is right: the lap's update push moves it to the new
      lap (counter and segment timer) and it shows no alert countdown. Unlocking alone changes nothing. Then repeat, but
      after the PWA lap unlock the phone and open QuickR before 30 s.
      Expected: the app becoming active re-plans, the stale `Rest 1` alerts
      are removed, and nothing fires during `Run 2`; the next `Rest` lap
      gets its own alerts. Spec: timers2.md §9.1 (the accepted limitation),
      OQ-11, §12.5 item 2.
- [ ] **Reopen re-creates the Live Activity on a second device by
      push-to-start.** Build: `v0.4.0` on both devices. Setup: a second
      iPhone signed in to the same server, QuickR opened there once since
      install (so its push-to-start token is registered) with Live
      Activities allowed. Steps: start `Smoke` on this phone (both devices
      show its Live Activity), wait 30 s, stop it from this phone (both
      activities end), then within 15 minutes tap Resume on this phone's
      tile. Expected: this phone's activity is requested locally at once;
      the second iPhone's activity for `Smoke` reappears by push-to-start
      within a few seconds, without opening the app there. Both show Running,
      with the timer continuing from the active time at the stop (the gap
      between stop and Resume is a pause, not active time); the entry is
      hidden while the run is open again. With only one iPhone, run the
      reverse instead: reopen from the PWA (tile Resume) and expect this
      phone's activity to reappear by push-to-start the same way. Spec:
      timers2.md §4.6, §8.3, §12.5 item 3.
- [ ] **A reopen more than 7 days after the run's start is refused.** Build:
      `v0.4.0` on the phone; the MCP server of the deployed `v0.4.0` (or any
      client of `POST /runs/{id}/events`). Setup: none beyond `Smoke`. Steps:
      with MCP `start_run` start `Smoke` with `at` = now − 7 days + 2 minutes
      (a start may be backdated at most 7 days), then `run_action` `stop` at
      once (the stop is still inside the 7 days; `Smoke` has no required
      questions, so the entry is created);
      note the entry's `revision`; wait 3 minutes, then `run_action`
      `reopen` on the run (target defaults to its terminal stop). Expected:
      the call succeeds (HTTP 200, no error code) but the reopen is recorded
      **void** with `reason: too_long`: its `at` is more than 7 days after
      `started_at`. The run stays `stopped`, the entry keeps its timing and
      revision, no Live Activity appears on any device, and the phone and the
      PWA keep showing the entry. On the phone the entry detail offers no
      "Resume run" for it (resumable from the entry detail only within 7
      days of the run's start). Spec: timers2.md OQ-1 ("Resumable"), §3.4
      (the reopen's `too_long` rule, vector `reopen-too-long`), §4.2, §7.2
      (void reasons are 200, not errors).
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
- [ ] **VoiceOver over the stats.** On the `Intervals` Overview with VoiceOver
      on, swipe through the activity strip and the lap-type bars. Expected:
      "Week of … : N entries" and per-type values are spoken.

## PWA installed on iOS (Add to Home Screen)

- [ ] **Alert tone after a tap gesture (M1, F1-ALERTS).** Build: the `v0.4.0`
      web build, installed to the Home Screen. Setup: alerts not muted in App
      settings, the ring/silent switch on ring, media volume up; Settings →
      Notifications → QuickR (the native app) Allow Notifications off for
      these items, so the native app's own local alerts for the same run
      can't be mistaken for the PWA's (turn it back on after). Steps: open
      the installed PWA, start `Intervals` (the Start tap creates and resumes
      the `AudioContext`), tap Lap so the open lap is `Rest 1`, keep the page
      in the foreground. Expected: at 30 s of `Rest 1` a toast "Half way ·
      Rest 1" and a short synthesised tone; at 60 s "Done · Rest 1" the same.
      No vibration: `navigator.vibrate` is a no-op on iOS. Flip the silent
      switch and repeat: the toast still shows, the tone is muted. Spec:
      timers2.md §9.2 (OQ-13), §12.5 item 5.
- [ ] **Notification when permitted.** With notifications granted to the PWA.
      Expected: the alert also arrives as a notification while the page is open.
- [ ] **Silence while backgrounded (M1, F1-ALERTS).** Build: the `v0.4.0`
      web build, installed. Setup: as the tone item. Steps: start `Intervals`,
      tap Lap to `Rest 1`, and after about 10 s switch to another app (or lock
      the phone) across the 30 s mark. Expected: no tone, toast or
      notification while the PWA is in the background (PWA alerts fire only
      while the page is open; nothing is pushed). Come back within 30 s of
      the missed instant (before about 60 s of `Rest 1`): "Half way · Rest 1"
      shows at once on `visibilitychange`. Repeat but stay away until more
      than 30 s after the instant: that alert is dropped, not shown late, and
      "Done · Rest 1" at 60 s still fires if the page is open by then. Spec:
      timers2.md §9.2 (an alert more than 30 s late is dropped).
- [ ] **Mute toggle.** App settings → mute alerts. Expected: toast only, no tone
      or vibration.

## Sign-off

- [ ] Every item above is ticked or has a `t2-followup` issue linked here.
- [ ] `docs/t2/evidence/*.md` reference this run (date, build number).
