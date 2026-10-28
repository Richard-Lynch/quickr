import AppIntents
import Foundation
import QuickrCore

/// What a widget's chip or ✓, or a topic's Control, runs: INTENTS' one commit (`IntentLogging`),
/// pinned to the store the widget was drawn from. A widget can outlive its server (a switch, a
/// reset): its button then refuses ("refresh the widget") and the widgets and Controls reload, so it
/// never logs its shown answer into another server that happens to share the topic's id. It never
/// prompts (a widget run can't): with nothing to log it says so. Siri, Shortcuts and the Action
/// button keep `LogEntryIntent`.
public struct WidgetLogIntent: AppIntent {
    public static let title: LocalizedStringResource = "Log from a Widget"
    public static let isDiscoverable = false

    @available(iOS 26.0, macOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    /// Nil only for a Control not configured yet.
    @Parameter(title: "Topic") public var topic: TopicEntity?
    @Parameter(title: "Option") public var option: QuestionOptionEntity?
    @Parameter(title: "Number") public var number: Double?
    /// The store the widget was drawn from (`EntryScope.id`: "{server_id}/{store_gen}").
    @Parameter(title: "Store") public var scope: String

    public init() {}

    /// A chip: logs `option`.
    public init(topic: TopicEntity, option: QuestionOptionEntity, scope: EntryScope) {
        self.init(topic: topic, scope: scope)
        self.option = option
    }

    /// ✓: logs `number`.
    public init(topic: TopicEntity, number: Double, scope: EntryScope) {
        self.init(topic: topic, scope: scope)
        self.number = number
    }

    /// A single topic (no questions): logs it, with no answers. For any other topic it has nothing
    /// to log (a Control for a chip topic never logged): says so, logs nothing.
    public init(topic: TopicEntity, scope: EntryScope) {
        self.topic = topic
        self.scope = scope.id
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let topic else { return .result(dialog: "Choose a topic for this control first.") }
        let said = try await WidgetLogging.perform(
            topicId: topic.id, option: option, number: number,
            scope: EntryScope(scope), context: IntentWrites.context(),
            reload: WidgetWrites.reloadAll)
        return .result(dialog: IntentDialog(stringLiteral: said))
    }
}

/// `WidgetLogIntent`'s rules, with the context passed in (tests don't register one).
enum WidgetLogging {
    enum Failure: Error, Sendable, Hashable, CustomStringConvertible, CustomLocalizedStringResourceConvertible {
        /// The widget was drawn from another store than the active one.
        case stale

        var description: String {
            switch self {
            case .stale: "This widget was for another quickR server. It's refreshing: try again in a moment."
            }
        }

        var localizedStringResource: LocalizedStringResource { "\(description)" }
    }

    /// Logs (and returns what to say), or refuses. `context` nil: quickR isn't set up here.
    static func perform(
        topicId: UUID, option: QuestionOptionEntity?, number: Double?, scope: EntryScope,
        context: IntentWriteContext?, reload: @Sendable () -> Void
    ) async throws -> String {
        guard let context else { throw IntentLogging.Failure.noStore }
        // Run in the app (not the widget extension), the app may be suspended in the background.
        return try await IntentLogging.holding(context) {
            try await logPinned(
                topicId: topicId, option: option, number: number, scope: scope, context: context, reload: reload)
        }
    }

    private static func logPinned(
        topicId: UUID, option: QuestionOptionEntity?, number: Double?, scope: EntryScope,
        context: IntentWriteContext, reload: @Sendable () -> Void
    ) async throws -> String {
        let store: LocalStore
        do {
            guard let opened = try await context.openActiveStore() else { throw IntentLogging.Failure.noStore }
            store = opened
        } catch let failure as IntentLogging.Failure {
            throw failure
        } catch {
            throw IntentLogging.Failure.noStore
        }
        guard store.scope == scope else {
            reload()
            throw Failure.stale
        }
        // The check and the write on the same store: no switch can come between them.
        var pinned = context
        pinned.openActiveStore = { store }
        let (_, current) = try await IntentLogging.topic(topicId, in: pinned)
        // A timed topic is never one-press logged untimed (timers.md §11.1): the Timer Control
        // times it.
        if current.timer != nil { return "\(current.name) is timed: use the Timer control." }
        let answers: [String: AnswerValue]
        switch QuickLog(questions: current.questions) {
        case .chips(let question, _)?:
            guard let option, let value = option.value else {
                return "\(current.name) has no answer to repeat yet: log it in quickR first."
            }
            answers = [question.key: .string(value)]
        case .number(let question)?:
            guard let number else { return "Log \(current.name) in quickR first." }
            answers = [question.key: IntentText.answer(number, for: question)]
        case .single?:
            answers = [:]
        case nil:
            return "\(current.name) has more than one question: log it in quickR."
        }
        let logged = try await IntentLogging.log(topicId: current.id, answers: answers, in: pinned)
        return logged.saying("Logged \(IntentText.summary(logged.answers, topic: logged.topic)).")
    }
}
