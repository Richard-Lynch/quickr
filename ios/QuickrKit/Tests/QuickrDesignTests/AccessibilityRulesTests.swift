import QuickrUI
import SwiftUI
import Testing

@Suite struct AccessibilityRulesTests {
    @Test func shortChoicesBecomeMenusAtAccessibilitySizes() {
        for size in DynamicTypeSize.allCases {
            let expected: QuickrChoicePresentation = size.isAccessibilitySize ? .menu : .segmented
            #expect(QuickrChoicePresentation(size) == expected, "\(size)")
        }
        #expect(QuickrChoicePresentation(.xxxLarge) == .segmented)
        #expect(QuickrChoicePresentation(.accessibility1) == .menu)
    }

    @Test func anErrorIsFocusedWhenItAppearsOrComesBackForANewAttempt() {
        typealias State = (message: String?, trigger: Int)
        let cases: [(State, State, Bool)] = [
            ((nil, 0), ("Couldn’t save", 0), true),  // appears
            (("Couldn’t save", 0), ("Couldn’t save", 0), false),  // unchanged
            (("Couldn’t save", 0), ("Couldn’t save", 1), true),  // the same error, a new attempt
            (("Couldn’t save", 0), ("Offline", 0), true),  // a different error
            (("Couldn’t save", 0), (nil, 1), false),  // cleared
            ((nil, 0), ("", 1), false),  // empty is no message
        ]
        for (old, new, expected) in cases {
            #expect(QuickrErrorFocusRule.shouldFocus(from: old, to: new) == expected, "\(old) → \(new)")
        }
    }
}
