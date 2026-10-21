import AppIntents
import Foundation
import QuickrCore

/// One option of a topic's single-select question, as App Intents sees it: what a quick-log
/// widget button, a Control or Siri ("Log coffee: two cups") picks. Its id is
/// `{topic_id}|{key}|{value}`; keys and option values follow the key grammar
/// (`^[a-z][a-z0-9_]{0,62}$`), so the bars can't be ambiguous.
public struct QuestionOptionEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Option"
    public static let defaultQuery = QuestionOptionQuery()

    public let id: String
    @Property(title: "Label") public var label: String

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }

    public init(topicId: UUID, key: String, option: EnumOption) {
        id = Self.id(topicId: topicId, key: key, value: option.value)
        label = option.label
    }

    public static func id(topicId: UUID, key: String, value: String) -> String {
        "\(topicId.wireString)|\(key)|\(value)"
    }

    /// The parts of an id, or nil when it isn't one.
    public static func parts(of id: String) -> (topicId: UUID, key: String, value: String)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let topicId = UUID(uuidString: parts[0]), !parts[1].isEmpty, !parts[2].isEmpty
        else { return nil }
        return (topicId, parts[1], parts[2])
    }

    public var topicId: UUID? { Self.parts(of: id)?.topicId }
    public var key: String? { Self.parts(of: id)?.key }
    public var value: String? { Self.parts(of: id)?.value }

    /// The active options of `question` (a single-select) of `topic`.
    public static func options(of question: Question, topicId: UUID) -> [QuestionOptionEntity] {
        guard case .choice(let rules) = question.kind, !rules.multiple else { return [] }
        return rules.activeOptions.map { QuestionOptionEntity(topicId: topicId, key: question.key, option: $0) }
    }
}

/// Options by id (through `IntentTopicSource`, like `TopicEntityQuery`); suggestions are the
/// quick-log options of the topic chosen in a `LogEntryIntent`.
public struct QuestionOptionQuery: EntityQuery {
    @IntentParameterDependency<LogEntryIntent>(\.$topic) var logEntry

    public init() {}

    public func entities(for identifiers: [String]) async throws -> [QuestionOptionEntity] {
        let repository = try IntentTopicSource.repository()
        var topics: [UUID: Topic] = [:]
        var found: [QuestionOptionEntity] = []
        for id in identifiers {
            guard let parts = QuestionOptionEntity.parts(of: id) else { continue }
            if topics[parts.topicId] == nil, let topic = try await repository.topic(id: parts.topicId) {
                topics[parts.topicId] = topic.topic
            }
            if let topic = topics[parts.topicId], let option = Self.option(id, in: topic) { found.append(option) }
        }
        return found
    }

    public func suggestedEntities() async throws -> [QuestionOptionEntity] {
        guard let topicId = logEntry?.topic.id,
            let topic = try await IntentTopicSource.repository().topic(id: topicId)?.topic
        else { return [] }
        return Self.quickLogOptions(of: topic)
    }

    /// The options a quick-log of `topic` offers (none unless it logs with chips).
    static func quickLogOptions(of topic: Topic) -> [QuestionOptionEntity] {
        guard case .chips(let question, _) = QuickLog(questions: topic.questions) else { return [] }
        return QuestionOptionEntity.options(of: question, topicId: topic.id)
    }

    /// The option `id` names in `topic`'s current questions, if it is still an active option.
    static func option(_ id: String, in topic: Topic) -> QuestionOptionEntity? {
        guard let parts = QuestionOptionEntity.parts(of: id), parts.topicId == topic.id,
            let question = topic.questions.first(where: { $0.key == parts.key })
        else { return nil }
        return QuestionOptionEntity.options(of: question, topicId: topic.id).first { $0.id == id }
    }
}
