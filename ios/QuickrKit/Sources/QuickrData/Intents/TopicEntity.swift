import AppIntents
import Foundation
import QuickrCore

/// A topic as App Intents sees it: Shortcuts, Siri, Spotlight and widget configuration. Declared
/// once, here; its metadata reaches the app and the widget extension by linking (see
/// `QuickrDataIntents.swift` for why there is no `AppIntentsPackage`).
public struct TopicEntity: AppEntity, IndexedEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    public static let defaultQuery = TopicEntityQuery()

    public let id: UUID
    @Property(title: "Name") public var name: String
    @Property(title: "Slug") public var slug: String

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    public init(id: UUID, name: String, slug: String) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    public init(_ topic: Topic) {
        self.init(id: topic.id, name: topic.name, slug: topic.slug)
    }
}

/// Reads topics through the repository registered with `IntentTopicSource`. Lists (pickers, suggestions,
/// string search) leave archived topics out; lookups by id don't, so a widget configured with a
/// topic that was archived since still resolves it.
public struct TopicEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [TopicEntity] {
        Self.entities(for: identifiers, in: try await IntentTopicSource.repository().topics())
    }

    public func entities(matching string: String) async throws -> [TopicEntity] {
        Self.entities(matching: string, in: try await IntentTopicSource.repository().topics())
    }

    public func allEntities() async throws -> [TopicEntity] {
        Self.listed(try await IntentTopicSource.repository().topics())
    }

    public func suggestedEntities() async throws -> [TopicEntity] {
        try await allEntities()
    }

    /// The timed topics (`timed(_:)`).
    public func timedEntities() async throws -> [TopicEntity] {
        Self.timed(try await IntentTopicSource.repository().topics())
    }

    // The rules, separate from the registration so the host tests can run them.

    static func listed(_ topics: [ViewTopic]) -> [TopicEntity] {
        topics.filter { $0.topic.status == .active }.map { TopicEntity($0.topic) }
    }

    /// The timed ones (timers.md §11.3), for the Timer Control's picker: active topics whose
    /// current version has a timer.
    public static func timed(_ topics: [ViewTopic]) -> [TopicEntity] {
        listed(topics.filter { $0.topic.timer != nil })
    }

    static func entities(for identifiers: [UUID], in topics: [ViewTopic]) -> [TopicEntity] {
        let byId = Dictionary(topics.map { ($0.id, $0.topic) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byId[$0].map(TopicEntity.init) }
    }

    static func entities(matching string: String, in topics: [ViewTopic]) -> [TopicEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listed(topics) }
        return listed(topics).filter {
            $0.name.localizedStandardContains(query) || $0.slug.localizedStandardContains(query)
        }
    }
}
