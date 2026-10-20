# RECORD: deviations from the PWA

The record screen follows the PWA's `RecordPage`: "Same as last time", Details
(captured at, notes, source), Log another, the single-chip auto-save, fix mode,
and the leave guard. `RecordUITests` and the end-to-end suites
(`EndToEndUITests`, `TapCountUITests`) cover them. These are the deliberate
differences:

1. **Back is always quickR's own button.** The system back button would have to
   be swapped for a guarded one on the first edit. That swap changed the
   navigation bar while the keyboard was up, and the Save bar then dropped under
   the keyboard's Next/Done until the next layout (found by UIT-2's
   screenshots). The button goes straight back when nothing has changed and asks
   "Discard this entry?" when something has, so the leave guard is the same as
   the PWA's.
   - **Swipes back:** the edge swipe, and iOS 26's swipe from anywhere in the
     content, work only while nothing has changed. With changes they do nothing,
     and the back button asks instead. `testSwipingBackWorksOnlyWithoutChanges`
     covers this.
   - **VoiceOver's escape** (the two-finger scrub) is the same back, guarded the
     same way. XCUITest can't perform it, so it has no UI test.
   - **Save bar:** `testTheSaveBarStaysAboveTheKeyboardAfterTheFirstEdit` keeps
     the bar above the keyboard toolbar.
2. **The leave guard is an alert.** iOS 26 shows a confirmation dialog as a
   popover without its cancel button, so "Discard this entry?" is an alert with
   Discard and Keep editing.
3. **A refused new entry is discarded, as in the PWA, but its errors stay on the
   form.** The full problem from the server marks the fields, and the outbox
   item is removed so it can't come back in the sync sheet. A refusal without
   field errors shows the server's message in a banner.
4. **At accessibility text sizes the Save bar steps aside while the keyboard is
   up**, so the field being typed in stays visible (FORM's note). It comes back
   when the keyboard goes.
