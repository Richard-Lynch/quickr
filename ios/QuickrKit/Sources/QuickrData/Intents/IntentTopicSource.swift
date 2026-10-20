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

/// No topics: what a process registers when it can't open its store (the next launch retries).
public struct NoTopicRepository: TopicRepository {
    public init() {}

    public func topics() async throws -> [ViewTopic] { [] }
    public func topic(id: UUID) async throws -> ViewTopic? { nil }
    public func topic(slug: String) async throws -> ViewTopic? { nil }
}

/// A fixed topic list for package tests and previews. The app and the widget register the active
/// store's topics (`ActiveStoreTopicRepository`), never this. Coffee and Mood quick-log (a number,
/// an option); Old habit is archived.
public struct PlaceholderTopicRepository: TopicRepository {
    public static let coffee = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c01")!
    public static let mood = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c02")!
    public static let oldHabit = UUID(uuidString: "6f1c3c1e-0c4b-4d2a-9a51-1d6a0e9b7c03")!

    private let all: [ViewTopic]

    public init() {
        let epoch = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        func topic(
            _ id: UUID, _ slug: String, _ name: String, _ question: Question, _ status: TopicStatus = .active
        ) -> ViewTopic {
            ViewTopic(
                topic: Topic(
                    id: id, slug: slug, name: name, status: status, currentVersion: 1, revision: 1,
                    questionCount: 1, createdAt: epoch, updatedAt: epoch,
                    archivedAt: status == .archived ? epoch : nil, questions: [question]))
        }
        let cups = Question(key: "cups", label: "Cups", kind: .int(.init(min: 0, max: 20, unit: "cups")))
        let mood = Question(
            key: "mood", label: "Mood",
            kind: .choice(
                .init(options: [
                    EnumOption(value: "good", label: "Good"), EnumOption(value: "ok", label: "OK"),
                    EnumOption(value: "bad", label: "Bad"),
                ])))
        all = [
            topic(Self.coffee, "coffee", "Coffee", cups),
            topic(Self.mood, "mood", "Mood", mood),
            topic(Self.oldHabit, "old-habit", "Old habit", mood, .archived),
        ]
    }

    public func topics() async throws -> [ViewTopic] { all }
    public func topic(id: UUID) async throws -> ViewTopic? { all.first { $0.id == id } }
    public func topic(slug: String) async throws -> ViewTopic? { all.first { $0.topic.slug == slug } }
}
