# RECORD: deviations from the PWA

The record screen follows the PWA's `RecordPage`: "Same as last time", Details
(captured at, notes, source), Log another, the single-chip auto-save, fix mode,
and the leave guard. `RecordUITests` and the end-to-end suites
(`EndToEndUITests`, `TapCountUITests`) cover them. These are the deliberate
differences:

1. **Back is always quickR's own button.** It goes straight back when nothing has
   changed, and asks "Discard this entry?" when something has, so the leave
   guard is the same as the PWA's. This replaces swapping the system back button
   for a guarded one on the first edit, which needed the navigation bar to change.
   - **Swipes back:** the edge swipe, and iOS 26's swipe from anywhere in the
     content, work only while nothing has changed. With changes they do nothing,
     and the back button asks instead. `testSwipingBackWorksOnlyWithoutChanges`
     covers this.
   - **VoiceOver's escape** (the two-finger scrub) is the same back, guarded the
     same way. XCUITest can't perform it, so it has no UI test.
2. **The leave guard is an alert.** iOS 26 shows a confirmation dialog as a
   popover without its cancel button, so "Discard this entry?" is an alert with
   Discard and Keep editing.
3. **A refused new entry is discarded, as in the PWA, but its errors stay on the
   form.** The full problem from the server marks the fields, and the outbox
   item is removed so it can't come back in the sync sheet. A refusal without
   field errors shows the server's message in a banner.
4. **The Save bar sits on the keyboard frame UIKit reports**, not on SwiftUI's
   keyboard safe area. That safe area lost the keyboard's Next/Done bar whenever
   the form re-rendered (the first keystroke), and the Save bar slid under it
   until the next layout (found by UIT-2's screenshots).
   `testTheSaveBarStaysAboveTheKeyboardAfterTheFirstEdit` guards this.
5. **At accessibility text sizes the Save bar steps aside while the keyboard is
   up**, so the field being typed in stays visible (FORM's note). It comes back
   when the keyboard goes.
