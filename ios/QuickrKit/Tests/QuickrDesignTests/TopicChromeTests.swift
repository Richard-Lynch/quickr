import QuickrCore
import SwiftUI
import Testing

@testable import QuickrUI

/// T2-WIRE: the chrome the tile, primary buttons, widgets and the Live Activity draw from a topic's
/// theme (appearance.md §6). The default theme is the accent tokens they drew before themes (§4.3).
@Suite struct TopicChromeTests {
    static func token(_ name: String) -> Color { Color(name, bundle: .module) }

    @Test func theDefaultThemeIsTheAccentChrome() {
        for theme in [
            TopicTheme.default, TopicTheme(appearance: .init(icon: .emoji("🚿"), tags: ["Home"]), name: "Bath"),
        ] {
            let chrome = TopicChrome(theme)
            #expect(chrome.primaryFill() == Self.token("accent"))
            #expect(chrome.primaryFill(pressed: true) == Self.token("accent-strong"))
            #expect(chrome.onPrimary == Self.token("on-accent"))
            #expect(chrome.softFill == Self.token("accent-soft"))
            #expect(chrome.onSoft == Self.token("accent-strong"))
            #expect(chrome.bar == Self.token("accent"))
            #expect(chrome.showsBar(isDue: true))
            #expect(!chrome.showsBar(isDue: false), "no bar at rest without a colour")
            #expect(chrome.border(isDue: false) == nil)
            #expect(chrome.border(isDue: true) == Self.token("accent").opacity(0.45))
        }
    }

    @Test func aColouredThemeFillsWithItsTint() {
        let theme = TopicTheme(appearance: .init(color: .teal), name: "Water")
        let chrome = TopicChrome(theme)
        #expect(chrome.primaryFill() == Self.token("topic-teal-tint"))
        #expect(chrome.primaryFill(pressed: true) == Self.token("topic-teal-tint").opacity(0.85))
        #expect(chrome.onPrimary == Self.token("topic-teal-on"))
        #expect(chrome.softFill == Self.token("topic-teal-soft"))
        #expect(chrome.onSoft == Self.token("ink"), "text on tintSoft is ink (§4.3)")
        #expect(chrome.bar == Self.token("topic-teal-tint"))
        #expect(chrome.showsBar(isDue: false), "a coloured tile shows its bar at rest")
        #expect(chrome.border(isDue: true) == Self.token("topic-teal-tint").opacity(0.45))
    }

    @Test func theGlyphFallsBackToTheInitialOnlyWithAColour() {
        #expect(TopicChrome(TopicTheme(appearance: nil, name: "Mood")).glyph == nil)
        #expect(TopicChrome(TopicTheme(appearance: .init(icon: .emoji("🙂")), name: "Mood")).glyph == .emoji("🙂"))
        #expect(TopicChrome(TopicTheme(appearance: .init(color: .blue), name: "Mood")).glyph == .initial("M"))
        #expect(
            TopicChrome(TopicTheme(appearance: .init(color: .blue, icon: .emoji("🙂")), name: "Mood")).glyph
                == .emoji("🙂"))
    }
}

/// A tile's tag chips (appearance.md §5): three, then "+N".
@Suite struct TileTagsTests {
    @Test func atMostThreeChipsThenTheRestAsPlusN() {
        let none = TileTags([])
        #expect(none.shown.isEmpty && none.moreLabel == nil)
        let three = TileTags(["Health", "Daily", "Home"])
        #expect(three.shown == ["Health", "Daily", "Home"])
        #expect(three.moreLabel == nil)
        #expect(three.spokenLabel == "Tags: Health, Daily, Home")
        let five = TileTags(["Health", "Daily", "Home", "Evening", "Gym"])
        #expect(five.shown == ["Health", "Daily", "Home"], "the stored order")
        #expect(five.more == 2)
        #expect(five.moreLabel == "+2")
        #expect(five.spokenLabel == "Tags: Health, Daily, Home, and 2 more")
    }
}
