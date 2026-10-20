# RECORD: deviations from the PWA

The record screen follows the PWA's `RecordPage`: "Same as last time", Details
(captured at, notes, source), Log another, the single-chip auto-save, fix mode,
and the leave guard. `RecordUITests` and the end-to-end suites
(`EndToEndUITests`, `TapCountUITests`) cover them. These are the deliberate
differences:

1. **Back is the system's until something changes.** While nothing has changed,
   the system back button and its swipes (the edge swipe, and the swipe from
   anywhere in the content on iOS 26 and 27) go straight back. Once something has
   changed, a guarded back takes its place and asks "Discard this entry?", so the
   leave guard is the same as the PWA's. With the system button hidden, UIKit
   turns the swipes off. (A guarded button kept the whole time loses the content
   swipe on iOS 27, which gives none to a screen whose back button is hidden.)
   - **Tests:** `testAContentSwipeGoesBackFromACleanForm`,
     `testAContentSwipeKeepsAChangedForm`, `testSwipingBackWorksOnlyWithoutChanges`
     and `testTheSwipeGuardSurvivesLeavingAndComingBack`, on iOS 26 and 27.
   - **VoiceOver's escape** (the two-finger scrub) is the same guarded back.
     XCUITest can't perform it, so it has no UI test.
2. **The leave guard is an alert.** iOS 26 shows a confirmation dialog as a
   popover without its cancel button, so "Discard this entry?" is an alert with
   Discard and Keep editing.
3. **A refused new entry is discarded, as in the PWA, but its errors stay on the
   form.** The full problem from the server marks the fields, and the outbox
   item is removed so it can't come back in the sync sheet. A refusal without
   field errors shows the server's message in a banner.
4. **While the keyboard is up, Save is in the keyboard's toolbar** (next to
   Next/Done), and the sticky Save bar shows only with the keyboard down. The
   PWA keeps its sticky bar above the keyboard. On iOS, a bar of our own above
   the keyboard slid under Next/Done whenever the form re-rendered (SwiftUI's
   keyboard safe area dropped the toolbar; found by UIT-2's screenshots). The
   toolbar is the native place for it, and it keeps the field being typed in
   visible at every text size, which covers FORM's accessibility-size note.
   Tap counts don't change: Save is one tap either way.
   `formSaveBar` (QuickrUI/Form) does this for every form screen;
   `testSaveIsInTheKeyboardToolbarWhileTyping` guards it.
