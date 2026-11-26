import QuickrCore
import SwiftUI

// The content is pure (no iOS-only API), so QuickrDesignTests checks it on the host; the view below
// is iOS-only like the rest of QuickrUI's views.

/// What a topic's header shows (appearance.md §6.3): the glyph at 28 pt, the name and the tag chips,
/// with a 4 pt `tint` rule under them. The default theme stays today's UI (§4.3): a topic with no
/// appearance gets no header at all (``make(appearance:name:)`` is nil), and a topic without a colour
/// gets no rule and no fallback initial, so nothing accent-coloured appears that `main` doesn't draw.
public struct TopicHeaderContent: Sendable, Hashable {
    public let theme: TopicTheme
    public let name: String
    /// The glyph to draw: the emoji, or the initial on the tint when the topic has a colour.
    public let glyph: TopicGlyph?
    /// The tags, in the stored order, one neutral chip each (§5).
    public let tags: [String]
    /// The 4 pt `tint` rule: only for a topic with a colour.
    public let showsRule: Bool

    /// The header for `appearance`, or nil when it has no colour, icon or tags (nil counts as empty).
    public static func make(appearance: TopicAppearance?, name: String) -> TopicHeaderContent? {
        guard let appearance, appearance != .empty else { return nil }
        return TopicHeaderContent(appearance: appearance, name: name)
    }

    /// `make(appearance: topic.appearance, name: topic.name)`.
    public static func make(for topic: Topic) -> TopicHeaderContent? {
        make(appearance: topic.appearance, name: topic.name)
    }

    private init(appearance: TopicAppearance, name: String) {
        theme = TopicTheme(appearance: appearance, name: name)
        self.name = name
        let coloured = appearance.color != nil
        glyph = theme.glyph(fallbackInitial: coloured)
        tags = appearance.tags
        showsRule = coloured
    }

    // Accessibility ids in the style of appearance.md §7 (`topic.tags`, `topic.tags.<i>`), under
    // `topic.header` so they don't collide with the editor's.
    /// The header row.
    public static let identifier = "topic.header"
    /// The name.
    public static let nameIdentifier = "topic.header.name"
    /// The chips' container.
    public static let tagsIdentifier = "topic.header.tags"
    /// The chip of the tag at `index`.
    public static func tagIdentifier(_ index: Int) -> String { "topic.header.tags.\(index)" }
}

#if os(iOS)
/// The topic header row of appearance.md §6.3, above the tab picker. Build it from
/// ``TopicHeaderContent/make(for:)`` and show nothing when that is nil.
public struct TopicHeaderView: View {
    let content: TopicHeaderContent

    public init(_ content: TopicHeaderContent) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    if content.glyph != nil {
                        TopicGlyphView(theme: content.theme, size: 28, fallbackInitial: content.showsRule)
                    }
                    Text(content.name)
                        .font(.qr(.title))
                        .foregroundStyle(.qr.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(TopicHeaderContent.nameIdentifier)
                }
                if !content.tags.isEmpty {
                    FlowRow {
                        ForEach(Array(content.tags.enumerated()), id: \.offset) { index, tag in
                            QuickrBadge(tag)
                                .accessibilityIdentifier(TopicHeaderContent.tagIdentifier(index))
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(TopicHeaderContent.tagsIdentifier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if content.showsRule {
                Rectangle()
                    .fill(content.theme.tint)
                    .frame(height: 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TopicHeaderContent.identifier)
    }
}

#Preview("Topic header") {
    VStack(spacing: 24) {
        if let header = TopicHeaderContent.make(
            appearance: .init(color: .teal, icon: .emoji("💧"), tags: ["Health", "Daily"]), name: "Water")
        {
            TopicHeaderView(header)
        }
        if let header = TopicHeaderContent.make(appearance: .init(color: .orange), name: "Smoking") {
            TopicHeaderView(header)
        }
        if let header = TopicHeaderContent.make(appearance: .init(tags: ["Gym"]), name: "Lifting") {
            TopicHeaderView(header)
        }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .qrPaperBackground()
}
#endif
