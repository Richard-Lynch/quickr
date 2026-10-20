#if os(iOS)
import SwiftUI

/// The "field notebook" colour tokens from `frontend/src/index.css`, as asset-catalog colours
/// (`Resources/Colors.xcassets`) with light and dark appearances.
///
/// Use them anywhere a `Color` or `ShapeStyle` goes: `.foregroundStyle(.qr.ink)`,
/// `.background(Color.qr.paper)`.
public struct QuickrPalette: Sendable {
    public var paper: Color { token("paper") }
    public var surface: Color { token("surface") }
    public var sunken: Color { token("sunken") }
    public var ink: Color { token("ink") }
    public var inkSoft: Color { token("ink-soft") }
    public var muted: Color { token("muted") }
    public var line: Color { token("line") }
    public var lineStrong: Color { token("line-strong") }
    public var accent: Color { token("accent") }
    public var accentStrong: Color { token("accent-strong") }
    public var accentSoft: Color { token("accent-soft") }
    public var onAccent: Color { token("on-accent") }
    public var ok: Color { token("ok") }
    public var okSoft: Color { token("ok-soft") }
    public var warn: Color { token("warn") }
    public var warnSoft: Color { token("warn-soft") }
    public var danger: Color { token("danger") }
    public var dangerSoft: Color { token("danger-soft") }
    public var info: Color { token("info") }
    public var infoSoft: Color { token("info-soft") }

    /// Chart series 1–6 in their validated categorical order; wraps past 6.
    public func series(_ n: Int) -> Color {
        token("series-\((max(n, 1) - 1) % 6 + 1)")
    }

    /// Every token by its CSS name, in `index.css` order (for the catalogue).
    public static let tokenNames = [
        "paper", "surface", "sunken", "ink", "ink-soft", "muted", "line", "line-strong",
        "accent", "accent-strong", "accent-soft", "on-accent",
        "ok", "ok-soft", "warn", "warn-soft", "danger", "danger-soft", "info", "info-soft",
        "series-1", "series-2", "series-3", "series-4", "series-5", "series-6",
    ]

    /// A token by its CSS name (without `--color-`).
    public func token(_ name: String) -> Color {
        Color(name, bundle: .module)
    }
}

extension ShapeStyle where Self == Color {
    /// The brand palette: `Color.qr.accent`, or `.qr.accent` where a style is expected.
    public static var qr: QuickrPalette { QuickrPalette() }
}
#endif
