import QuickrCore
import SwiftUI

// Not iOS-only like the rest of the tokens: it is pure SwiftUI, and QuickrDesignTests checks it on the
// host (nil appearance → the accent tokens, the glyph fallback). The colours resolve lazily, from
// `Colors.xcassets` (accent) or `TopicColors.xcassets` (a palette colour), both in `Bundle.module`.

/// The colours and glyph a topic's appearance resolves to (appearance.md §4.1). `tint` is the fill
/// (buttons, accent bar), `tintSoft` the wash (card background), `onTint` the text on `tint`. Read it
/// from `\.topicTheme`; set it with `.topicTheme(for: topic)`.
///
/// Rules every consumer follows (§4.3): a theme never re-colours `danger`, `warn` or `ok`; text on
/// `tintSoft` is `ink`/`inkSoft`; the default theme is indistinguishable from the untinted UI.
public struct TopicTheme: Sendable, Hashable {
    public var tint: Color
    public var tintSoft: Color
    public var onTint: Color
    /// The emoji, or nil when the topic has none; views may fall back to ``initial``.
    public var glyph: TopicGlyph?
    /// The name's first grapheme, for the fallback glyph ("" for an empty name).
    public var initial: String
    /// The topic has a colour. Without one the theme is the accent, and consumers add no
    /// accent-coloured chrome the untinted UI doesn't draw (§4.3): no always-on bar, no initial.
    public var isTinted: Bool

    /// nil or no colour → the accent tokens; an icon → `.emoji`.
    public init(appearance: TopicAppearance?, name: String) {
        let names = Self.tokenNames(for: appearance?.color)
        tint = Color(names.tint, bundle: .module)
        tintSoft = Color(names.tintSoft, bundle: .module)
        onTint = Color(names.onTint, bundle: .module)
        glyph = appearance?.icon.map { icon in
            switch icon {
            case .emoji(let value): .emoji(value)
            }
        }
        initial = TopicGlyph.initial(of: name)
        isTinted = appearance?.color != nil
    }

    /// Accent, accent-soft, on-accent; no glyph. What a topic without a colour, and every surface
    /// outside a themed subtree, renders with.
    public static let `default` = TopicTheme(appearance: nil, name: "")

    /// The glyph to draw: the emoji, else the initial when `fallbackInitial` (and the name is not
    /// empty), else nothing.
    public func glyph(fallbackInitial: Bool) -> TopicGlyph? {
        if let glyph { return glyph }
        return fallbackInitial && !initial.isEmpty ? .initial(initial) : nil
    }

    /// The colour-set names: the brand accent's in `Colors.xcassets`, or `topic-<name>-tint`,
    /// `topic-<name>-soft`, `topic-<name>-on` in `TopicColors.xcassets`.
    static func tokenNames(for color: ColorName?) -> (tint: String, tintSoft: String, onTint: String) {
        guard let color else { return ("accent", "accent-soft", "on-accent") }
        let name = color.rawValue
        return ("topic-\(name)-tint", "topic-\(name)-soft", "topic-\(name)-on")
    }
}

extension EnvironmentValues {
    /// The theme of the topic a view belongs to; `.default` outside a themed subtree.
    @Entry public var topicTheme: TopicTheme = .default
}

extension View {
    /// Themes this subtree: tiles, cards and buttons below read `\.topicTheme`.
    public func topicTheme(_ theme: TopicTheme) -> some View {
        environment(\.topicTheme, theme)
    }

    /// `TopicTheme(appearance: topic.appearance, name: topic.name)` on this subtree.
    public func topicTheme(for topic: Topic) -> some View {
        topicTheme(TopicTheme(appearance: topic.appearance, name: topic.name))
    }
}
