import Foundation

/// A topic's appearance (appearance.md §1.1): a palette colour, an emoji icon and tags. Topic-level
/// and unversioned. `empty` is the server's default (`null`, `null`, `[]`), the wire shape, so it is
/// `Codable` as is: the three keys are always written, `color` and `icon` as `null` when unset.
public struct TopicAppearance: Codable, Sendable, Hashable {
    public var color: ColorName?
    public var icon: TopicIcon?
    public var tags: [String]

    public init(color: ColorName? = nil, icon: TopicIcon? = nil, tags: [String] = []) {
        self.color = color
        self.icon = icon
        self.tags = tags
    }

    /// No colour, no icon, no tags: the default theme and no glyph.
    public static let empty = TopicAppearance()

    private enum CodingKeys: String, CodingKey {
        case color, icon, tags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(ColorName.self, forKey: .color)
        icon = try container.decodeIfPresent(TopicIcon.self, forKey: .icon)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(icon, forKey: .icon)
        try container.encode(tags, forKey: .tags)
    }
}

/// The twelve palette names, in palette order (appearance.md §3.1). No free hex (OQ-8).
public enum ColorName: String, Codable, CaseIterable, Sendable, Hashable {
    case red, orange, amber, yellow, lime, green, teal, cyan, blue, indigo, violet, pink
}

/// A topic's icon, `{kind: "emoji", value}` on the wire. Emoji is the only kind in phase A (OQ-7); an
/// unknown kind fails to decode, like an unknown schedule kind.
public enum TopicIcon: Codable, Sendable, Hashable {
    /// One emoji grapheme cluster (appearance.md §2).
    case emoji(String)

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "emoji": self = .emoji(try container.decode(String.self, forKey: .value))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown icon kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let value):
            try container.encode("emoji", forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}
