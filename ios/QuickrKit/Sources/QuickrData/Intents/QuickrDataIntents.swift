import AppIntents
import Foundation
import QuickrCore

// No `AppIntentsPackage` here, on purpose. Xcode merges this static library's intents metadata into
// every binary that links it. An `includedPackages` entry for it makes iOS 26.0's linkd look the
// package type up among the binary's *imported* symbols; a static library's never are, so linkd
// logs "did not match any imported symbol" and drops the whole bundle's intents (iOS 27 accepts
// it). `IntentMetadataTests` guards this.

/// Logs an entry for a quick-log topic (one required question: an option, or a number), from
/// Siri, Shortcuts, a widget button or a Control. Given its value (widgets, Controls) it never
/// prompts; from Siri a missing option is asked for (`requestDisambiguation`) and a missing number
/// too (`requestValue`). The write is `IntentLogging.log`: checked against the active store,
/// validated, one durable `entry.create` with a random id, then a best-effort flush. A topic with
/// more questions says to use the record screen. Undoable (`UndoableIntent`): undo cancels the
/// create.
public struct LogEntryIntent: AppIntent, UndoableIntent {
    public static let title: LocalizedStringResource = "Log Entry"
    public static let description = IntentDescription("Logs an entry for a topic in quickR.")
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Topic") public var topic: TopicEntity
    @Parameter(title: "Option") public var option: QuestionOptionEntity?
    @Parameter(title: "Number") public var number: Double?

    public static var parameterSummary: some ParameterSummary { Summary("Log \(\.$topic)") }

    public init() {}

    public init(topic: TopicEntity) {
        self.topic = topic
    }

    /// A widget's or Control's chip: logs this option, no prompt.
    public init(topic: TopicEntity, option: QuestionOptionEntity) {
        self.topic = topic
        self.option = option
    }

    /// A widget's or Control's number: logs this value, no prompt.
    public init(topic: TopicEntity, number: Double) {
        self.topic = topic
        self.number = number
    }

    /// The logged answer, as the dialog says it ("Coffee: 2 cups").
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let context = IntentWrites.context() else { throw IntentLogging.Failure.noStore }
        let (_, current) = try await IntentLogging.topic(topic.id, in: context)
        guard let quickLog = QuickLog(questions: current.questions) else {
            throw IntentLogging.Failure.invalid("\(current.name) has more than one question: log it in quickR.")
        }
        let answers: [String: AnswerValue]
        switch quickLog {
        case .chips(let question, _):
            let options = QuestionOptionEntity.options(of: question, topicId: current.id)
            let chosen: QuestionOptionEntity
            if let option, options.contains(where: { $0.id == option.id }) {
                chosen = option
            } else {
                chosen = try await $option.requestDisambiguation(among: options, dialog: "Which \(question.label)?")
            }
            answers = [question.key: .string(chosen.value ?? "")]
        case .number(let question):
            let value: Double
            if let number {
                value = number
            } else {
                value = try await $number.requestValue("\(IntentText.prompt(for: question))")
            }
            answers = [question.key: IntentText.answer(value, for: question)]
        }
        let logged = try await IntentLogging.log(topicId: current.id, answers: answers, in: context)
        let summary = IntentText.summary(logged.answers, topic: logged.topic)
        await IntentUndo.register(undoManager, entryId: logged.entryId, summary: summary, context: context)
        return .result(value: summary, dialog: "Logged \(summary).")
    }
}

/// The topic a widget shows. WIDGETS builds the real widgets on it.
public struct SelectTopicIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Topic"
    public static let description = IntentDescription("The topic this widget shows.")

    @Parameter(title: "Topic") public var topic: TopicEntity?

    public init() {}

    public init(topic: TopicEntity?) {
        self.topic = topic
    }
}
