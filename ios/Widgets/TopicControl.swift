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

/// What a topic's Control does now. A Control runs one fully specified intent (`WidgetLogIntent`,
/// pinned to the store it was read from) and can't prompt: a chip topic logs its last option again,
/// a number topic the value ✓ would log (its last, or its start). A chip topic never logged, or one
/// that needs the form, logs nothing: its label says so, and a press says it in a dialog.
struct TopicControlValue: Sendable {
    let title: String
    let detail: String?
    let intent: WidgetLogIntent
    let logs: Bool

    static let unconfigured = TopicControlValue(
        title: "Choose a topic", detail: nil, intent: WidgetLogIntent(), logs: false)

    init(title: String, detail: String?, intent: WidgetLogIntent, logs: Bool) {
        self.title = title
        self.detail = detail
        self.intent = intent
        self.logs = logs
    }

    /// The rules, from the store's view of the topic.
    init(_ shown: WidgetTopic) {
        guard let scope = shown.scope else {
            self = .unconfigured
            return
        }
        let entity = TopicEntity(shown.topic)
        let name = shown.topic.name
        let nothing = WidgetLogIntent(topic: entity, scope: scope)
        switch shown.quick {
        case .chips(let question, let options):
            guard case .string(let value)? = shown.lastAnswer, let option = options.first(where: { $0.value == value })
            else {
                self.init(title: name, detail: "Log it in quickR first", intent: nothing, logs: false)
                return
            }
            let chip = QuestionOptionEntity(topicId: shown.id, key: question.key, option: option)
            self.init(
                title: name, detail: option.label, intent: WidgetLogIntent(topic: entity, option: chip, scope: scope),
                logs: true)
        case .number(let question):
            // Shows exactly what it logs (the last value, or the start once the rules changed).
            guard let answer = shown.checkAnswer, let number = answer.number else {
                self.init(title: name, detail: "Log it in quickR first", intent: nothing, logs: false)
                return
            }
            self.init(
                title: name, detail: TopicText().answer(answer, for: question),
                intent: WidgetLogIntent(topic: entity, number: number, scope: scope), logs: true)
        case .single:
            // No questions: its entry has no answers, so it always logs.
            self.init(title: name, detail: "Log it", intent: nothing, logs: true)
        case nil:
            self.init(title: name, detail: "Needs the form: log it in quickR", intent: nothing, logs: false)
        }
    }
}

extension AnswerValue {
    fileprivate var number: Double? {
        switch self {
        case .int(let n): Double(n)
        case .double(let x): x
        default: nil
        }
    }
}

struct TopicControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectTopicControlIntent) -> TopicControlValue {
        guard let topic = configuration.topic else { return .unconfigured }
        return TopicControlValue(title: topic.name, detail: nil, intent: WidgetLogIntent(), logs: false)
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
