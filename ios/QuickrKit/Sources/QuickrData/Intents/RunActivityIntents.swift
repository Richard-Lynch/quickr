import AppIntents
import Foundation
import QuickrCore
import Synchronization

/// One Live Activity button tap (timers.md §10.3): which button, on which (server, topic)'s
/// activity, for the run and segment it showed.
public struct RunActivityTap: Sendable, Hashable {
    public var button: RunActivityDisplay.Button
    public var serverId: String
    public var topicId: UUID
    public var runId: String
    /// The content state's `seg`: Next and Lap send it, so a tap on a segment that has moved on
    /// is void (§4.2).
    public var seg: Int

    public init(button: RunActivityDisplay.Button, serverId: String, topicId: UUID, runId: String, seg: Int) {
        self.button = button
        self.serverId = serverId
        self.topicId = topicId
        self.runId = runId
        self.seg = seg
    }

    /// The tap's write: `seg` from the content state (`RunTapTarget.shown`); the pause a Resume
    /// ends from the local view (the content state has no pause id).
    public var tapType: RunTapType {
        switch button {
        case .next: .next
        case .lap: .lap
        case .pause: .pause
        case .resume: .resume
        case .stop: .stop
        }
    }

    public var target: RunTapTarget { .shown(seg: seg, step: nil, pauseId: nil) }
}

/// Where the app registers what a Live Activity button does. iOS runs a `LiveActivityIntent` in
/// the app's process, launching it in the background if it was killed, so only the app
/// registers one; the widget extension, which only draws the buttons, never does.
public enum RunActivityTaps {
    public typealias Handler = @Sendable (RunActivityTap) async throws -> Void

    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        case noHandler

        public var description: String { "Open quickR to time this topic." }
    }

    private static let current = Mutex<Handler?>(nil)

    public static func register(_ handler: @escaping Handler) {
        current.withLock { $0 = handler }
    }

    public static func handler() -> Handler? { current.withLock { $0 } }

    public static func perform(_ tap: RunActivityTap) async throws {
        guard let handler = handler() else { throw Failure.noHandler }
        try await handler(tap)
    }
}

#if os(iOS)
/// A Live Activity button: Next, Lap, Pause, Resume or Stop. Not offered in Shortcuts (Siri's
/// run actions are I-INTENTS').
public struct RunActivityButtonIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Run Button"
    public static let description = IntentDescription("A button on a quickR Live Activity.")
    public static let isDiscoverable = false
    public static let supportedModes: IntentModes = .background

    @Parameter(title: "Button") public var button: String
    @Parameter(title: "Server") public var serverId: String
    @Parameter(title: "Topic") public var topicId: String
    @Parameter(title: "Run") public var runId: String
    @Parameter(title: "Segment") public var seg: Int

    public init() {}

    public init(_ button: RunActivityDisplay.Button, attributes: RunActivityAttributes, state: RunActivityState) {
        self.button = button.rawValue
        serverId = attributes.serverId
        topicId = attributes.topicId
        runId = state.runId
        seg = state.seg
    }

    public func perform() async throws -> some IntentResult {
        guard let button = RunActivityDisplay.Button(rawValue: button), let topic = UUID(uuidString: topicId) else {
            return .result()
        }
        try await RunActivityTaps.perform(
            RunActivityTap(button: button, serverId: serverId, topicId: topic, runId: runId, seg: seg))
        return .result()
    }
}
#endif
