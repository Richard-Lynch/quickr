import AppIntents
import QuickrCore
import QuickrData
import QuickrUI
import SwiftUI
import WidgetKit

/// Chooses the topic a Control logs (Control Center, the Lock Screen, the Action button).
struct SelectTopicControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Topic"

    @Parameter(title: "Topic") var topic: TopicEntity?

    init() {}
}

/// What a topic's Control does now. A Control runs one fully specified intent and can't prompt:
/// a chip topic logs its last option again, a number topic its last value (or the stepper's start,
/// like the tile's ✓). A chip topic never logged, or one that needs the form, has no such log: its
/// label says so, and a press runs `LogEntryIntent(topic:)`, which declines with INTENTS' message.
struct TopicControlValue: Sendable {
    let topic: TopicEntity?
    let title: String
    let detail: String?
    let option: QuestionOptionEntity?
    let number: Double?

    static let unconfigured = TopicControlValue(topic: nil, title: "Choose a topic", detail: nil)

    init(
        topic: TopicEntity?, title: String, detail: String?, option: QuestionOptionEntity? = nil,
        number: Double? = nil
    ) {
        self.topic = topic
        self.title = title
        self.detail = detail
        self.option = option
        self.number = number
    }

    /// The rules, from the store's view of the topic.
    init(_ shown: WidgetTopic) {
        let entity = TopicEntity(shown.topic)
        let name = shown.topic.name
        switch shown.quick {
        case .chips(let question, let options):
            guard case .string(let value)? = shown.lastAnswer, let option = options.first(where: { $0.value == value })
            else {
                self.init(topic: entity, title: name, detail: "Log it in quickR first")
                return
            }
            self.init(
                topic: entity, title: name, detail: option.label,
                option: QuestionOptionEntity(topicId: shown.id, key: question.key, option: option))
        case .number(let question):
            let text = QuickLog.initialText(for: question, last: shown.lastAnswer)
            guard let number = Double(text) else {
                self.init(topic: entity, title: name, detail: "Log it in quickR first")
                return
            }
            let shownValue = TopicText().answer(shown.lastAnswer ?? .double(number), for: question)
            self.init(topic: entity, title: name, detail: shownValue ?? text, number: number)
        case nil:
            self.init(topic: entity, title: name, detail: "Needs the form: log it in quickR")
        }
    }

    /// The Control's one action (always this type: Controls can't branch on it).
    var intent: LogEntryIntent {
        guard let topic else { return LogEntryIntent() }
        if let option { return LogEntryIntent(topic: topic, option: option) }
        if let number { return LogEntryIntent(topic: topic, number: number) }
        return LogEntryIntent(topic: topic)
    }

    var logs: Bool { option != nil || number != nil }
}

struct TopicControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectTopicControlIntent) -> TopicControlValue {
        guard let topic = configuration.topic else { return .unconfigured }
        return TopicControlValue(topic: topic, title: topic.name, detail: nil)
    }

    func currentValue(configuration: SelectTopicControlIntent) async throws -> TopicControlValue {
        await Self.value(for: configuration.topic?.id)
    }

    static func value(for id: UUID?) async -> TopicControlValue {
        guard let id, let reader = WidgetBootstrap.reader() else { return .unconfigured }
        do {
            guard let shown = try await reader.topic(id: id) else { return .unconfigured }
            return TopicControlValue(shown)
        } catch {
            WidgetBootstrap.log.error("control topic unreadable: \(String(describing: error), privacy: .public)")
            return .unconfigured
        }
    }
}

/// One Control per topic: logs it again in one press, without opening quickR.
struct TopicControl: ControlWidget {
    static let kind = "com.bahumia.quickr.control.topic"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: TopicControlProvider()) { value in
            ControlWidgetButton(action: value.intent) {
                Label {
                    Text(value.title)
                    if let detail = value.detail { Text(detail) }
                } icon: {
                    Image(systemName: value.logs ? "checkmark.circle" : "square.and.pencil")
                }
            }
        }
        .displayName("Log a topic")
        .description("Logs a topic's last answer again in one press.")
        .promptsForUserConfiguration()
    }
}
