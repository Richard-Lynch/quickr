# Review of PLAN.md draft v1: Fable (adversarial sub-agent)

This is a condensed record of the review. Every finding is kept; the wording is
shortened.

**Verdict:** The architecture is sound. However, the plan's premise that work
can start now and be tested on the host is false on this Mac. The outbox is
presented as a port but is really a new design. Four platform assumptions are
wrong or unverified: the notification action count, Xcode pinning, where
`AppShortcutsProvider` lives, and the Action button hardware.

## Blockers

1. **"M0/M1 blocked by: none (host tests)" is false.** On this Mac (Command Line
   Tools 16.4, Swift 6.1.2), every `swift package dump-package` and `swift test`
   fails at manifest link time with
   `Undefined symbols: PackageDescription.Package.__allocating_init`.
   Separately, `.iOS(.v26)` and `.macOS(.v15)` need tools-version 6.2, which
   means Xcode 26 or later. Swift Testing is present but that doesn't help.
   **Fix:**
   - Make H1 and H2 the first human steps.
   - Do the B1–B3 backend work in the meantime.
   - Don't write Swift blind and debug it through CI. An Ubuntu Swift job for
     the GRDB-free targets is optional.
2. **The notification category design exceeds what iOS shows.** Up to 6 options
   plus "Open" is 7 actions. iOS shows at most **4** in the expanded
   notification and 2 in the banner (Apple forum 4368, Kodeco, OneSignal).
   **Fix:** design for 4.
3. **The outbox is not a "1:1 port".** The PWA outbox has exactly one kind,
   `entry.create` (`frontend/src/lib/outbox/kinds.ts:51`). It has no update or
   delete, no coalescing, no undo rules and no leases. `outbox.test.ts` has 18
   cases. **Fix:** write the outbox rules as a spec with their own test matrix,
   and resize M1 to XL.

## Major

1. **Xcode pinning can't match.** The CI `macos-26` image has Xcode 26.5/26.6
   (iOS 26 SDK, Swift 6.3). Locally we'll have Xcode 27.x. Xcode 27 is only
   available on the preview `xcode-27` runner label. **Fix:** use `xcode-27` if
   it is generally available, or state the rule explicitly: iOS 26 deployment
   target, no iOS 27-only API, tools-version 6.2.
2. **`AppShortcutsProvider` must live in the app target** (forums 759160 and
   764792). The static-vs-dynamic linking caveat also applies. **Fix:** put the
   provider and its phrases in `App/`, and prove intents resolve from both the
   app and the widget in the M2 skeleton.
3. **The Action button needs an iPhone 15 Pro or later.** **Fix:** ask for the
   phone model in H5. If the phone has no Action button, declare the feature
   infeasible.
4. **Sync and tombstone edge cases are unspecified:**
   - **Zombie entries.** A web delete combined with a pending update makes the
     PATCH return 404, and the entry becomes a zombie. **Fix:** a 404 on update
     or delete drops the local row and the outbox item.
   - **Topic tombstones** must cancel that topic's pending items, notification
     categories and widget configs.
   - **Python wall-clock writes** also happen in `topics.py:403`
     (`publish_version`), not just `entries.py:187`.
   - **`resync_required` wipe** with a pending outbox has no defined behaviour.
5. **Value arrives too late, and M2 is too big.** **Fix:**
   - Reorder to M2 → M5 → M6 → M3 → M4.
   - Run the notification device spikes on the first day a device is available.
   - Split M2.
6. **CI budget.** Debugging compile errors through CI would burn about 200 macOS
   minutes a month within days. **Fix:**
   - Compile locally.
   - Download xcodegen as a binary instead of `brew install`.
   - Run `swift test` on push, and run the full `xcodebuild test` only on
     ready-for-review or manual dispatch.
   - Confirm the GitHub plan tier.
7. **The APNs `badge` field has no data source.** The server has no due count,
   and the device sets the badge too, so there are two writers. **Fix:** set it
   on the device only.

## Minor

- **APNs environment.** Read the environment from `embedded.mobileprovision`
  instead of `#if DEBUG`.
- **"collapse-id = request identifier" is forum lore.** Remove delivered
  notifications by `userInfo` topic id. Also, the category id naming differs
  between the research and the plan; pick one.
- **`swift test` on macOS builds every target**, including iOS-only ones. Use
  `#if os(iOS)` or split the package.
- **`reloadAllTimelines()` after every write** will exhaust the widget reload
  budget. Reload only when due state or last values change.
- **`pending-logs.jsonl` is unnecessary.** `didReceive` runs in the app process,
  which can migrate.
- **`BGAppRefreshTask`** needs plist keys and is best-effort. A
  `content-available` push is cheaper.
- **Testing the phone against the Mac's docker stack** needs
  `NSAllowsLocalNetworking`, the LAN IP and `http://`. The plan also never says
  how the `.p8` key reaches docker.
- **M0 and M1 have no demo media.** State this as a deviation. Also put the PWA
  parity limits in the plan: iOS Safari push has no actions, and Chromium shows
  at most 2.
- **`conftest` TABLES** must gain the new tables. Plan an explicit downgrade
  test for the enum.

## Missing

- Phone model, notification-permission UX, and registering categories before
  permission is granted.
- What a server-URL change or reset does.
- Keychain access-group entitlements, a committed `Package.resolved`, and the
  NSE limits (24 MB, 30 s).
- NSE behaviour before first unlock.
- Per-entity ordering across processes.
- An explicit list of infeasible requirements.

## Simplifications

1. Keep tombstones forever and drop retention and `resync_required`.
2. Use 3 SPM targets instead of 6.
3. Trim M6: drop `TopicOptionEntity`, Spotlight, `UndoableIntent` and the widget
   stepper.
4. Cut JWT verification, chart screenshot comparison and snapshot tests. Keep
   one of fixtures or the integration test as the drift mechanism.
5. Use a single `flush_lock` row instead of per-item leases plus
   compare-and-set.
