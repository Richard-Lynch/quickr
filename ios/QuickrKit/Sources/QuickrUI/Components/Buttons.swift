#if os(iOS)
import SwiftUI

/// The PWA's button variants (`frontend/src/components/ui/Button.tsx`).
public enum QuickrButtonVariant: Sendable {
    case primary
    case secondary
    case ghost
    case danger
    case quietDanger
}

/// Heights 36, 44 and 56 pt (`sm`, `md`, `lg`), and 72 pt (`hero`): the run screen's primary
/// (active-surfaces.md §2.2, §8.1).
public enum QuickrButtonSize: Sendable {
    case small
    case medium
    case large
    case hero

    public var height: CGFloat {
        switch self {
        case .small: 36
        case .medium: 44
        case .large: 56
        case .hero: 72
        }
    }

    var padding: CGFloat {
        switch self {
        case .small: 14
        case .medium: 20
        case .large: 28
        case .hero: 32
        }
    }

    var font: Font {
        switch self {
        case .small: .qr(.sansSemiBold, size: 14, relativeTo: .subheadline)
        case .medium: .qr(.callout)
        case .large: .qr(.sansSemiBold, size: 16, relativeTo: .body)
        case .hero: .qr(.sansSemiBold, size: 22, relativeTo: .title2)
        }
    }

    /// The icon beside the label (`PrimaryButton`).
    var iconSize: CGFloat {
        switch self {
        case .small: 16
        case .medium, .large: 20
        case .hero: 28
        }
    }

    /// Large and hero buttons fill their row.
    var fillsWidth: Bool { self == .large || self == .hero }
}

/// Capsule buttons in the brand's variants: `.buttonStyle(.qr(.primary, size: .large))`. The
/// primary fills with `\.topicTheme`'s `tint` and `onTint` (appearance.md §6.2, §6.4), which are the
/// accent's outside a themed subtree.
public struct QuickrButtonStyle: ButtonStyle {
    let variant: QuickrButtonVariant
    let size: QuickrButtonSize
    @Environment(\.topicTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @QuickrReduceMotion private var reduceMotion

    public init(_ variant: QuickrButtonVariant = .secondary, size: QuickrButtonSize = .medium) {
        self.variant = variant
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(size.font)
            // One line, except at accessibility sizes, where a label wraps rather than clips. The
            // hero takes two lines at every size and grows with them (active-surfaces.md §2.3).
            .lineLimit(size == .hero ? 2 : typeSize.isAccessibilitySize ? 3 : 1)
            .minimumScaleFactor(size == .hero ? 0.8 : 1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, size.padding)
            .frame(minHeight: size.height)
            .foregroundStyle(foreground)
            .background(background(pressed: pressed), in: Capsule())
            .overlay {
                if variant == .secondary { Capsule().strokeBorder(Color.qr.lineStrong, lineWidth: 1) }
            }
            .shadow(color: variant == .primary ? .black.opacity(0.15) : .clear, radius: 0, y: 1)
            // The small size looks 36 pt but takes (and lays out) a 44 × 44 pt hit area, so it
            // never overlaps a neighbour's target.
            .frame(minWidth: QuickrMetrics.tapTarget, minHeight: QuickrMetrics.tapTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : QuickrMotion.press, value: pressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: TopicChrome(theme).onPrimary
        case .secondary: .qr.ink
        case .ghost: .qr.inkSoft
        case .danger: .white
        case .quietDanger: .qr.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: TopicChrome(theme).primaryFill(pressed: pressed)
        case .secondary: pressed ? .qr.sunken : .qr.surface
        case .ghost: pressed ? .qr.sunken : .clear
        case .danger: .qr.danger
        case .quietDanger: pressed ? .qr.dangerSoft : .clear
        }
    }
}

extension ButtonStyle where Self == QuickrButtonStyle {
    public static func qr(_ variant: QuickrButtonVariant = .secondary, size: QuickrButtonSize = .medium) -> Self {
        QuickrButtonStyle(variant, size: size)
    }
}

/// The main call to action: an accent capsule with an optional icon and a busy state.
public struct PrimaryButton: View {
    let title: String
    let icon: QIcon?
    let size: QuickrButtonSize
    let isLoading: Bool
    let action: () -> Void

    public init(
        _ title: String, icon: QIcon? = nil, size: QuickrButtonSize = .large, isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(.qr.onAccent)
                } else if let icon {
                    icon.view(size: size.iconSize, weight: .bold)
                }
                Text(title)
            }
            .frame(maxWidth: size.fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.qr(.primary, size: size))
        .disabled(isLoading)
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

/// A round 44 pt (or 36 pt to look at, still 44 pt to tap) icon-only button, e.g. the header's
/// settings and add buttons. The icon and both sizes grow with Dynamic Type.
public struct QuickrIconButton: View {
    let icon: QIcon
    let label: String
    let bordered: Bool
    let small: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var tapSide = QuickrMetrics.tapTarget
    @ScaledMetric(relativeTo: .body) private var smallSide: CGFloat = 36

    public init(_ icon: QIcon, label: String, bordered: Bool = false, small: Bool = false, action: @escaping () -> Void)
    {
        self.icon = icon
        self.label = label
        self.bordered = bordered
        self.small = small
        self.action = action
    }

    private var size: CGFloat { small ? smallSide : tapSide }

    public var body: some View {
        Button(action: action) {
            icon.view(size: iconSize)
                .frame(width: size, height: size)
                .foregroundStyle(.qr.inkSoft)
                .background(bordered ? Color.qr.surface : .clear, in: Circle())
                .overlay { if bordered { Circle().strokeBorder(Color.qr.lineStrong, lineWidth: 1) } }
                .frame(width: tapSide, height: tapSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickrPressStyle(scale: 0.95))
        .accessibilityLabel(label)
    }
}

#Preview("Buttons") {
    VStack(spacing: 12) {
        PrimaryButton("Lap", icon: .flag, size: .hero) {}
        PrimaryButton("Save", icon: .check) {}
        HStack {
            Button("Small") {}.buttonStyle(.qr(.primary, size: .small))
            Button("Medium") {}.buttonStyle(.qr(.secondary))
            Button("Ghost") {}.buttonStyle(.qr(.ghost))
        }
        HStack {
            Button("Delete") {}.buttonStyle(.qr(.danger))
            Button("Discard") {}.buttonStyle(.qr(.quietDanger))
            QuickrIconButton(.plus, label: "New topic", bordered: true) {}
            QuickrIconButton(.settings, label: "Settings") {}
        }
    }
    .padding()
    .background(Color.qr.paper)
}
#endif
