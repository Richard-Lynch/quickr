import AppIntents
import Foundation
import QuickrCore
import Synchronization

/// Where the app registers what a run intent does (timers.md §11.3): a timed widget's button, the
/// timer Control, the Action button and Siri. Each is a `LiveActivityIntent`, which iOS runs in
/// the app's process (launching it in the background if it was killed), so it can start or
/// update the run's Live Activity; only the app registers a handler, the widget extension (which
/// only draws the buttons) never does.
public enum RunIntents {
    public typealias Handler = @Sendable (RunIntentRequest) async throws -> RunIntentResult

    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible, CustomLocalizedStringResourceConvertible {
        /// The widget or Control was drawn from another store than the active one.
        case stale

        public var description: String {
            switch self {
            case .stale: "This widget was for another quickR server. It's refreshing: try again in a moment."
            }
        }

        public var localizedStringResource: LocalizedStringResource { "\(description)" }
    }

    private static let current = Mutex<Handler?>(nil)

    public static func register(_ handler: @escaping Handler) {
        current.withLock { $0 = handler }
    }

    public static func perform(_ request: RunIntentRequest) async throws -> RunIntentResult {
        guard let handler = current.withLock({ $0 }) else { throw RunActivityTaps.Failure.noHandler }
        return try await handler(request)
    }

    /// What a refusal says: the store is locked (before first unlock), not set up, another
    /// server's; nil for any other error.
    public static func message(for error: any Error) -> String? {
        switch error {
        case let failure as RunActivityTaps.Failure: failure.description
        case let failure as IntentLogging.Failure: failure.description
        case let failure as Failure: failure.description
        default: nil
        }
    }
}

/// Siri's and the Action button's actions (§11.3). "Next" is Auto (§11.1): it starts an idle
/// topic and stops one on its last step, so one phrase moves a run along.
public enum RunActionKind: String, AppEnum, Sendable {
    case auto, start, next, stop, pause, resume

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer Action"

    public static let caseDisplayRepresentations: [RunActionKind: DisplayRepresentation] = [
        .auto: DisplayRepresentation(title: "Auto", subtitle: "Start, next step, or stop on the last one"),
        .start: DisplayRepresentation(title: "Start", synonyms: ["Begin", "Time"]),
        .next: DisplayRepresentation(title: "Next", synonyms: ["Advance", "Next step"]),
        .stop: DisplayRepresentation(title: "Stop", synonyms: ["Finish", "End"]),
        .pause: DisplayRepresentation(title: "Pause"),
        .resume: DisplayRepresentation(title: "Resume", synonyms: ["Continue", "Unpause"]),
    ]

    /// The run action it asks for.
    public var action: RunIntentAction {
        switch self {
        case .auto, .next: .auto
        case .start: .start
        case .stop: .stop
        case .pause: .pause
        case .resume: .resume
        }
    }
}

/// The dialog of Siri's and the Action button's intents, with natural durations ("4 minutes 12
/// seconds"): Siri speaks it, so `m:ss` would be read as a time of day.
enum RunIntentDialog {
    static func make(_ outcome: RunIntentOutcome) -> IntentDialog { IntentDialog("\(outcome.spokenText)") }

    static func make(_ message: String) -> IntentDialog { IntentDialog(stringLiteral: message) }
}

#if os(iOS)
/// A timed widget's button (Start, Next, Lap, Stop) or the timer Control (Auto). Pinned to the
/// store it was drawn from, like `WidgetLogIntent`: a widget left over from another server
/// refuses. A widget's Next, Lap and Stop carry the run and segment it showed, so a tap on a run
/// that moved on does nothing. Not offered in Shortcuts.
public struct RunWidgetIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Timer Button"
    public static let description = IntentDescription("A button on a quickR timer widget or Control.")
    public static let isDiscoverable = false
    public static let supportedModes: IntentModes = .background

    /// `RunIntentAction`'s raw value. Nil, like the topic and store, only for a Control not
    /// configured yet (or whose topic is gone): it does nothing.
    @Parameter(title: "Action") public var action: String?
    @Parameter(title: "Topic") public var topicId: String?
    /// `EntryScope.id`: "{server_id}/{store_gen}".
    @Parameter(title: "Store") public var scope: String?
    @Parameter(title: "Run") public var runId: String?
    @Parameter(title: "Segment") public var seg: Int?

    public init() {}

    /// A widget's button, for the run `run` it shows (nil for Start).
    public init(_ button: WidgetRunButton, topicId: UUID, scope: EntryScope, run: RunActivityState?) {
        let action: RunIntentAction =
            switch button {
            case .start: .start
            case .next: .next
            case .lap: .lap
            case .stop: .stop
            }
        self.init(action: action, topicId: topicId, scope: scope)
        if button != .start, let run {
            runId = run.runId
            seg = run.seg
        }
    }

    /// The Control's Auto (or any action on the current state).
    public init(action: RunIntentAction, topicId: UUID, scope: EntryScope) {
        self.action = action.rawValue
        self.topicId = topicId.wireString
        self.scope = scope.id
    }

    public func perform() async throws -> some IntentResult {
        guard let action = action.flatMap(RunIntentAction.init(rawValue:)),
            let topic = topicId.flatMap({ UUID(uuidString: $0) }),
            let scope
        else { return .result() }
        let shown = runId.flatMap { id in seg.map { RunIntentRequest.Shown(runId: id, seg: $0) } }
        _ = try await RunIntents.perform(
            RunIntentRequest(action: action, topicId: topic, origin: .widget, scope: EntryScope(scope), shown: shown))
        return .result()
    }
}

/// The Action button's intent (§11.3), offered in Shortcuts: Auto on one topic by default, so one
/// press starts it, the next moves to the next step, and on the last step stops it.
public struct AdvanceRunIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Advance Timer"
    public static let description = IntentDescription(
        "Starts a timed topic, moves it to its next step, or stops it on the last one.")
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Topic") public var topic: TopicEntity
    @Parameter(title: "Action", default: .auto) public var action: RunActionKind

    public static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$topic)'s timer") }

    public init() {}

    public init(topic: TopicEntity, action: RunActionKind = .auto) {
        self.topic = topic
        self.action = action
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let result = try await RunIntents.perform(
                RunIntentRequest(action: action.action, topicId: topic.id, origin: .siri))
            return .result(dialog: RunIntentDialog.make(result.outcome))
        } catch {
            guard let message = RunIntents.message(for: error) else { throw error }
            return .result(dialog: RunIntentDialog.make(message))
        }
    }
}

/// Siri's one timer App Shortcut (§11.3): start, next, stop, pause or resume, on a topic or, without
/// one, on the only open run (several are asked; a start without one asks for the topic).
public struct RunActionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Timer"
    public static let description = IntentDescription("Starts, advances, pauses, resumes or stops a quickR timer.")
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Action", default: .next) public var action: RunActionKind
    @Parameter(title: "Topic") public var topic: TopicEntity?

    public static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$topic)'s timer") }

    public init() {}

    public init(action: RunActionKind, topic: TopicEntity? = nil) {
        self.action = action
        self.topic = topic
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            var result = try await RunIntents.perform(
                RunIntentRequest(action: action.action, topicId: topic?.id, origin: .siri))
            if case .chooseTopic(let refs) = result.outcome {
                let chosen: TopicEntity
                if refs.isEmpty {
                    chosen = try await $topic.requestValue("Which topic?")
                } else {
                    let options = refs.compactMap { ref in
                        UUID(uuidString: ref.id).map { TopicEntity(id: $0, name: ref.name, slug: ref.slug) }
                    }
                    chosen = try await $topic.requestDisambiguation(among: options, dialog: "Which timer?")
                }
                result = try await RunIntents.perform(
                    RunIntentRequest(action: action.action, topicId: chosen.id, origin: .siri))
            }
            return .result(dialog: RunIntentDialog.make(result.outcome))
        } catch {
            guard let message = RunIntents.message(for: error) else { throw error }
            return .result(dialog: RunIntentDialog.make(message))
        }
    }
}
#endif
