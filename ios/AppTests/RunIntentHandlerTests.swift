import Foundation
import GRDB
import QuickrCore
import QuickrData
import Testing

@testable import QuickR

/// The run intents in the app's process (timers.md §11.3): the Action button, Siri, a timed
/// widget's buttons and the Timer Control all reach `handleRunIntent`, which shares the topic's
/// 450 ms cooldown (so a double press can't start then stop a run), refuses a widget drawn from
/// another store, and requests the Live Activity after this device's own Start.
@MainActor @Suite(.serialized) struct RunIntentHandlerTests {
    /// The seeded store with Coffee timed (its current version), no run.
    static func seeded() async throws -> (StoreLocation, Topic) {
        let location = try await TestStores.seededLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        let topic = try #require(try await PlaceholderTopicRepository().topics().map(\.topic).first)
        let version = TopicVersion(
            version: topic.currentVersion, questions: [], timer: TopicTimer(steps: LiveActivityTapTests.steps),
            createdAt: Date())
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.insert(db, version: version, id: UUID(), topicId: topic.id)
        }
        return (location, topic)
    }

    @Test func aDoublePressStartsOnceThenTheNextPressAdvances() async throws {
        let (location, topic) = try await Self.seeded()
        defer { TestStores.remove(location) }
        let center = AppActivityCenter()
        let environment = LiveActivityTapTests.environment(
            location, transport: RecordingTransport(), activityCenter: center)
        defer { Task { await environment.session?.shutdown() } }
        await environment.start()

        let auto = RunIntentRequest(action: .auto, topicId: topic.id, origin: .siri)
        async let first = environment.handleRunIntent(auto)
        async let second = environment.handleRunIntent(auto)
        let results = try await [first, second]
        let started: [RunIntentResult] = results.filter { (result: RunIntentResult) -> Bool in result.started }
        #expect(started.count == 1)
        let ignoredOutcome: RunIntentOutcome = .ignored(topic: nil)
        let ignored: [RunIntentResult] = results.filter { (result: RunIntentResult) -> Bool in
            result.outcome == ignoredOutcome
        }
        #expect(ignored.count == 1)
        let events = try await LiveActivityTapTests.runEvents(location)
        #expect(events == ["start"])
        let requests = await center.requests
        #expect(requests.count == 1, "this device's own Start requests its activity")

        // Siri without a topic: the cooldown is the resolved topic's (its only open run).
        let untargeted = try await environment.handleRunIntent(
            RunIntentRequest(action: .stop, topicId: nil, origin: .siri))
        let ignoredStop: RunIntentOutcome = .ignored(topic: nil)
        #expect(untargeted.outcome == ignoredStop)
        let afterStop = try await LiveActivityTapTests.runEvents(location)
        #expect(afterStop == ["start"])

        try await Task.sleep(for: .milliseconds(500))
        let next = try await environment.handleRunIntent(auto)
        let expected: RunIntentOutcome = .advanced(done: "A", ms: next.outcome.ms, next: "B")
        #expect(next.outcome == expected)
        let after = try await LiveActivityTapTests.runEvents(location)
        #expect(after == ["start", "next"])
        let origins = try await Self.origins(location)
        #expect(origins == [.siri])
        let still = await center.requests
        #expect(still.count == 1, "a tap updates the activity, it doesn't request another")
    }

    @Test func aWidgetFromAnotherStoreIsRefused() async throws {
        let (location, topic) = try await Self.seeded()
        defer { TestStores.remove(location) }
        let environment = LiveActivityTapTests.environment(location, transport: RecordingTransport())
        defer { Task { await environment.session?.shutdown() } }
        let request = RunIntentRequest(
            action: .start, topicId: topic.id, origin: .widget, scope: EntryScope("other-server/1"))
        await #expect(throws: RunIntents.Failure.stale) { try await environment.handleRunIntent(request) }
        let events = try await LiveActivityTapTests.runEvents(location)
        #expect(events.isEmpty)
    }

    @Test func theIntentsReachTheRegisteredHandler() async throws {
        let (location, topic) = try await Self.seeded()
        defer { TestStores.remove(location) }
        let environment = LiveActivityTapTests.environment(location, transport: RecordingTransport())
        defer { Task { await environment.session?.shutdown() } }
        environment.registerRunIntents()
        let entity = TopicEntity(topic)
        _ = try await AdvanceRunIntent(topic: entity).perform()
        try await Task.sleep(for: .milliseconds(500))
        let store = try #require(try await environment.session?.partitions.openActiveStore(role: .app)?.store)
        let widget = RunWidgetIntent(action: .auto, topicId: topic.id, scope: store.scope)
        _ = try await widget.perform()
        let events = try await LiveActivityTapTests.runEvents(location)
        #expect(events == ["start", "next"])
        let origins = try await Self.origins(location)
        #expect(origins == [.siri, .widget])
    }

    static func origins(_ location: StoreLocation) async throws -> Set<OutboxOrigin> {
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try #require(try await partitions.openActiveStore(role: .app)?.store)
        return try await store.writer.read { db in
            Set(try OutboxStorage.items(db).filter { $0.kind == .runEvent }.map(\.origin))
        }
    }
}

extension RunIntentOutcome {
    /// The duration an outcome carries, for comparing the rest of it.
    fileprivate var ms: Int {
        switch self {
        case .advanced(_, let ms, _), .lapped(_, let ms), .saved(_, let ms), .savedNeedsDetails(_, let ms): ms
        default: 0
        }
    }
}
