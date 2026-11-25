import SwiftUI

/// What stands in for a topic before its name (appearance.md, glossary): its emoji, or the name's
/// first grapheme on the tint when it has none.
public enum TopicGlyph: Sendable, Hashable {
    case emoji(String)
    case initial(String)

    /// The text of either case.
    public var text: String {
        switch self {
        case .emoji(let value), .initial(let value): value
        }
    }

    /// The fallback initial: the first grapheme (`Character`) of the trimmed name, "" when there is
    /// none. The PWA's `glyphOf` segments the same way (`Intl.Segmenter`, grapheme granularity).
    public static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? ""
    }
}

#if os(iOS)
/// Draws a topic's glyph: the emoji at `size`, or the initial on a `tint` circle of `size` when the
/// theme has none and `fallbackInitial` is on. Nothing when neither applies. Decorative, like
/// ``QIconView``: the tile or header that shows it already carries the topic's name.
public struct TopicGlyphView: View {
    let theme: TopicTheme
    let size: CGFloat
    let fallbackInitial: Bool

    public init(theme: TopicTheme, size: CGFloat = 22, fallbackInitial: Bool = true) {
        self.theme = theme
        self.size = size
        self.fallbackInitial = fallbackInitial
    }

    public var body: some View {
        switch theme.glyph(fallbackInitial: fallbackInitial) {
        case .emoji(let value)?:
            // Emoji glyphs sit a little inside their box, like SF Symbols do in `QIconView`.
            Text(value)
                .font(.system(size: size * 0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .initial(let value)?:
            Text(value)
                .font(.qr(.displayBold, size: size * 0.52, relativeTo: .body))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(theme.onTint)
                .frame(width: size, height: size)
                .background(theme.tint, in: Circle())
                .accessibilityHidden(true)
        case nil:
            EmptyView()
        }
    }
}

#Preview("Topic glyphs") {
    HStack(spacing: 12) {
        TopicGlyphView(theme: TopicTheme(appearance: .init(icon: .emoji("🚬")), name: "Smoking"))
        TopicGlyphView(theme: TopicTheme(appearance: .init(color: .teal), name: "Water"))
        TopicGlyphView(theme: TopicTheme(appearance: nil, name: "Mood"), size: 28)
        TopicGlyphView(theme: .default, size: 28)
    }
    .padding()
    .background(Color.qr.paper)
}
#endif
