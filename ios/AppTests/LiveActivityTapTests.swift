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
        // The server answers 503: the tap stays queued, and its flush is seen to be tried.
        let transport = RecordingTransport()
        let environment = AppEnvironment.live(location: location, transport: transport, categoryCenter: nil)
        defer { Task { await environment.session?.shutdown() } }
        #expect(environment.session?.store == nil, "launched for the intent: nothing bound yet")

        let next = RunActivityTap(button: .next, serverId: "test-server", topicId: topic.id, runId: runId, seg: 0)
        try await environment.handleActivityTap(next)
        try await environment.handleActivityTap(next)
        let events = try await Self.runEvents(location)
        #expect(events == ["next"])
        let sent = transport.requests.count
        #expect(sent >= 1, "flushed within the intent's budget")

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
}
