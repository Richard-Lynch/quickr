import Foundation

/// A screen the app can navigate to: one per PWA page (`frontend/src/router.tsx`), so a PWA URL
/// and a notification's `quickr.url` (`/t/{slug}/record`) open the same screen on iOS. The topic
/// list is the root and has no route. `DeepLink` turns paths and `quickr://` URLs into routes
/// and back.
public enum Route: Hashable, Sendable {
    /// `/settings`: app settings.
    case settings
    /// `/new`: create a topic.
    case newTopic
    /// `/t/:ref`, `/t/:ref/entries` and `/t/:ref/versions`: a topic's tabs.
    case topic(TopicLinkRef, TopicTab)
    /// `/t/:ref/record`, optionally `?fix=<outbox item id>`: log an entry, or fix a rejected one.
    case record(TopicLinkRef, fix: String? = nil)
    /// `/t/:ref/entries/:entryId`: edit one entry.
    case entry(TopicLinkRef, entryId: UUID)
    /// `/t/:ref/edit`: the question builder.
    case editQuestions(TopicLinkRef)
    /// `/t/:ref/settings`: the topic's details, schedule, archive and delete.
    case topicSettings(TopicLinkRef)

    /// The topic this route belongs to, if any.
    public var topic: TopicLinkRef? {
        switch self {
        case .settings, .newTopic: nil
        case .topic(let ref, _), .record(let ref, _), .entry(let ref, _), .editQuestions(let ref),
            .topicSettings(let ref):
            ref
        }
    }
}

/// A topic tab (`TopicTabs` in the PWA).
public enum TopicTab: String, Hashable, Sendable, CaseIterable {
    case overview
    case entries
    case versions
}

/// How a URL names a topic: its slug, or its id (the server's `getTopic` takes either).
public struct TopicLinkRef: Hashable, Sendable, CustomStringConvertible {
    /// The slug, or the id in lowercase.
    public let rawValue: String

    /// A slug as the server allows it (`SLUG_PATTERN`: `^[a-z0-9][a-z0-9-]{0,63}$`) or a UUID;
    /// nil for anything else.
    public init?(_ raw: String) {
        if let id = UUID(uuidString: raw) {
            rawValue = id.uuidString.lowercased()
        } else if Self.isSlug(raw) {
            rawValue = raw
        } else {
            return nil
        }
    }

    public init(id: UUID) { rawValue = id.uuidString.lowercased() }

    /// The id, when the ref is one.
    public var id: UUID? { UUID(uuidString: rawValue) }

    public var description: String { rawValue }

    static func isSlug(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) }
        return alnum(bytes[0]) && bytes.dropFirst().allSatisfy { alnum($0) || $0 == 0x2D }
    }
}
