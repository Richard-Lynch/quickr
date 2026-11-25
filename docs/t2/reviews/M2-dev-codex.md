1. **[P1] The killed-app test conflates a successful lap with a network sync
   guarantee** —
   [device-checklist.md:108](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:108).
   The checklist expects the second device to show the lap after its next sync,
   but does not establish that the phone has network access or that its queued
   write has reached the server. A correct local tap can therefore fail this
   check. Specify an online connection and wait for the phone’s write to sync
   before checking the second device.

2. **[P2] The Resume test does not exercise the toast action** —
   [device-checklist.md:146](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:146).
   It checks that Resume appears in the toast but only taps the tile action. A
   broken toast action could pass, even though the spec requires both surfaces
   to reopen the latest stopped entry. Add a separate stop-and-resume through
   the toast and verify that the same run returns.

3. **[P2] The “Resuming…” state is not made observable** —
   [device-checklist.md:149](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:149).
   On a normal online connection, the server may acknowledge the reopen before
   the tester can see the pending state. The test can falsely fail a correct
   implementation or pass without verifying that controls are hidden. Hold the
   phone offline or otherwise delay the acknowledgment, check the pending card,
   then restore connectivity and check the acknowledged state.

4. **[P2] The Lock Screen accessibility check omits button label readability** —
   [device-checklist.md:86](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:86).
   The check only requires the button row to remain visible at the largest text
   size. The shipped buttons use a single line and a minimum scale factor, so
   the row can remain visible while “Next: Breakfast” or a typed Lap label is
   clipped or unreadable. Require all button labels to remain legible, including
   a representative long label, and verify their VoiceOver names.

## Resolution (round 1)

1. Fixed: the item now says the phone is online, waits about 10 s and refreshes
   the second device before checking it.
2. Fixed: the Resume item resumes once through the toast (same run, total
   carries on, gap pause row) and once through the idle tile.
3. Fixed: the tile Resume is tapped in airplane mode so "Resuming…" without
   controls is observable, then airplane mode off shows the acked card.
4. Fixed: at the largest text size every button label must read in full ("Next:
   Breakfast" as the long one), and the VoiceOver names are checked. That check
   found the shipped Live Activity Stop reads "Stop", not §1.3's "Stop {topic}":
   filed as #143 (t2-followup) and linked from the item.

## Round 2

1. **[P2] The checklist leaves runs open that later checks try to start** —
   [device-checklist.md:105](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:105).
   The Dynamic Island check starts `Dishwasher` but never stops it. The next
   check then says to start `Dishwasher`, and the Timer control check later
   expects it to be idle. Similarly, the lap-fields check leaves `Intervals`
   running before the Dynamic Island check asks to start it. Following the
   checklist in order can put testers in the wrong state and produce false
   failures. Stop each run after the relevant check or explicitly reset the
   topic before the next one.

2. **[P2] The active-card check never exercises its primary control** —
   [device-checklist.md:144](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:144).
   It checks that **Lap → Rest** is displayed, then tests Pause and Stop, but
   never taps Lap or verifies that a lap is recorded and the primary changes to
   **Lap → Run**. A correctly labelled but disconnected or incorrect home-card
   action would pass. Add the tap and verify the resulting run state.

3. **[P2] The killed-app Island repetition does not establish a killed app** —
   [device-checklist.md:117](/Users/richie/code/quickr-worktrees/t2-m2-dev/docs/t2/device-checklist.md:117).
   Immediately before “Repeat once from the expanded Dynamic Island,” the
   instructions open quickR to inspect the table. The repeat does not explicitly
   swipe it away again, so it can pass with the app alive and leave the intended
   killed-app path untested. Specify closing quickR from the app switcher again
   before the Island tap.

## Resolution (round 2)

1. Fixed: the M2 setup says every item starts with every topic idle, and each
   item that leaves a run open ends with an explicit Stop.
2. Fixed: the active-card item taps **Lap → Rest** and checks the clock
   restarts, the badge names `Rest` and the primary reads **Lap → Run**.
3. Fixed: quickR is swiped away again before the Dynamic Island repeat.
