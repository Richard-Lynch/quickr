#if os(iOS)
import SwiftUI

/// Paper with a faint dot grid, like squared notebook paper: `line-strong` dots at 45% opacity,
/// 0.6 pt radius, on an 18 pt pitch (the PWA's `body` background).
public struct DotGridBackground: View {
    public init() {}

    public var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.qr.paper))
            let pitch = QuickrMetrics.gridPitch
            let r: CGFloat = 0.6
            var dots = Path()
            var y = pitch / 2
            while y < size.height {
                var x = pitch / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    x += pitch
                }
                y += pitch
            }
            ctx.fill(dots, with: .color(.qr.lineStrong.opacity(0.45)))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Surface, hairline border, 18 pt continuous corners and the card shadow.
public struct QuickrCardModifier: ViewModifier {
    var border: Color

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: QuickrMetrics.cardRadius, style: .continuous)
        content
            .background(Color.qr.surface, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .qrShadow(.card)
    }
}

extension View {
    /// The dot-grid paper behind a screen.
    public func qrPaperBackground() -> some View {
        background { DotGridBackground() }
    }

    /// Wraps the view in the brand card. `border` defaults to the `line` token.
    public func qrCard(border: Color = .qr.line) -> some View {
        modifier(QuickrCardModifier(border: border))
    }
}

/// A container with the card look and standard padding.
public struct Card<Content: View>: View {
    let padding: CGFloat
    let content: Content

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .qrCard()
    }
}

/// Colour pairs for badges, banners and due states.
public enum QuickrTone: CaseIterable, Sendable {
    case neutral, accent, ok, warn, danger, info

    public var background: Color {
        switch self {
        case .neutral: .qr.sunken
        case .accent: .qr.accentSoft
        case .ok: .qr.okSoft
        case .warn: .qr.warnSoft
        case .danger: .qr.dangerSoft
        case .info: .qr.infoSoft
        }
    }

    public var foreground: Color {
        switch self {
        case .neutral: .qr.inkSoft
        case .accent: .qr.accentStrong
        case .ok: .qr.ok
        case .warn: .qr.warn
        case .danger: .qr.danger
        case .info: .qr.info
        }
    }
}

/// A small pill label, e.g. the tile's due badge ("Overdue · since 7:59 PM").
public struct QuickrBadge: View {
    let text: String
    let icon: QIcon?
    let tone: QuickrTone
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ text: String, icon: QIcon? = nil, tone: QuickrTone = .neutral) {
        self.text = text
        self.icon = icon
        self.tone = tone
    }

    public var body: some View {
        let wraps = typeSize.isAccessibilitySize
        return HStack(alignment: wraps ? .firstTextBaseline : .center, spacing: 4) {
            if let icon { icon.view(size: iconSize, weight: .bold) }
            // One line normally; at accessibility sizes it wraps instead of truncating the time.
            Text(text)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.qr(.caption))
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .padding(.vertical, wraps ? 4 : 0)
        .foregroundStyle(tone.foreground)
        // A wrapped pill would be a blob: a rounded rectangle instead.
        .background(tone.background, in: wraps ? AnyShape(RoundedRectangle(cornerRadius: 10)) : AnyShape(Capsule()))
    }
}

#Preview("Surfaces") {
    VStack(alignment: .leading, spacing: 16) {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Card").font(.qr(.title))
                HStack {
                    QuickrBadge("Overdue · since 7:59 PM", icon: .bell, tone: .danger)
                    QuickrBadge("v3", tone: .neutral)
                }
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qrPaperBackground()
}
#endif
