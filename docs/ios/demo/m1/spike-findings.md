# SPIKE findings: logging from a notification action with the app killed

**Work package:** SPIKE (M1, `docs/ios/DAG.md`). **Date:** 2026-10-18.
**Where:** iOS 26.0 simulator (this worktree's clone), Xcode 27.1, against this
worktree's integration stack (`make ios-integration-up`). **Code:**
`ios/App/Notifications/Spike` (DEBUG only, and inert unless a spike run opts in; see "Limits"),
`ios/NotificationService/NotificationService.swift` (DEBUG block),
`ios/UITests/SpikeNotificationTests.swift` (own `Spike` plan),
`ios/AppTests/SpikeCategoryTests.swift`, and
`ios/scripts/spike-{proof.sh,payload.py,coordinator.py}`. **Reproduce:**
`ios/scripts/spike-proof.sh [simulator] [limit seconds]`. It leaves its
artefacts in `ios/build/spike`.

## Result

**A reminder's action logs an entry with the app not running, and the entry
reaches the server.** The entry is written durably first and then flushed, and
the app stays in the background throughout. This held in 4 of 4 runs after the
fixes below: runs 4–6, and run 7 on the merged final SKEL and WATCHDOG base.

| Step                                                                                                      | Observed                                                                                                                                                                                                      |
| --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App setup: connect (§2.1 bootstrap), then register the category via the registry table (§5.2)             | `spike: ready`, with the category id taken from the server's payload ([1](spike/1-app-ready.png))                                                                                                             |
| App terminated (`XCUIApplication.terminate`)                                                              | `notRunning`                                                                                                                                                                                                  |
| `xcrun simctl push` of the payload the scheduler would send (rendered by the backend's own `apns.render`) | Banner "Spike app · Time to log" ([2](spike/2-app-registered-delivered.png))                                                                                                                                  |
| Long-press on the banner                                                                                  | Both actions, **Calm** and **Busy**, appear ([3](spike/3-app-registered-expanded.png))                                                                                                                        |
| Tap **Busy**                                                                                              | iOS launches the app **in the background** (`applicationState == .background`; the XCUITest app state goes from `notRunning` to `background`). The UI never appears ([4](spike/4-app-registered-logged.png)). |
| Handler: validate, look up the registry, open the store, one IMMEDIATE enqueue                            | **137 ms** from the handler's start to the committed `entry.create` (`origin: notification`, `source: ios.notification`)                                                                                      |
| Handler: forced flush, 5 s budget (outbox.md §10)                                                         | `drained`, `acked: 1`, **58 ms** (204 ms for the whole handler, loopback network)                                                                                                                             |
| Server                                                                                                    | `GET /topics/{id}/entries` has the entry: `answers.mood = busy`, `source = ios.notification`, `channel = ios`, `captured_at` = the device time of the tap                                                     |

A short recording of the run is at
[spike/action-from-killed-app.mp4](spike/action-from-killed-app.mp4). It shows
setup, the app being killed, the banner, the expanded actions, the tap, and the
second case.

## Findings

### F1. In these runs, the NSE never ran for `simctl push` on the iOS 26 simulator

This is an **observation from this machine and runtime** (iOS 26.0 simulator,
Xcode 27.1), not a documented limitation. A payload with `"mutable-content": 1` is delivered without launching
`QuickRNotificationService`. The unified log has no process launch and no NSE
log lines, and the spike's `nse.*` events never appear. That held with and
without a category and with and without `quickr`. So the `nse-only` case (a
category that only the NSE would register) shows **no actions**
([5](spike/5-nse-only-delivered.png), [6](spike/6-nse-only-expanded.png)).

- **Consequence:** whether a category registered by the NSE applies to the
  notification it is preparing (notifications.md §6, the "backstop") **can't be
  checked on a simulator**. It moves to checkpoint **D** on a device, together
  with a real APNs delivery.
- Registration from the app (§5.2, the primary path) works on the simulator, as
  the result above shows.

### F2. The simulator holds a full reminder for ~10 s before showing it

A plain alert is presented in about 0.1 s. The real payload (`thread-id`,
`category`, `mutable-content`, `relevance-score`, `quickr`) goes through a
`UserNotificationsCore.IntelligenceActor` pipeline step that waits out a timer:
`Request: Completed` comes after **≈10.0 s**, and the banner appears only then.
Payloads with only some of those fields were delayed similarly; I didn't bisect
further.

- **Consequence for tests:** wait up to 30 s for the banner, then fall back to
  Notification Center. `SpikeNotificationTests` does both.
- **For D:** measure the delay on a device. A 10 s delay before a reminder
  appears would be noticeable, though acceptable for reminders.

### F3. Use the completion-handler `didReceive`, and call the completion on the main thread

The async variant, `userNotificationCenter(_:didReceive:) async`, implemented
`nonisolated` in a `@MainActor` delegate, **crashed the app after every
action**. UIKit hit an `NSAssertionHandler` failure in
`-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]`, with the
crashing frame in the compiler-generated `@objc` thunk of that method. **The
likely cause, inferred and not proven,** is that the thunk calls the completion
from a background executor, and UIKit asserts that it runs on the main thread.

In the same runs, the handler's flush also **stalled for 25–26 s** before
sending, while the process was running (RunningBoard reported `running-active`,
and a `PreventTaskSuspend` assertion was held). The flush ended
`budgetExhausted` with a 5 s budget, or acked late. I didn't isolate the cause
of the stall.

With the completion-handler variant
(`Task { await handle(); await MainActor.run { completion() } }`), both problems
went away: there was no crash, and the flush took 58 ms. The UI test now asserts
that the completion ran on the main thread for every action, including the error
and default ones (`handler.completed` with `mainThread: true`).

### F4. Set the delegate in `didFinishLaunching`

The action's background launch delivers the response only if
`UNUserNotificationCenter.current().delegate` is set before
`application(_:didFinishLaunchingWithOptions:)` returns. In a SwiftUI app that
means a `@UIApplicationDelegateAdaptor`, not a view's `.task`.

`applicationState` is `.background` at that point on **every** launch, including
a normal user launch, so it doesn't tell you why the app launched.

### F5. The tapped notification is already gone when the handler runs

`getDeliveredNotifications` returned 10 delivered notifications (8 of them
quickR's, from earlier pushes), and **none** matched the tapped reminder's
(server, topic). The system had removed it already. §7.1 step 7 still matters
for _other_ reminders of the same topic, such as an older slot.

### F6. Visible actions

- **Banner:** no actions until the user long-presses it.
- **Expanded:** both actions of a 2-option enum show.
- **Not covered on the simulator:** how many of 4 actions show on the Lock
  Screen and in a collapsed banner (§4.1, "two or four visible"). That stays a D
  item.

### F7. The pieces the handler needs all work in a background launch

The App Group store and registry (`StorePartitions.open`, `openStore`),
`Outbox.createEntry` and `Outbox.flush`, and `URLSession` to the server
(127.0.0.1 via the integration proxy) all work in a background launch with no
scene. Opening the store took most of the 137 ms.

Under heavy machine load (run 7, load average about 250), the same steps took
**21 s** from the handler's start to the committed enqueue, and the flush then
took 0.3 s. Nothing failed, but a device's background-launch window (≈30 s) would
leave little margin at that speed. D should measure the handler's time on a
device, and HANDLER should keep the work before the enqueue minimal: open the
registry and store, and nothing else.

### F8. Before first unlock: not testable here

The simulator can't model file protection before first unlock. That remains for
D (open question 3).

## Category ids and the cross-check

- **The spike doesn't hash.** Category ids come from the payload's
  `aps.category`, which the server computes (B7). The actions are rendered from
  `quick_log` following §4.1 and §4.2: one `log` action per enum option,
  identified `q1|server|topic|version|key|o|value`. Number descriptors (which
  need §4.4 `fmt`) and "More…" (the `open` action kind, which the C1 contract
  doesn't have yet) are left out.
- **`SpikeCategoryTests`** checks that the rendering reproduces the
  `notification-vectors.json` `enum-4` and `enum-non-ascii` cases exactly
  (identifiers and titles). It also checks that the category-id literals it
  holds equal those cases' `category_id`, and that a forged topic, version or
  option is refused by the handler's validation.

## Recommendations

**HANDLER (M3)**

- Implement the **completion-handler** `didReceive` and call `completionHandler`
  on the main actor (F3). Add a regression test that runs an action end to end
  (this spike's UI test can become it).
- Set the delegate in the app delegate's `didFinishLaunching` (F4).
- The §7.1 order is right as specified, and it's fast:
  - validate, registry, store, then one enqueue transaction, all before any
    network;
  - then a forced flush with the 5 s budget;
  - 137 ms to durability on the simulator.
- Keep the `beginBackgroundTask`. It costs nothing, and the system's
  `NotificationAction` assertion alone may be shorter on a device.
- Step 7 (remove delivered) should target the _topic's other_ reminders. The
  tapped one is already gone (F5).

**NSE (M3)**

- Keep it as a **backstop only**. Its effect can't be seen on the simulator
  (F1), so D must show whether an NSE-registered category gets its actions on
  the notification being prepared.
- Until D says otherwise, assume it doesn't: **the app's registration after
  every sync (§5.2) has to cover every quick-loggable topic ahead of time.**
- Log NSE timing (registry open, reconcile, register) at D. The spike's DEBUG
  block already logs `nse.start` and `nse.registered`, with milliseconds, to the
  App Group's `spike-log.jsonl`.

**CAT (M3)**

- Registering the full union under the registry's IMMEDIATE transaction, with
  `setNotificationCategories` called inside it, works from the app.
  `SpikeCategories.register` is a minimal reference. The multi-process union
  property is covered by MP's N4.
- CAT must render categories **locally** for every quick-loggable topic after a
  sync, including the §4.3 hash and §4.4 `fmt`, so the ids equal the server's
  `aps.category`. Otherwise, given F1, a reminder arrives with a category nobody
  registered and **shows no actions**. The `nse-only` case above shows exactly
  that.
- Reuse the vector cross-check pattern for the full vector set.

**Checkpoint D** (adds to its list):

- whether the NSE runs for real APNs pushes, and whether its registration
  applies before display (F1);
- the delay before display (F2);
- how many of 4 actions are visible, collapsed and on the Lock Screen (F6);
- the background-launch budget on a device: how long the handler may run (here
  204 ms);
- before first unlock (F8).

## Limits of this spike

**The spike's handler is not a complete §7.1 reference.** It covers steps 1–3,
step 5 (one transaction), step 7 (remove delivered) and step 10 (the forced
5 s flush). It **omits**:

- **step 4's preconditions:** a topic that is tombstoned or **archived** isn't
  rejected; only a topic missing from the store is;
- **step 5's retired-store retry:** it doesn't reopen through the registry and
  retry when the store file was retired by a reset;
- **step 10's condition:** it flushes whichever server's store the action names,
  not only when that store is the **active** one;
- step 6 (the explicit Darwin post; the store's pool posts it on commit), and
  steps 8 and 9 (badge and widgets);
- step 7.3's number text input.

HANDLER must implement all of them.

**The spike is opt-in, even in Debug builds.** It runs only when
`Library/quickr/spike-enabled` exists in the App Group. The app creates that
file when it is launched with `-spikeServer`, and `spike-proof.sh` removes it
when it finishes. Without it, the app installs no notification delegate and
the NSE leaves notifications untouched. The file, not a launch argument, is the
gate, because an action's background launch, and the NSE, get no arguments.

- Simulator only.
- Pushes went through `simctl push`, not APNs, so no NSE ran (F1).
- Enum descriptors only.
- One server; reachable on loopback.
- The run uses the integration stack's proxy.
- Release builds don't contain any of this: every spike source is `#if DEBUG`.
  Debug builds run it only after an explicit opt-in (the App Group marker above).
