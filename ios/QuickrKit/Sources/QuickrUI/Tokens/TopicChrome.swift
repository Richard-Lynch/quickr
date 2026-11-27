import SwiftUI

// Not iOS-only, like `TopicTheme`: QuickrDesignTests checks on the host that the default theme
// gives exactly the accent tokens the surfaces drew before themes (appearance.md §4.3).

/// The accent-coloured chrome a topic's surfaces draw from its theme (appearance.md §6.1, §6.2,
/// §6.4–§6.6): the tile's bar, border and action block, the primary button and the widgets' and
/// Live Activity's fills. On ``TopicTheme/default`` every value is the accent token it replaces.
public struct TopicChrome: Sendable, Hashable {
    public let theme: TopicTheme

    public init(_ theme: TopicTheme) {
        self.theme = theme
    }

    /// The tile's leading bar: a due tile's, as before themes, and always on a topic with a
    /// colour, so its colour shows at rest. A topic without one adds no bar (§4.3).
    public func showsBar(isDue: Bool) -> Bool { isDue || theme.isTinted }

    /// The bar's colour.
    public var bar: Color { theme.tint }

    /// A due tile's border; nil for the plain `line` border.
    public func border(isDue: Bool) -> Color? { isDue ? theme.tint.opacity(0.45) : nil }

    /// A primary fill (buttons, the tile's loud block, the widget's primary chip): the accent and
    /// accent-strong when pressed on the default theme; a palette colour has no strong shade, so
    /// pressed dims its `tint`.
    public func primaryFill(pressed: Bool = false) -> Color {
        guard theme.isTinted else { return Self.token(pressed ? "accent-strong" : "accent") }
        return pressed ? theme.tint.opacity(0.85) : theme.tint
    }

    /// Text and icons on ``primaryFill(pressed:)``.
    public var onPrimary: Color { theme.onTint }

    /// The soft fill (the tile's quiet block, a card's wash).
    public var softFill: Color { theme.tintSoft }

    /// Text and icons on ``softFill``: the accent-strong as before themes; `ink` on a palette
    /// colour's wash (§4.3: text on `tintSoft` is `ink`/`inkSoft`).
    public var onSoft: Color { Self.token(theme.isTinted ? "ink" : "accent-strong") }

    /// The glyph before a topic's name: its emoji, or its initial when it has a colour (§4.3).
    public var glyph: TopicGlyph? { theme.glyph(fallbackInitial: theme.isTinted) }

    /// A `Colors.xcassets` token (`QuickrPalette`'s, which is iOS-only).
    static func token(_ name: String) -> Color { Color(name, bundle: .module) }
}
