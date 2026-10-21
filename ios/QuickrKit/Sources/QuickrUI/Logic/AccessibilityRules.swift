import SwiftUI

/// How a short choice (tabs, a schedule kind, Edit/Preview) is presented: segments, or a menu at
/// accessibility text sizes, where a segmented control stops growing and truncates.
public enum QuickrChoicePresentation: Sendable, Hashable {
    case segmented
    case menu

    public init(_ typeSize: DynamicTypeSize) {
        self = typeSize.isAccessibilitySize ? .menu : .segmented
    }
}

/// When `.qrAnnouncesError` moves VoiceOver to an error: each time a message appears, and again
/// when the same message comes back for a new attempt (`trigger` changed), never when it clears.
/// (The modifier runs once per distinct `(message, trigger)`, as `from: (nil, trigger)`.)
public enum QuickrErrorFocusRule {
    public static func shouldFocus<Trigger: Equatable>(
        from old: (message: String?, trigger: Trigger), to new: (message: String?, trigger: Trigger)
    ) -> Bool {
        guard let message = new.message, !message.isEmpty else { return false }
        return message != old.message || new.trigger != old.trigger
    }
}
