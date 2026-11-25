import Foundation
import QuickrCore
import Testing

@testable import QuickrUI

/// The topic header's content (appearance.md §6.3, §5 chips, §4.3 default) against hand-made
/// appearances shaped like the §1.1 wire shape. The view itself is checked in M3-UITEST.
@Suite(.timeLimit(.minutes(1))) struct TopicHeaderTests {
    /// The §1.1 wire shape, as the server sends it on `TopicDetail.appearance`.
    static func decode(_ json: String) throws -> TopicAppearance {
        try JSONDecoder().decode(TopicAppearance.self, from: Data(json.utf8))
    }

    @Test func noAppearanceShowsNoHeader() throws {
        #expect(TopicHeaderContent.make(appearance: nil, name: "Water") == nil)
        #expect(TopicHeaderContent.make(appearance: .empty, name: "Water") == nil)
        let defaults = try Self.decode(#"{"color": null, "icon": null, "tags": []}"#)
        #expect(TopicHeaderContent.make(appearance: defaults, name: "Water") == nil)
    }

    /// Until I3-STORE stores it, every topic's appearance is `.empty`: today's UI, no header.
    @Test func topicWithoutAppearanceShowsNoHeader() {
        let topic = Topic(
            id: UUID(), slug: "water", name: "Water", currentVersion: 1, revision: 1, questionCount: 0,
            createdAt: .distantPast, updatedAt: .distantPast, questions: [])
        #expect(TopicHeaderContent.make(for: topic) == nil)
    }

    @Test func fullAppearanceShowsGlyphNameChipsAndRule() throws {
        let appearance = try Self.decode(
            #"{"color": "teal", "icon": {"kind": "emoji", "value": "💧"}, "tags": ["Health", "daily", "Gym"]}"#)
        let header = try #require(TopicHeaderContent.make(appearance: appearance, name: "Water"))
        #expect(header.name == "Water")
        #expect(header.glyph == .emoji("💧"))
        #expect(header.tags == ["Health", "daily", "Gym"])
        #expect(header.showsRule)
        #expect(header.theme == TopicTheme(appearance: appearance, name: "Water"))
        #expect(header.theme.tint != TopicTheme.default.tint)
    }

    /// A colour without an emoji: the name's initial on the tint (the glossary's glyph).
    @Test func colourWithoutEmojiFallsBackToTheInitial() throws {
        let header = try #require(TopicHeaderContent.make(appearance: .init(color: .orange), name: " smoking"))
        #expect(header.glyph == .initial("s"))
        #expect(header.tags.isEmpty)
        #expect(header.showsRule)
    }

    /// No colour: the accent theme, no rule and no accent initial circle (§4.3), but the emoji and
    /// the chips still show.
    @Test func noColourDrawsNoAccentChrome() throws {
        let emoji = try #require(TopicHeaderContent.make(appearance: .init(icon: .emoji("🚬")), name: "Smoking"))
        #expect(emoji.glyph == .emoji("🚬"))
        #expect(!emoji.showsRule)
        #expect(emoji.theme.tint == TopicTheme.default.tint)
        #expect(emoji.theme.tintSoft == TopicTheme.default.tintSoft)
        #expect(emoji.theme.onTint == TopicTheme.default.onTint)

        let tags = try #require(TopicHeaderContent.make(appearance: .init(tags: ["Gym"]), name: "Lifting"))
        #expect(tags.glyph == nil)
        #expect(!tags.showsRule)
        #expect(tags.tags == ["Gym"])
    }

    /// An empty name has no initial: a coloured topic then shows the rule and no glyph.
    @Test func colourWithEmptyNameHasNoGlyph() throws {
        let header = try #require(TopicHeaderContent.make(appearance: .init(color: .blue), name: "  "))
        #expect(header.glyph == nil)
        #expect(header.showsRule)
    }

    @Test func accessibilityIdentifiers() {
        #expect(TopicHeaderContent.identifier == "topic.header")
        #expect(TopicHeaderContent.nameIdentifier == "topic.header.name")
        #expect(TopicHeaderContent.tagsIdentifier == "topic.header.tags")
        #expect(TopicHeaderContent.tagIdentifier(0) == "topic.header.tags.0")
        #expect(TopicHeaderContent.tagIdentifier(9) == "topic.header.tags.9")
    }
}
