#if os(iOS)
import SwiftUI

/// Sizes and radii shared with the PWA (CSS px map 1:1 to points on iPhone).
public enum QuickrMetrics {
    /// Cards and tiles (`--radius-card`, 1.125rem).
    public static let cardRadius: CGFloat = 18
    /// Record-screen chips, toasts and banners (Tailwind `rounded-2xl`).
    public static let chipRadius: CGFloat = 16
    /// Number fields, stepper buttons and tile chips (`rounded-xl`).
    public static let controlRadius: CGFloat = 12
    /// The minimum tap target.
    public static let tapTarget: CGFloat = 44
    /// Record-screen chips and stepper buttons.
    public static let chipHeight: CGFloat = 52
    /// The dot grid's pitch.
    public static let gridPitch: CGFloat = 18
    /// The tile's Log block.
    public static let logBlockWidth: CGFloat = 84
}

/// `--shadow-card` and `--shadow-float`, which differ by appearance.
public enum QuickrShadow {
    case card
    case float
}

private struct QuickrShadowModifier: ViewModifier {
    let kind: QuickrShadow
    let isActive: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // Scaling the opacity (not dropping the modifier) keeps view identity when it toggles.
        let on: Double = isActive ? 1 : 0
        let ink = Color(red: 27 / 255, green: 25 / 255, blue: 21 / 255)
        switch (kind, scheme) {
        case (.card, .dark):
            content.shadow(color: .black.opacity(0.3 * on), radius: 0, y: 1)
        case (.card, _):
            content
                .shadow(color: ink.opacity(0.04 * on), radius: 0, y: 1)
                .shadow(color: ink.opacity(0.06 * on), radius: 1, y: 1)
        case (.float, .dark):
            content.shadow(color: .black.opacity(0.7 * on), radius: 12, y: 12)
        case (.float, _):
            content
                .shadow(color: ink.opacity(0.35 * on), radius: 10, y: 10)
                .shadow(color: ink.opacity(0.12 * on), radius: 3, y: 2)
        }
    }
}

extension View {
    /// The brand's card or floating shadow for the current appearance; `isActive: false` hides it.
    public func qrShadow(_ kind: QuickrShadow, isActive: Bool = true) -> some View {
        modifier(QuickrShadowModifier(kind: kind, isActive: isActive))
    }
}
#endif
