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

/// Heights 36, 44 and 56 pt (`sm`, `md`, `lg`).
public enum QuickrButtonSize: Sendable {
    case small
    case medium
    case large

    public var height: CGFloat {
        switch self {
        case .small: 36
        case .medium: 44
        case .large: 56
        }
    }

    var padding: CGFloat {
        switch self {
        case .small: 14
        case .medium: 20
        case .large: 28
        }
    }

    var font: Font {
        switch self {
        case .small: .qr(.sansSemiBold, size: 14, relativeTo: .subheadline)
        case .medium: .qr(.callout)
        case .large: .qr(.sansSemiBold, size: 16, relativeTo: .body)
        }
    }
}

/// Capsule buttons in the brand's variants: `.buttonStyle(.qr(.primary, size: .large))`.
public struct QuickrButtonStyle: ButtonStyle {
    let variant: QuickrButtonVariant
    let size: QuickrButtonSize
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
            // One line, except at accessibility sizes, where a label wraps rather than clips.
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
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
        case .primary: .qr.onAccent
        case .secondary: .qr.ink
        case .ghost: .qr.inkSoft
        case .danger: .white
        case .quietDanger: .qr.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? .qr.accentStrong : .qr.accent
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
                    icon.view(size: size == .small ? 16 : 20, weight: .bold)
                }
                Text(title)
            }
            .frame(maxWidth: size == .large ? .infinity : nil)
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
