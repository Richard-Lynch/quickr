#if os(iOS)
import SwiftUI

/// The PWA's motion tokens (`--animate-*`). Use them through `qrAnimation(_:value:)`
/// or ``QuickrMotion/animation(_:reduceMotion:)`` so Reduce Motion turns them off.
public enum QuickrMotion {
    /// Toasts and new content rising into place (0.35 s, `cubic-bezier(0.2, 0.8, 0.2, 1)`).
    public static let rise = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.35)
    /// Fades (0.2 s ease-out).
    public static let fade = Animation.easeOut(duration: 0.2)
    /// Sheets sliding up (0.28 s).
    public static let sheet = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    /// Press feedback and colour changes (0.15 s).
    public static let press = Animation.easeOut(duration: 0.15)

    /// The animation, or nil under Reduce Motion.
    public static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct ReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Scales a control down slightly while pressed (the PWA's `active:scale-[0.97]`). No scaling
/// under Reduce Motion.
public struct QuickrPressStyle: ButtonStyle {
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(scale: CGFloat = 0.97) {
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(reduceMotion ? nil : QuickrMotion.press, value: configuration.isPressed)
    }
}

extension View {
    /// `.animation(_:value:)` that turns off under Reduce Motion.
    public func qrAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReducibleAnimation(animation: animation, value: value))
    }
}
#endif
