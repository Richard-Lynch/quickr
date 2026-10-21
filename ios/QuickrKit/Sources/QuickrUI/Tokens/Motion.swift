#if os(iOS)
import SwiftUI

/// The PWA's motion tokens (`--animate-*`). Use them through `qrAnimation(_:value:)`,
/// ``withQRAnimation(_:reduceMotion:_:)`` or ``QuickrMotion/animation(_:reduceMotion:)`` so Reduce
/// Motion turns them off. Read Reduce Motion with ``QuickrReduceMotion`` (`@QuickrReduceMotion`),
/// never `\.accessibilityReduceMotion` directly, so the UI tests' `-QuickrReduceMotion` applies.
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
        reduceMotion || forcedReduceMotion ? nil : animation
    }

    /// The launch argument that turns Reduce Motion on for the app's own motion (DEBUG builds
    /// only), so a UI test can check the reduced paths: the system setting can't be set from a
    /// test.
    public static let reduceMotionArgument = "-QuickrReduceMotion"

    /// Whether ``reduceMotionArgument`` was passed. Always false in release builds.
    public static let forcedReduceMotion: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(reduceMotionArgument)
        #else
        false
        #endif
    }()
}

/// Reduce Motion as the app's motion honours it: the system setting, or the DEBUG launch
/// argument ``QuickrMotion/reduceMotionArgument``. Use `@QuickrReduceMotion private var
/// reduceMotion` in place of `@Environment(\.accessibilityReduceMotion)`.
@propertyWrapper
public struct QuickrReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system

    public init() {}

    public var wrappedValue: Bool { system || QuickrMotion.forcedReduceMotion }
}

/// `withAnimation` that doesn't animate under Reduce Motion (pass `@QuickrReduceMotion`'s value).
@discardableResult
public func withQRAnimation<Result>(
    _ animation: Animation = .default, reduceMotion: Bool, _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(QuickrMotion.animation(animation, reduceMotion: reduceMotion), body)
}

private struct ReducibleAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @QuickrReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Scales a control down slightly while pressed (the PWA's `active:scale-[0.97]`). No scaling
/// under Reduce Motion.
public struct QuickrPressStyle: ButtonStyle {
    public var scale: CGFloat
    @QuickrReduceMotion private var reduceMotion

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
