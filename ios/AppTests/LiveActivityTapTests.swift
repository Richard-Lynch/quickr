import Foundation
import GRDB
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// A Live Activity button in the app's process (timers.md §10.3): iOS launches the app in the
/// background for it, so the session hasn't started or bound a store. The tap writes one
/// `run.event` through the active store, with the content state's `seg`; a second tap inside the
/// topic's cooldown writes nothing; another server's activity writes nothing.
@MainActor @Suite(.serialized) struct LiveActivityTapTests {
    static let steps = [TopicTimer.Step(key: "a", label: "A"), TopicTimer.Step(key: "b", label: "B")]

    /// The seeded store with Coffee timed (its current version) and an open run of it.
    static func seeded() async throws -> (StoreLocation, Topic, String) {
        let location = try await TestStores.seededLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        let topic = try #require(try await PlaceholderTopicRepository().topics().map(\.topic).first)
        let runId = UUID()
        let start = RunEvent(id: runId.wireString, type: .start, at: RunInstant.milliseconds(Date()) - 60_000)
        let state = try RunFold.fold(runId: runId.wireString, steps: steps, events: [start])
        let run = Run(
            id: runId, topicId: topic.id, version: topic.currentVersion, status: .running, revision: 1,
            startedAt: start.at, endedAt: nil, edited: false,
            events: [Run.StoredEvent(event: start, arrival: 1, effect: .applied, source: "web")], state: state,
            aliases: [])
        let version = TopicVersion(
            version: topic.currentVersion, questions: [], timer: TopicTimer(steps: steps), createdAt: Date())
        try await store.writer.write { db in
            // Bootstrapped from an epoch, so the outbox claims and sends.
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topic.id)
            _ = try ServerLayer.upsert(db, run: run)
        }
        return (location, topic, runId.wireString)
    }

    static func runEvents(_ location: StoreLocation) async throws -> [String] {
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        return try await store.writer.read { db in
            try OutboxStorage.items(db).filter { $0.kind == .runEvent }.compactMap {
                try $0.runEventPayload()?.event.type
            }
        }
    }

    @Test func aTapWritesThroughTheActiveStoreOnceInItsCooldown() async throws {
        let (location, topic, runId) = try await Self.seeded()
        defer { TestStores.remove(location) }
        // The server answers 503, so the tap stays queued. Its flush is awaited by the tap, within
        // a budget raised from the intent's 4 s so a slow runner can't spend it before sending.
        let transport = RecordingTransport()
        let environment = AppEnvironment.live(location: location, transport: transport, categoryCenter: nil)
        environment.activityTapFlushBudget = .seconds(60)
        defer { Task { await environment.session?.shutdown() } }
        #expect(environment.session?.store == nil, "launched for the intent: nothing bound yet")

        let next = RunActivityTap(button: .next, serverId: "test-server", topicId: topic.id, runId: runId, seg: 0)
        // A double tap: the second arrives while the first is still being written and flushed.
        async let first: Void = environment.handleActivityTap(next)
        async let second: Void = environment.handleActivityTap(next)
        _ = try await (first, second)
        let events = try await Self.runEvents(location)
        #expect(events == ["next"])
        let sent = transport.requests.count
        #expect(sent >= 1, "flushed before the tap returned")

        let other = RunActivityTap(button: .stop, serverId: "other-server", topicId: topic.id, runId: runId, seg: 0)
        try await Task.sleep(for: .milliseconds(500))
        try await environment.handleActivityTap(other)
        let after = try await Self.runEvents(location)
        #expect(after == ["next"], "another server's activity writes nothing here")
    }

    @Test func theButtonIntentReachesTheRegisteredHandler() async throws {
        let (location, topic, runId) = try await Self.seeded()
        defer { TestStores.remove(location) }
        let environment = AppEnvironment.live(
            location: location, transport: RecordingTransport(), categoryCenter: nil)
        defer { Task { await environment.session?.shutdown() } }
        environment.registerLiveActivityTaps()
        let attributes = RunActivityContent.attributes(serverId: "test-server", topicId: topic.id, topicName: "Coffee")
        let state = RunActivityState(
            runId: runId, revision: 1, status: "running", startedAt: 0, seg: 0, segStartedAt: 0, label: "A",
            stepIndex: 0, stepCount: 2, nextLabel: "B", pausedAt: nil, pausedMsBeforeSeg: 0, pausedMsInSeg: 0,
            endedAt: nil, activeMs: nil)
        _ = try await RunActivityButtonIntent(.pause, attributes: attributes, state: state).perform()
        let events = try await Self.runEvents(location)
        #expect(events == ["pause"])
    }

    /// I-NOTIF's seam (timers.md §10.2): the answer is prompt and makes no request; after
    /// `.started` the run's activity is requested once per (server, topic), from the run as
    /// written; another server's start shows nothing here.
    @Test func aNotificationStartRequestsOneActivity() async throws {
        let (location, topic, runId) = try await Self.seeded()
        defer { TestStores.remove(location) }
        let center = AppActivityCenter()
        let environment = AppEnvironment.live(
            location: location, transport: RecordingTransport(), categoryCenter: nil, activityCenter: center)
        defer { Task { await environment.session?.shutdown() } }
        await environment.start()
        let start = NotificationRunStart(
            serverId: "test-server", topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name),
            runId: try #require(UUID(uuidString: runId)), version: topic.currentVersion, startedAt: Date())
        let shown = await environment.liveActivityForNotificationStart(start)
        #expect(shown == false, "not in the foreground: iOS would refuse, push-to-start shows it")
        let none = await center.requests
        #expect(none.isEmpty)

        await environment.notificationRunStarted(runId: runId, serverId: "other-server")
        await environment.notificationRunStarted(runId: runId, serverId: "TEST-SERVER")
        await environment.notificationRunStarted(runId: runId, serverId: "test-server")
        let requests = await center.requests
        #expect(requests.count == 1)
        let first = try #require(requests.first)
        #expect(first.attributes.topicId == topic.id.wireString)
        #expect(first.state.runId == runId)
    }
}

/// ActivityKit's activities in memory, for the app's tests.
actor AppActivityCenter: RunActivityCenter {
    struct Request: Sendable {
        var attributes: RunActivityAttributes
        var state: RunActivityState
    }

    private(set) var requests: [Request] = []

    func areActivitiesEnabled() -> Bool { true }

    func activities() -> [RunActivityRecord] {
        requests.enumerated().map { index, request in
            RunActivityRecord(
                id: "a\(index)", attributes: request.attributes, state: request.state, staleDate: nil, phase: .active)
        }
    }

    func request(_ attributes: RunActivityAttributes, _ state: RunActivityState, staleDate: Date) -> String {
        requests.append(Request(attributes: attributes, state: state))
        return "a\(requests.count - 1)"
    }

    func update(id: String, _ state: RunActivityState, staleDate: Date) {}
    func end(id: String, _ state: RunActivityState, dismissal: RunActivityDismissal) {}
}
