#if os(iOS)
import SwiftUI

/// A segmented picker that becomes a menu at accessibility text sizes (``QuickrChoicePresentation``),
/// for tabs and short choices. Put the accessibility identifier on it as on a `Picker`; UI tests
/// find it as a segmented control, or as a button at AX sizes.
public struct QuickrSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    /// The selected option's text, which a menu picker can't read from its content.
    let valueLabel: String?
    let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `valueLabel` comes before the content so a trailing closure still fills it.
    public init(
        _ title: String, selection: Binding<Selection>, valueLabel: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._selection = selection
        self.valueLabel = valueLabel
        self.content = content()
    }

    public var body: some View {
        switch QuickrChoicePresentation(typeSize) {
        case .segmented:
            Picker(title, selection: $selection) { content }.pickerStyle(.segmented)
        case .menu:
            let menu = Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .tint(.qr.ink)
                .frame(minHeight: QuickrMetrics.tapTarget)
            // A segmented control reports its selected segment itself; a menu's button doesn't.
            if let valueLabel {
                menu.accessibilityValue(valueLabel)
            } else {
                menu
            }
        }
    }
}

/// Posts VoiceOver announcements for changes that have no element to focus (a status line, a
/// finished sync). A no-op without VoiceOver.
public enum QuickrAnnouncer {
    public static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

private struct ErrorFocus<Trigger: Equatable>: ViewModifier {
    let message: String?
    let trigger: Trigger
    @AccessibilityFocusState(for: .voiceOver) private var focused: Bool

    /// A heuristic: long enough for a view inserted with the error to reach the accessibility
    /// tree (and a scroll to it to start). Not a guarantee; device D checks it.
    static var settle: Duration { .milliseconds(150) }

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($focused)
            // One request per (message, trigger): a new one cancels the last, and leaving the
            // screen cancels it, so a stale request never moves focus.
            .task(id: ErrorKey(message: message, trigger: trigger)) {
                guard QuickrErrorFocusRule.shouldFocus(from: (nil, trigger), to: (message, trigger)) else { return }
                focused = false  // a repeat of the same error is a new focus change, read again
                do { try await Task.sleep(for: Self.settle) } catch { return }
                focused = true
            }
    }
}

private struct ErrorKey<Trigger: Equatable>: Equatable {
    var message: String?
    var trigger: Trigger
}

extension View {
    /// Moves VoiceOver to this view (an error banner, or a field's error text) whenever `message`
    /// appears, so the error is read at once instead of after the rest of the screen. VoiceOver
    /// reads the element's own label, so put the modifier on the view that shows the message.
    /// Pass a `trigger` that changes per attempt (a save counter) so a repeated identical error
    /// is read again. Does nothing without VoiceOver.
    public func qrAnnouncesError<Trigger: Equatable>(_ message: String?, trigger: Trigger) -> some View {
        modifier(ErrorFocus(message: message, trigger: trigger))
    }

    /// ``qrAnnouncesError(_:trigger:)`` for an error that is read again only when its text changes.
    public func qrAnnouncesError(_ message: String?) -> some View {
        modifier(ErrorFocus(message: message, trigger: 0))
    }
}
#endif
