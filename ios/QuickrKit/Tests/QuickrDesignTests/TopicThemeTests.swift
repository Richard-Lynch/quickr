import Foundation
import QuickrCore
import SwiftUI
import Testing

@testable import QuickrUI

/// The theme API of appearance.md §4.1 and the `TopicColors.xcassets` catalogue against the palette
/// of §3.1. M3-TOKENS reads the table copied below; M3-DB repoints `palette` at
/// `shared/fixtures/appearance-vectors.json` once the generator exists.
@Suite(.timeLimit(.minutes(2))) struct TopicThemeTests {
    static let catalog = TokenDriftTests.repo.appending(
        path: "ios/QuickrKit/Sources/QuickrUI/Resources/TopicColors.xcassets")

    struct Swatch {
        let tint: String
        let tintSoft: String
        let onTint: String
    }

    /// appearance.md §3.1, in palette order: name, light, dark.
    static let palette: [(ColorName, light: Swatch, dark: Swatch)] = [
        (
            .red, Swatch(tint: "#c2362b", tintSoft: "#f8dcd8", onTint: "#ffffff"),
            Swatch(tint: "#ff7b6e", tintSoft: "#3b1714", onTint: "#1b0d04")
        ),
        (
            .orange, Swatch(tint: "#c2470a", tintSoft: "#fde4d4", onTint: "#ffffff"),
            Swatch(tint: "#ff7a2e", tintSoft: "#3a2214", onTint: "#1b0d04")
        ),
        (
            .amber, Swatch(tint: "#9e5406", tintSoft: "#fbe7c6", onTint: "#ffffff"),
            Swatch(tint: "#f0a63a", tintSoft: "#3a2a0e", onTint: "#1b1204")
        ),
        (
            .yellow, Swatch(tint: "#f2c230", tintSoft: "#fbf0c4", onTint: "#1b1915"),
            Swatch(tint: "#f5cf4f", tintSoft: "#3a3110", onTint: "#1b1804")
        ),
        (
            .lime, Swatch(tint: "#4f7a0c", tintSoft: "#e6f2cc", onTint: "#ffffff"),
            Swatch(tint: "#a9d64c", tintSoft: "#243410", onTint: "#101a04")
        ),
        (
            .green, Swatch(tint: "#2f7d4f", tintSoft: "#dcefe2", onTint: "#ffffff"),
            Swatch(tint: "#5cc28a", tintSoft: "#173323", onTint: "#04170c")
        ),
        (
            .teal, Swatch(tint: "#19786f", tintSoft: "#d4eeea", onTint: "#ffffff"),
            Swatch(tint: "#4fc4b7", tintSoft: "#113330", onTint: "#04201c")
        ),
        (
            .cyan, Swatch(tint: "#1c7fa3", tintSoft: "#d6ecf5", onTint: "#ffffff"),
            Swatch(tint: "#5cc0e8", tintSoft: "#113040", onTint: "#041a26")
        ),
        (
            .blue, Swatch(tint: "#2f5f8f", tintSoft: "#dce7f2", onTint: "#ffffff"),
            Swatch(tint: "#7fb1e3", tintSoft: "#16283a", onTint: "#071624")
        ),
        (
            .indigo, Swatch(tint: "#4a3aa7", tintSoft: "#e3dff6", onTint: "#ffffff"),
            Swatch(tint: "#9085e9", tintSoft: "#1f1a3d", onTint: "#0d0a24")
        ),
        (
            .violet, Swatch(tint: "#7a3c9e", tintSoft: "#ecdff4", onTint: "#ffffff"),
            Swatch(tint: "#c08ae0", tintSoft: "#2d1a3a", onTint: "#1b0a26")
        ),
        (
            .pink, Swatch(tint: "#b8386e", tintSoft: "#f8dde9", onTint: "#ffffff"),
            Swatch(tint: "#ec84b1", tintSoft: "#3a1728", onTint: "#260a18")
        ),
    ]

    @Test func nilAppearanceIsTheDefaultTheme() {
        let theme = TopicTheme(appearance: nil, name: "Water")
        #expect(theme.tint == TopicTheme.default.tint)
        #expect(theme.tintSoft == TopicTheme.default.tintSoft)
        #expect(theme.onTint == TopicTheme.default.onTint)
        #expect(theme.glyph == nil)
        #expect(TopicTheme.default.glyph == nil)
        #expect(TopicTheme.default.glyph(fallbackInitial: true) == nil)
        let names = TopicTheme.tokenNames(for: nil)
        #expect(names.tint == "accent")
        #expect(names.tintSoft == "accent-soft")
        #expect(names.onTint == "on-accent")
        // The accent tokens are the brand's: `Palette.swift` builds them the same way.
        #expect(TopicTheme.default.tint == Color("accent", bundle: .module))
        #expect(TopicTheme.default.tintSoft == Color("accent-soft", bundle: .module))
        #expect(TopicTheme.default.onTint == Color("on-accent", bundle: .module))
    }

    @Test func colourlessAppearanceWithAnIconKeepsTheAccentTokens() {
        let theme = TopicTheme(appearance: TopicAppearance(icon: .emoji("🚬"), tags: ["habit"]), name: "Smoking")
        #expect(theme.tint == TopicTheme.default.tint)
        #expect(theme.tintSoft == TopicTheme.default.tintSoft)
        #expect(theme.onTint == TopicTheme.default.onTint)
        #expect(theme.glyph == .emoji("🚬"))
        #expect(theme.glyph(fallbackInitial: true) == .emoji("🚬"))
        #expect(theme.glyph(fallbackInitial: false) == .emoji("🚬"))
    }

    @Test func everyColourResolvesInLightAndDark() throws {
        #expect(ColorName.allCases == Self.palette.map(\.0))
        #expect(ColorName.allCases.count == 12)
        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path())
            .filter { $0.hasSuffix(".colorset") }
        #expect(sets.count == 36)

        for (name, light, dark) in Self.palette {
            let names = TopicTheme.tokenNames(for: name)
            #expect(names.tint == "topic-\(name.rawValue)-tint")
            #expect(names.tintSoft == "topic-\(name.rawValue)-soft")
            #expect(names.onTint == "topic-\(name.rawValue)-on")
            let theme = TopicTheme(appearance: TopicAppearance(color: name), name: name.rawValue)
            #expect(theme.tint == Color(names.tint, bundle: .module))
            #expect(theme.tintSoft == Color(names.tintSoft, bundle: .module))
            #expect(theme.onTint == Color(names.onTint, bundle: .module))
            #expect(theme.tint != TopicTheme.default.tint, "\(name) is not the accent")

            let tint = try TokenDriftTests.colorSet(names.tint, in: Self.catalog)
            let soft = try TokenDriftTests.colorSet(names.tintSoft, in: Self.catalog)
            let on = try TokenDriftTests.colorSet(names.onTint, in: Self.catalog)
            #expect(tint.0 == light.tint, "\(name) light tint")
            #expect(soft.0 == light.tintSoft, "\(name) light tintSoft")
            #expect(on.0 == light.onTint, "\(name) light onTint")
            #expect(tint.1 == dark.tint, "\(name) dark tint")
            #expect(soft.1 == dark.tintSoft, "\(name) dark tintSoft")
            #expect(on.1 == dark.onTint, "\(name) dark onTint")
        }
    }

    @Test func onTintOnTintReadsAt4Point5ToOne() {
        for (name, light, dark) in Self.palette {
            #expect(Self.contrast(light.onTint, light.tint) >= 4.5, "\(name) light")
            #expect(Self.contrast(dark.onTint, dark.tint) >= 4.5, "\(name) dark")
        }
    }

    @Test func glyphFallsBackToTheInitial() {
        let water = TopicTheme(appearance: .empty, name: "Water")
        #expect(water.glyph == nil)
        #expect(water.initial == "W")
        #expect(water.glyph(fallbackInitial: true) == .initial("W"))
        #expect(water.glyph(fallbackInitial: false) == nil)
        // One grapheme, not one scalar: a ZWJ family, a flag and a combining sequence each stay whole.
        #expect(TopicTheme(appearance: nil, name: "👨‍👩‍👧 Family").initial == "👨‍👩‍👧")
        #expect(TopicTheme(appearance: nil, name: "🇮🇪 Trip").initial == "🇮🇪")
        #expect(TopicTheme(appearance: nil, name: "e\u{0301}tude").initial == "e\u{0301}")
        #expect(TopicTheme(appearance: nil, name: "  padded").initial == "p")
        #expect(TopicTheme(appearance: nil, name: "").glyph(fallbackInitial: true) == nil)
        // The emoji wins over the initial.
        let themed = TopicTheme(appearance: TopicAppearance(color: .teal, icon: .emoji("💧")), name: "Water")
        #expect(themed.glyph(fallbackInitial: true) == .emoji("💧"))
        #expect(TopicGlyph.emoji("💧").text == "💧")
        #expect(TopicGlyph.initial("W").text == "W")
    }

    @Test func appearanceRoundTripsTheWireShape() throws {
        let json = #"{"color":"red","icon":{"kind":"emoji","value":"🚬"},"tags":["habit","Health"]}"#
        let decoded = try JSONDecoder().decode(TopicAppearance.self, from: Data(json.utf8))
        #expect(decoded == TopicAppearance(color: .red, icon: .emoji("🚬"), tags: ["habit", "Health"]))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        #expect(encoded == expected)

        // The server's defaults, keys present and null; and a missing `tags` reads as empty.
        let empty = try JSONDecoder().decode(
            TopicAppearance.self, from: Data(#"{"color":null,"icon":null,"tags":[]}"#.utf8))
        #expect(empty == .empty)
        let encodedEmpty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? NSDictionary
        #expect(encodedEmpty == ["color": NSNull(), "icon": NSNull(), "tags": []])
        #expect(try JSONDecoder().decode(TopicAppearance.self, from: Data("{}".utf8)) == .empty)

        // Strict: an unknown kind or colour is a decoding error, not a silent default.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                TopicAppearance.self,
                from: Data(#"{"color":null,"icon":{"kind":"symbol","value":"drop"},"tags":[]}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TopicAppearance.self, from: Data(#"{"color":"mauve","icon":null,"tags":[]}"#.utf8))
        }
    }

    /// WCAG 2 contrast ratio of two `#rrggbb` colours.
    static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: String) -> Double {
        let channels = stride(from: 1, to: 7, by: 2).map { i -> Double in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let value = Double(Int(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
