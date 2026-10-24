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
        // A timed topic is never one-press logged untimed (timers.md §11.1): the Timer Control
        // times it.
        if shown.runTile.isTimed {
            self.init(title: name, detail: "Timed: use the Timer control", intent: nothing, logs: false)
            return
        }
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

// MARK: - Timer

/// What a timed topic's Control (timers.md §11.3) shows and does: "Timer: {topic}", and what a
/// press does now, which is Auto (`RunWidgetIntent`, pinned to the store it was read from): Start,
/// "Next: Breakfast" (or a plain Next while the steps aren't known), or Stop on the last step. A
/// finishing run isn't open, so a press starts a new one. A topic it can't time (untimed,
/// archived, gone) gets an empty intent, which does nothing.
struct TimerControlValue: Sendable {
    let title: String
    let detail: String?
    let intent: RunWidgetIntent
    let icon: String

    static let unconfigured = TimerControlValue(
        title: "Choose a topic", detail: nil, intent: RunWidgetIntent(), icon: "timer")

    init(title: String, detail: String?, intent: RunWidgetIntent, icon: String) {
        self.title = title
        self.detail = detail
        self.intent = intent
        self.icon = icon
    }

    init(_ shown: WidgetTopic) {
        guard let scope = shown.scope else {
            self = .unconfigured
            return
        }
        let title = "Timer: \(shown.topic.name)"
        let auto = RunWidgetIntent(action: .auto, topicId: shown.id, scope: scope)
        switch shown.runTile {
        case .untimed:
            self.init(title: title, detail: "Not timed", intent: RunWidgetIntent(), icon: "timer")
        case .open:
            if shown.runButtons(compact: true).first == .next {
                let detail = shown.run?.nextLabel.map { "Next: \($0)" } ?? "Next"
                self.init(title: title, detail: detail, intent: auto, icon: "forward.end")
            } else {
                self.init(title: title, detail: "Stop", intent: auto, icon: "stop")
            }
        case .idle, .finishing:
            guard shown.topic.status != .archived else {
                self.init(title: title, detail: "Archived", intent: RunWidgetIntent(), icon: "timer")
                return
            }
            self.init(title: title, detail: "Start", intent: auto, icon: "play")
        }
    }
}

/// The Timer Control's picker: timed topics only. Declared here, in the extension: App Intents'
/// metadata can't find an options provider declared in a package.
struct TimedTopicOptions: DynamicOptionsProvider {
    func results() async throws -> [TopicEntity] {
        try await TopicEntityQuery().timedEntities()
    }
}

/// Chooses the timed topic a Timer Control advances: the picker lists timed topics only.
struct SelectTimerControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Timed Topic"

    @Parameter(title: "Topic", optionsProvider: TimedTopicOptions()) var topic: TopicEntity?

    init() {}
}

struct TimerControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectTimerControlIntent) -> TimerControlValue {
        guard let topic = configuration.topic else { return .unconfigured }
        return TimerControlValue(
            title: "Timer: \(topic.name)", detail: nil, intent: RunWidgetIntent(), icon: "timer")
    }

    func currentValue(configuration: SelectTimerControlIntent) async throws -> TimerControlValue {
        await Self.value(for: configuration.topic?.id)
    }

    static func value(for id: UUID?) async -> TimerControlValue {
        guard let id, let reader = WidgetBootstrap.reader() else { return .unconfigured }
        do {
            guard let shown = try await reader.topic(id: id) else { return .unconfigured }
            return TimerControlValue(shown)
        } catch {
            WidgetBootstrap.log.error("timer control topic unreadable: \(String(describing: error), privacy: .public)")
            return .unconfigured
        }
    }
}

/// One Control per timed topic (Control Centre, the Lock Screen): Auto in one press, without
/// opening quickR. Its intent runs in the app's process, so it can start or update the Live
/// Activity.
struct TimerControl: ControlWidget {
    static let kind = "com.bahumia.quickr.control.timer"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: TimerControlProvider()) { value in
            ControlWidgetButton(action: value.intent) {
                Label {
                    Text(value.title)
                    if let detail = value.detail { Text(detail) }
                } icon: {
                    Image(systemName: value.icon)
                }
            }
        }
        .displayName("Timer")
        .description("Starts a timed topic, moves to its next step, or stops it on the last one.")
        .promptsForUserConfiguration()
    }
}
