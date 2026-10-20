#if os(iOS)
import SwiftUI

/// The app's haptic vocabulary, played with `sensoryFeedback`. Keep it sparse: one haptic per
/// user action, none for passive updates.
public enum QuickrHaptic: Sendable {
    /// An entry was logged (chip, ✓, Save).
    case logged
    /// A chip was selected or deselected on the record screen.
    case selection
    /// The stepper moved up or down.
    case increase
    case decrease
    /// An undo or discard went through.
    case undo
    /// Something was rejected (validation, a failed save).
    case failure

    public var feedback: SensoryFeedback {
        switch self {
        case .logged: .success
        case .selection: .selection
        case .increase: .increase
        case .decrease: .decrease
        case .undo: .impact(weight: .light)
        case .failure: .error
        }
    }
}

extension View {
    /// Plays `haptic` whenever `trigger` changes.
    public func qrHaptic<T: Equatable>(_ haptic: QuickrHaptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }

    /// Plays `haptic` when `trigger` changes and `condition(old, new)` holds.
    public func qrHaptic<T: Equatable>(
        _ haptic: QuickrHaptic, trigger: T, condition: @escaping (T, T) -> Bool
    ) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger, condition: condition)
    }
}
#endif
