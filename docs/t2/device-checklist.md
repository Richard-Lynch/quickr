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
      **CI half done (2026-11-26):** run
      [45861915528](https://github.com/Richard-Lynch/quickr/actions/runs/45861915528)
      signed, exported and uploaded build `20261126.180255` with no entitlement
      or profile error. Still for you: the App Store Connect entitlements view,
      the install and the Settings toggle.
- [x] ~~**Fallback if rc1 fails to sign on the entitlement.**~~ Not needed: rc1
      signed (run 45861915528). Flip the one
      constant, `RunAlerts.interruptionLevel = .active`
      (`ios/QuickrKit/Sources/QuickrData/Notifications/RunAlerts.swift`), and
      remove the `com.apple.developer.usernotifications.time-sensitive` line
      from the T2-M1 block of `ios/project.yml` (timers2.md §9.1: a TestFlight
      build never fails on the entitlement), in a small PR on `feat/t2`; tell
      the orchestrator; then the Apple portal step at the end of this section.
      The items below (M1-DEV) need T2 timers, so a level-2 server: they run on
      the **`v0.4.0`** TestFlight build after deploy order step 3, and the PWA items
      at the end of this file on the `v0.4.0` web build. Only the signing proof
      and its fallback above run on `v0.4.0-rc1`. `v0.4.0` carries every T2
      milestone, so these items also lean on M2's Live Activity alert line and
      tile Resume, M4's entry-detail Resume and M1's F1-ALERTS (the PWA alerts);
      an item whose surface is missing from the build gets a `t2-followup` issue,
      not a tick. Common setup for the alert items: Settings →
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
      of the run screen's segment timer reading 0:30 and 1:00 (the banner
      only: foreground alerts are not listed in Notification Center). Spec:
      timers2.md §9.1, §12.3 R23.
- [ ] **Locked-screen lap alert, sound and haptic.** Build: `v0.4.0`. Setup:
      the common setup, no Focus on. Steps: start `Intervals`, tap Lap so the
      open lap is `Rest 1`, lock the phone at once and leave it. Expected: at
      30 s of `Rest 1` a Lock Screen notification `Intervals` / "Half way ·
      Rest 1" with the default sound and the system haptic; at 60 s "Done ·
      Rest 1", same sound. The Live Activity's alert countdown line (M2's
      rendering of the server-computed `alert_at`) reaches 0:00 when "Half
      way" fires; the notifications don't update the activity, so the line
      is not expected to move on to "Done" by itself. Spec: timers2.md §9.1,
      §12.5 item 1.
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
      lap (counter and segment timer), and its alert countdown line (M2)
      disappears because `Run` has no alerts. Unlocking alone changes nothing. Then repeat, but
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

These items come from [evidence/M3a.md](evidence/M3a.md) §8. Items marked **after
T2-WIRE** need M2's surfaces to render the theme (T2-WIRE-I). Until T2-WIRE has
merged, the expected result is the untinted default, which is not a failure.
Setup: `Smoke` themed teal 🚬 with the tag `habit`, and `Intervals` themed
orange 🏃, as in the setup at the top of this file.

- [ ] **First launch after the upgrade re-pulls themed topics.** Do this before
      any other M3a item.
  - Steps: install the TestFlight build, but don't open it. After the
    server deploy (deploy order, step 3), set the setup's colours, emoji and tag
    on `Smoke` and `Intervals` **from the PWA**. Then open the iOS app for the
    first time, online, and wait for the first sync.
  - Expected: with no edit on the phone, `Smoke`'s topic screen shows the header
    with 🚬, "Smoke", the `habit` chip and a teal rule under it. `Intervals`
    shows 🏃 and an orange rule. Settings → Details → Appearance reads
    `Teal · 🚬 · 1 tag` for `Smoke`.
  - If a topic stays unthemed, the store's cursor reset or the `t2m1`/`t2m3`
    migration order failed (evidence §3.5). File a `t2-followup` issue with the
    build number.
- [ ] **Emoji keyboard in the Appearance editor.**
  - Steps: on the phone, open `Smoke` → Settings → Details → Appearance. Tap the
    Emoji field and switch to the emoji keyboard with the globe key.
  - Expected:
    - Picking 🚬 shows it in the field with no error.
    - A long-press skin-tone variant (for example 👍🏽) is accepted.
    - A flag (for example 🇮🇪) is accepted.
    - A second emoji typed after the first, a letter, or a digit shows an
      inline error under the field and keeps Save details from sending.
    - The ✕ ("Remove emoji") clears the field.
  - Finish: back in Details, Save details. The header shows the new emoji, and
    the PWA shows the same emoji after a refresh.
- [ ] **Reminder notification title with the emoji prefix.**
  - Steps: in `Smoke`'s settings, set a schedule so that the topic falls due
    2–3 minutes from now. Save, lock the phone and wait.
  - Expected:
    - The reminder's title reads exactly "🚬 Smoke", with one space after the
      emoji.
    - On a topic without an emoji (clear `Intervals`' emoji first and repeat),
      the title is the plain name.
    - If the PWA has push enabled, its notification title also starts with 🚬.
- [ ] **Live Activity tint and glyph (after T2-WIRE).**
  - Steps: from the **second device or the PWA**, start `Smoke`, so this phone's
    Live Activity comes by push-to-start, which carries the appearance. Lock the
    phone.
  - Expected:
    - The Lock Screen activity's background is teal's soft wash (light
      `#d4eeea`, dark `#113330`), and its primary button is the teal tint.
    - 🚬 comes before "Smoke".
    - Stop stays red (§4.3: semantic colours never change).
  - Then change `Smoke`'s colour to orange while it runs. Expected: the activity
    keeps teal until the next run, because attributes are set at start.
  - Repeat with the start tapped **on this phone**. Until #226 is fixed, expect
    the untinted default there. That is a known gap, not a new failure.
- [ ] **Widget tint in full-colour, tinted and accented modes (after
      T2-WIRE).**
  - Steps: add the small and medium topic widgets for `Smoke`.
  - Expected:
    - **Default (full-colour) Home Screen:** a teal accent bar and primary chip,
      with 🚬 before the name.
    - **Tinted mode** (long-press the Home Screen → Edit → Customize → Tinted):
      no teal fills; 🚬 is still shown as text and is legible; nothing else
      changes.
    - **Dark/accented mode:** the same. The emoji may render monochrome, which
      is accepted (spec §6.6).
    - A topic without a colour looks exactly as it did before M3a.
- [ ] **Tile tint and glyph on Home (after T2-WIRE).**
  - Steps: open Home.
  - Expected:
    - `Smoke`'s idle tile has a teal accent bar and border, the Log/Start block
      in teal with white text, and 🚬 before the title.
    - The tile footer shows at most three tag chips, then "+N".
    - An untinted topic's tile is unchanged.
    - Check in light and dark, and at the largest text size.
- [ ] **Tag filter (after T2-WIRE).** Tag `Smoke` with `habit`; on Home tap the
      chip or use the tag filter. Expected: only tagged topics show; the chip
      appears on the tile footer and in the topic header.

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
      shows at once on `visibilitychange`. Then, in a new run, stay away from
      about 10 s to about 65 s of `Rest 1` (more than 30 s past "Half way"):
      on return "Half way" is dropped, not shown late, while "Done · Rest 1",
      under 30 s late, shows at once. Spec: timers2.md §9.2 (an alert more
      than 30 s late is dropped).
- [ ] **Mute toggle.** App settings → mute alerts. Expected: toast only, no tone
      or vibration.

## Sign-off

- [ ] Every item above is ticked or has a `t2-followup` issue linked here.
- [ ] `docs/t2/evidence/*.md` reference this run (date, build number).
