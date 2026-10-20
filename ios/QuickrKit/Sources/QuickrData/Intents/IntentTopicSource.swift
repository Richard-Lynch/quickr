import Foundation
import QuickrCore
import Synchronization

/// Where the App Intents queries read topics in this process. The app and the widget extension
/// each register a repository at launch, before the system can ask for an entity.
///
/// Not `AppDependencyManager`/`@Dependency`: that traps when read outside the system's intent
/// flow, and widget timeline providers and tests call the query directly.
public enum IntentTopicSource {
    public struct NotRegistered: Error, CustomStringConvertible {
        public var description: String { "No topic repository registered for App Intents in this process" }
    }

    private static let current = Mutex<(any TopicRepository)?>(nil)

    /// Registers `repository` for this process, replacing any earlier one.
    public static func register(_ repository: any TopicRepository) {
        current.withLock { $0 = repository }
    }

    static func repository() throws -> any TopicRepository {
        guard let repository = current.withLock({ $0 }) else { throw NotRegistered() }
        return repository
    }
}

/// SKEL stand-in until STORE is integrated: a fixed topic list, so the intents have something to
/// resolve in the app and the widget. Integration replaces it with the store's
/// `GRDBTopicRepository` over the active server's pool.
public struct PlaceholderTopicRepository: TopicRepository {
    public static let coffee = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c01")!
    public static let mood = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c02")!
    public static let oldHabit = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c03")!

    private let all: [ViewTopic]

    public init() {
        let epoch = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        func topic(_ id: UUID, _ slug: String, _ name: String, _ status: TopicStatus = .active) -> ViewTopic {
            ViewTopic(
                topic: Topic(
                    id: id, slug: slug, name: name, status: status, currentVersion: 1, revision: 1,
                    questionCount: 1, createdAt: epoch, updatedAt: epoch,
                    archivedAt: status == .archived ? epoch : nil, questions: []))
        }
        all = [
            topic(Self.coffee, "coffee", "Coffee"),
            topic(Self.mood, "mood", "Mood"),
            topic(Self.oldHabit, "old-habit", "Old habit", .archived),
        ]
    }

    public func topics() async throws -> [ViewTopic] { all }
    public func topic(id: UUID) async throws -> ViewTopic? { all.first { $0.id == id } }
    public func topic(slug: String) async throws -> ViewTopic? { all.first { $0.topic.slug == slug } }
}
