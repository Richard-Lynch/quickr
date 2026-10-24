import Foundation
import OSLog
import QuickrCore

/// This device's run activities (timers.md §10.3): local first, so the device that taps updates or
/// ends its activity at once; the server's pushes are for the other devices.
///
/// - ``reconcile(startFor:)``: after this device's taps (with `startFor` after a start), on every
///   activation, and whenever the local view of runs changes (a sync, an acknowledgement). Calls
///   run one after another, so two never request an activity for the same topic.
/// - ``tokensChanged()``: a push-to-start or update token arrived; registers what is owed.
/// - ``setEnabled(_:)``: the Settings switch. Off ends every activity at once and unregisters the
///   tokens; on registers the push-to-start token again and reconciles.
///
/// Each local update and request marks the activity stale 4 hours ahead.
@MainActor
public final class LiveActivities {
    private let center: any RunActivityCenter
    private let tokens: LiveActivityTokens?
    private let snapshot: @Sendable () async -> RunActivitySnapshot?
    private let now: @Sendable () -> Date
    private var enabled: Bool
    /// The calls in order: each waits for the one before.
    private var tail: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "live-activity")

    /// - Parameters:
    ///   - snapshot: the active store's local view; nil without one (nothing is done).
    ///   - enabled: the Settings switch's value at launch.
    public init(
        center: any RunActivityCenter, tokens: LiveActivityTokens?, enabled: Bool,
        snapshot: @escaping @Sendable () async -> RunActivitySnapshot?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.center = center
        self.tokens = tokens
        self.enabled = enabled
        self.snapshot = snapshot
        self.now = now
    }

    /// The Settings switch is on.
    public var isEnabled: Bool { enabled }

    /// Whether this device would show a run it starts now: what its start's `device.live_activity`
    /// says (the server then skips this device's push-to-start).
    public func willShowLocally() async -> Bool {
        guard enabled else { return false }
        return await center.areActivitiesEnabled()
    }

    public func reconcile(startFor topicId: UUID? = nil) async {
        await serially { [self] in
            guard enabled, let snapshot = await snapshot() else { return }
            let activities = await center.activities()
            let actions = RunActivityPlan.actions(
                activities, snapshot, now: now(), startFor: await center.areActivitiesEnabled() ? topicId : nil)
            for action in actions { await perform(action) }
            await tokens?.sync(await center.activities(), snapshot)
        }
    }

    public func tokensChanged() async {
        await serially { [self] in
            guard enabled, let tokens else { return }
            await tokens.sync(await center.activities(), await snapshot())
        }
    }

    public func setEnabled(_ on: Bool) async {
        await serially { [self] in
            guard on != enabled else { return }
            enabled = on
            if on { return }
            for activity in await center.activities() where activity.phase != .dismissed {
                await center.end(id: activity.id, activity.state, dismissal: .immediate)
            }
            await tokens?.unregisterAll()
        }
        if on { await reconcile() }
    }

    private func perform(_ action: RunActivityAction) async {
        let stale = now().addingTimeInterval(RunActivityContent.staleSeconds)
        switch action {
        case .request(let attributes, let state):
            do {
                _ = try await center.request(attributes, state, staleDate: stale)
            } catch {
                // §10.3 Limits: the run works without one (push-to-start may still show it).
                Self.log.notice("Live Activity refused: \(String(describing: error), privacy: .public)")
            }
        case .update(let id, let state):
            await center.update(id: id, state, staleDate: stale)
        case .end(let id, let state, let dismissal):
            await center.end(id: id, state, dismissal: dismissal)
        }
    }

    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        await task.value
    }
}

/// The Live Activity tokens this device registers with the active server (timers.md §10.3,
/// Tokens): its push-to-start token, and each live activity's update token with its topic and
/// run. Online-only and best effort: a registration that fails is tried again at the next
/// reconciliation. An update token is registered once the server knows its run (an unknown run's
/// is not kept there), and again when the activity moves to another run (a merge, a new run).
/// `device_token` is this phone's APNs token; nothing is registered before it has one.
public actor LiveActivityTokens {
    public struct Dependencies: Sendable {
        public var register: @Sendable (LiveActivityInDTO) async throws -> Void
        public var unregister: @Sendable (String) async throws -> Void
        public var deviceToken: @Sendable () async -> String?
        public var environment: @Sendable () -> ApnsEnvironment?

        public init(
            register: @escaping @Sendable (LiveActivityInDTO) async throws -> Void,
            unregister: @escaping @Sendable (String) async throws -> Void,
            deviceToken: @escaping @Sendable () async -> String?,
            environment: @escaping @Sendable () -> ApnsEnvironment?
        ) {
            self.register = register
            self.unregister = unregister
            self.deviceToken = deviceToken
            self.environment = environment
        }
    }

    private let dependencies: Dependencies
    /// The latest push-to-start token, and the device token it was registered with.
    private var startToken: String?
    private var startRegistered: (token: String, device: String)?
    /// Each activity's update token, by activity id.
    private var updateTokens: [String: String] = [:]
    /// The run each update token was registered for, by token.
    private var registered: [String: String] = [:]

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// From `Activity.pushToStartTokenUpdates` (lowercase hex).
    public func pushToStart(_ token: String) {
        startToken = token.lowercased()
    }

    /// From an activity's `pushTokenUpdates` (lowercase hex).
    public func update(_ token: String, activityId: String) {
        updateTokens[activityId] = token.lowercased()
    }

    /// Registers what is owed: the push-to-start token, and each live activity's update token for
    /// the run it shows, once the server knows that run (`snapshot`).
    public func sync(_ activities: [RunActivityRecord], _ snapshot: RunActivitySnapshot?) async {
        guard let device = await dependencies.deviceToken(), let environment = dependencies.environment() else {
            return
        }
        if let token = startToken, startRegistered?.token != token || startRegistered?.device != device {
            let body = LiveActivityInDTO(token: token, kind: .start, deviceToken: device, environment: environment)
            if (try? await dependencies.register(body)) != nil { startRegistered = (token, device) }
        }
        let live = activities.filter(\.phase.isLive)
        let liveIds = Set(live.map(\.id))
        updateTokens = updateTokens.filter { liveIds.contains($0.key) }
        let kept = Set(updateTokens.values)
        registered = registered.filter { kept.contains($0.key) }  // the server drops an ended run's
        guard let snapshot else { return }
        for activity in live {
            guard let token = updateTokens[activity.id],
                let run = RunActivityPlan.run(for: activity.attributes, in: snapshot),
                run.answers(to: activity.state.runId), let server = run.server
            else { continue }
            let runId = server.id.wireString
            guard registered[token] != runId else { continue }
            let body = LiveActivityInDTO(
                token: token, kind: .update, deviceToken: device, environment: environment,
                topicId: activity.attributes.topicId.lowercased(), runId: runId)
            if (try? await dependencies.register(body)) != nil { registered[token] = runId }
        }
    }

    /// The Settings switch went off: every registered token is deleted (best effort). The
    /// push-to-start token is kept, to register again when it goes back on.
    public func unregisterAll() async {
        var owed = Array(registered.keys)
        if let start = startRegistered?.token { owed.append(start) }
        registered = [:]
        updateTokens = [:]
        startRegistered = nil
        for token in owed { try? await dependencies.unregister(token) }
    }
}

extension LiveActivityTokens.Dependencies {
    public struct Failed: Error, Sendable {}

    /// Over the active server's API (`registerLiveActivity`, `deleteLiveActivity`). A request that
    /// may succeed later (offline, a 5xx) throws, to be tried again; one the server refuses for
    /// good counts as done, so it isn't sent forever.
    public static func api(
        _ client: @escaping @Sendable () async -> APIClient?, deviceToken: @escaping @Sendable () async -> String?,
        environment: @escaping @Sendable () -> ApnsEnvironment?
    ) -> Self {
        Self(
            register: { body in
                guard let client = await client() else { throw Failed() }
                try settled(try? await client.registerLiveActivity(body).outcome)
            },
            unregister: { token in
                guard let client = await client() else { throw Failed() }
                try settled(try? await client.deleteLiveActivity(LiveActivityRefDTO(token: token)).outcome)
            },
            deviceToken: deviceToken, environment: environment)
    }

    private static func settled<T>(_ outcome: APIOutcome<T>?) throws {
        guard let outcome else { throw Failed() }
        switch outcome {
        case .success, .terminal, .notFound: return
        default: throw Failed()
        }
    }
}

/// No Live Activities: tests, previews, and the UI tests' fake app.
public struct NoRunActivityCenter: RunActivityCenter {
    public struct Unavailable: Error, Sendable {}

    public init() {}

    public func areActivitiesEnabled() async -> Bool { false }
    public func activities() async -> [RunActivityRecord] { [] }
    public func request(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date) async throws
        -> String
    { throw Unavailable() }
    public func update(id: String, _ state: RunActivityState, staleDate: Date) async {}
    public func end(id: String, _ state: RunActivityState, dismissal: RunActivityDismissal) async {}
}
