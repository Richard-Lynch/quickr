import Foundation
import QuickrCore

/// `Appearance` as the server returns it (appearance.md §1.1): normalised, so every key is
/// required on the wire (`color` and `icon` nullable). `TopicAppearance`'s own decoder is
/// lenient (a missing key reads as unset); this one isn't, so a response that drops a key fails to
/// decode, as for every other response object (sync-protocol.md §2.2).
public struct AppearanceDTO: Codable, Sendable, Hashable, DomainConvertible {
    @RequiredKey public var color: ColorName?
    @RequiredKey public var icon: TopicIcon?
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case color, icon, tags
    }

    public init(_ appearance: TopicAppearance) {
        color = appearance.color
        icon = appearance.icon
        tags = appearance.tags
    }

    public func toDomain() -> TopicAppearance {
        TopicAppearance(color: color, icon: icon, tags: tags)
    }
}

/// `AppearanceUpdate` (`TopicUpdate.appearance`, appearance.md §1.1): an omitted field is
/// unchanged, `color: null` and `icon: null` clear, `tags: []` clears the tags.
/// `appearance: null` is a 422, so ``TopicUpdateDTO`` leaves the key out instead.
public struct AppearanceUpdateDTO: Codable, Sendable, Hashable {
    public var color: Nullable<ColorName>
    public var icon: Nullable<TopicIcon>
    public var tags: [String]?

    enum CodingKeys: String, CodingKey {
        case color, icon, tags
    }

    public init(color: Nullable<ColorName> = .absent, icon: Nullable<TopicIcon> = .absent, tags: [String]? = nil) {
        self.color = color
        self.icon = icon
        self.tags = tags
    }

    /// The PATCH of ``AppearanceUpdate``: `nil` is omitted, `.some(nil)` is `null`.
    public init(_ update: AppearanceUpdate) {
        color = Self.nullable(update.color)
        icon = Self.nullable(update.icon)
        tags = update.tags
    }

    private static func nullable<Value: Sendable & Hashable>(_ field: Value??) -> Nullable<Value> {
        switch field {
        case .none: .absent
        case .some(.none): .null
        case .some(.some(let value)): .value(value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeNullable(ColorName.self, forKey: .color)
        icon = try container.decodeNullable(TopicIcon.self, forKey: .icon)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(icon, forKey: .icon)
        try container.encodeIfPresent(tags, forKey: .tags)
    }
}
