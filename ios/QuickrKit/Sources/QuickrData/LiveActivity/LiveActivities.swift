import Foundation
import OSLog
import QuickrCore

/// This device's run activities (timers.md §10.3): local first, so the device that taps updates or
/// ends its activity at once; the server's pushes are for the other devices.
///
/// - ``reconcile(startFor:)``: after this device's taps (with `startFor` after a start), on every
///   activation, after every sync (foreground, background refresh, a push), and whenever the local
///   view of runs changes. Calls run one after another, so two never request an activity for the
///   same topic. While the Settings switch is off it ends any live activity (one push-to-start
///   may still bring before its token is unregistered).
/// - ``tokensChanged()``: a push-to-start or update token arrived; registers what is owed.
/// - ``setEnabled(_:)``: the Settings switch. Off ends every activity at once and unregisters the
///   tokens (durably: retried until the server has them); on registers the push-to-start token
///   again and reconciles.
///
/// Token registration runs beside the activity work, never on its chain: a tap's local update
/// never waits on the network. Each local update and request marks the activity stale 4 hours
/// ahead.
@MainActor
public final class LiveActivities {
    private let center: any RunActivityCenter
    private let tokens: LiveActivityTokens?
    private let snapshot: @Sendable () async -> RunActivitySnapshot?
    private let now: @Sendable () -> Date
    private var enabled: Bool
    /// The activity work in order: each call waits for the one before.
    private var tail: Task<Void, Never>?
    /// The token work in order, apart from the activity work.
    private var tokenTail: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "live-activity")

    /// - Parameters:
    ///   - snapshot: the active store's local view; nil without one, or before its bootstrap
    ///     (activities are then left alone, and tokens are still registered).
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
            let snapshot = await snapshot()
            guard enabled else {
                for activity in await center.activities() where activity.phase.isLive {
                    await center.end(id: activity.id, activity.state, dismissal: .immediate)
                }
                syncTokens(snapshot)
                return
            }
            if let snapshot {
                let activities = await center.activities()
                let start = await center.areActivitiesEnabled() ? topicId : nil
                for action in RunActivityPlan.actions(activities, snapshot, now: now(), startFor: start) {
                    await perform(action)
                }
            }
            syncTokens(snapshot)
        }
    }

    public func tokensChanged() async {
        syncTokens(await snapshot())
    }

    public func setEnabled(_ on: Bool) async {
        await serially { [self] in
            guard on != enabled else { return }
            enabled = on
            if on { return }
            for activity in await center.activities() where activity.phase != .dismissed {
                await center.end(id: activity.id, activity.state, dismissal: .immediate)
            }
            syncTokens(nil)
        }
        if on { await reconcile() }
    }

    /// Waits for the token work asked for so far (tests).
    public func tokensSettled() async {
        while let task = tokenTail {
            await task.value
            if tokenTail == task { return }
        }
    }

    /// Queues one token pass over the activities as they are now.
    private func syncTokens(_ snapshot: RunActivitySnapshot?) {
        guard let tokens else { return }
        let (previous, center, enabled) = (tokenTail, center, enabled)
        tokenTail = Task {
            await previous?.value
            await tokens.sync(await center.activities(), snapshot, enabled: enabled)
        }
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
/// the run it shows. Online-only and best effort: a registration that fails is tried again at the
/// next pass.
///
/// - **Push-to-start** is registered per (token, device token, server): a new server gets it too.
/// - **Update tokens** are registered at once with the activity's own run and topic, before this
///   phone has synced the run or bound a session (an activity push-to-start brought in the
///   background): the server keeps it for an open run, ignores an unknown one, and sends a
///   closed one its `end`. One this device registered before the server knew the run (its own
///   start, still queued) is registered again once it does, and again when the activity moves to
///   another run.
/// - **Off** (the Settings switch): every token this device has, the current push-to-start one
///   included, is owed a delete, kept in `owed` (persisted) and retried at every pass until the
///   server has it.
///
/// `device_token` is this phone's APNs token; nothing is registered before it has one.
public actor LiveActivityTokens {
    public struct Dependencies: Sendable {
        public var register: @Sendable (LiveActivityInDTO) async throws -> Void
        public var unregister: @Sendable (String) async throws -> Void
        public var deviceToken: @Sendable () async -> String?
        public var environment: @Sendable () -> ApnsEnvironment?
        /// The active server's id, lowercase: what the push-to-start token is registered with.
        public var serverId: @Sendable () async -> String?
        /// The tokens owed a delete, kept across launches.
        public var loadOwed: @Sendable () -> [String]
        public var saveOwed: @Sendable ([String]) -> Void

        public init(
            register: @escaping @Sendable (LiveActivityInDTO) async throws -> Void,
            unregister: @escaping @Sendable (String) async throws -> Void,
            deviceToken: @escaping @Sendable () async -> String?,
            environment: @escaping @Sendable () -> ApnsEnvironment?,
            serverId: @escaping @Sendable () async -> String?,
            loadOwed: @escaping @Sendable () -> [String] = { [] },
            saveOwed: @escaping @Sendable ([String]) -> Void = { _ in }
        ) {
            self.register = register
            self.unregister = unregister
            self.deviceToken = deviceToken
            self.environment = environment
            self.serverId = serverId
            self.loadOwed = loadOwed
            self.saveOwed = saveOwed
        }
    }

    private struct StartRegistration: Equatable {
        var token: String
        var device: String
        var serverId: String
    }

    private struct UpdateRegistration: Equatable {
        var runId: String
        /// The server knew the run then (else it didn't keep the token).
        var serverKnew: Bool
    }

    private let dependencies: Dependencies
    /// The latest push-to-start token, and where it was registered.
    private var startToken: String?
    private var startRegistered: StartRegistration?
    /// Each activity's update token, by activity id.
    private var updateTokens: [String: String] = [:]
    /// What each update token was registered for, by token.
    private var registered: [String: UpdateRegistration] = [:]
    /// Tokens owed a delete (the switch went off).
    private var owed: Set<String>

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        owed = Set(dependencies.loadOwed())
    }

    /// From `Activity.pushToStartTokenUpdates` (lowercase hex).
    public func pushToStart(_ token: String) {
        startToken = token.lowercased()
    }

    /// From an activity's `pushTokenUpdates` (lowercase hex).
    public func update(_ token: String, activityId: String) {
        updateTokens[activityId] = token.lowercased()
    }

    /// One pass: the deletes owed first; then, while `enabled`, the push-to-start token and each
    /// live activity's update token; while not, every token this device has becomes owed.
    public func sync(_ activities: [RunActivityRecord], _ snapshot: RunActivitySnapshot?, enabled: Bool) async {
        if !enabled {
            // Every token this device has, the ended activities' too (they were just ended).
            owe(Set(registered.keys).union(updateTokens.values).union(startToken.map { [$0] } ?? []))
            registered = [:]
            startRegistered = nil
        }
        let live = activities.filter(\.phase.isLive)
        let liveIds = Set(live.map(\.id))
        updateTokens = updateTokens.filter { liveIds.contains($0.key) }
        let kept = Set(updateTokens.values)
        registered = registered.filter { kept.contains($0.key) }  // the server drops an ended run's
        if enabled {
            // Back on: a token about to be registered again is no longer owed a delete.
            forgive(Set(updateTokens.values).union(startToken.map { [$0] } ?? []))
        }
        await payOwed()
        guard enabled, let device = await dependencies.deviceToken(), let environment = dependencies.environment(),
            let serverId = await dependencies.serverId()?.lowercased()
        else { return }
        if let token = startToken {
            let want = StartRegistration(token: token, device: device, serverId: serverId)
            if startRegistered != want {
                let body = LiveActivityInDTO(token: token, kind: .start, deviceToken: device, environment: environment)
                if (try? await dependencies.register(body)) != nil { startRegistered = want }
            }
        }
        for activity in live where activity.attributes.serverId.lowercased() == serverId {
            guard let token = updateTokens[activity.id] else { continue }
            // The view's run, when this phone has it: its server id (a merge target) once the
            // server knows it. Not in the view (push-to-start, not synced yet): the server knows it.
            let run = snapshot.flatMap { RunActivityPlan.run(for: activity.attributes, showing: nil, in: $0) }
                .flatMap { $0.answers(to: activity.state.runId) ? $0 : nil }
            let serverKnows = run.map { $0.server != nil } ?? true
            let runId = run?.server?.id.wireString ?? activity.state.runId.lowercased()
            let want = UpdateRegistration(runId: runId, serverKnew: serverKnows)
            if let done = registered[token], done.runId == runId, done.serverKnew || !serverKnows { continue }
            let body = LiveActivityInDTO(
                token: token, kind: .update, deviceToken: device, environment: environment,
                topicId: activity.attributes.topicId.lowercased(), runId: runId)
            if (try? await dependencies.register(body)) != nil { registered[token] = want }
        }
    }

    private func owe(_ tokens: Set<String>) {
        guard !tokens.isSubset(of: owed) else { return }
        owed.formUnion(tokens)
        dependencies.saveOwed(owed.sorted())
    }

    private func forgive(_ tokens: Set<String>) {
        guard !owed.isDisjoint(with: tokens) else { return }
        owed.subtract(tokens)
        dependencies.saveOwed(owed.sorted())
    }

    private func payOwed() async {
        guard !owed.isEmpty else { return }
        for token in owed.sorted() where (try? await dependencies.unregister(token)) != nil {
            owed.remove(token)
        }
        dependencies.saveOwed(owed.sorted())
    }
}

extension LiveActivityTokens.Dependencies {
    public struct Failed: Error, Sendable {}

    /// Over the active server's API (`registerLiveActivity`, `deleteLiveActivity`). A request that
    /// may succeed later (offline, a 5xx) throws, to be tried again; one the server refuses for
    /// good counts as done, so it isn't sent forever.
    public static func api(
        _ client: @escaping @Sendable () async -> APIClient?, deviceToken: @escaping @Sendable () async -> String?,
        environment: @escaping @Sendable () -> ApnsEnvironment?, serverId: @escaping @Sendable () async -> String?,
        loadOwed: @escaping @Sendable () -> [String], saveOwed: @escaping @Sendable ([String]) -> Void
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
            deviceToken: deviceToken, environment: environment, serverId: serverId, loadOwed: loadOwed,
            saveOwed: saveOwed)
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
