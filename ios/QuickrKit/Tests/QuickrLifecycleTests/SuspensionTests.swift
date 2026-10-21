import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `AppSession`'s background expiry against GRDB's real suspension (`NotificationCenter.default`):
/// the cancelled flush's cleanup (the item made uncertain, the lease released) must have committed
/// before the database is suspended, or a suspended GRDB refuses it and leaves the item in flight
/// and the lease held.
/// Run on their own (`make ios-lifecycle-test`, QUICKR_LIFECYCLE_TESTS=1): GRDB's suspension is
/// process-wide and would interrupt any other suite running in the same `swift test` process.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["QUICKR_LIFECYCLE_TESTS"] == "1",
        "posts GRDB's process-wide suspension: run with make ios-lifecycle-test"))
@MainActor struct SuspensionTests {
    @Test func expiryLetsTheCancelledFlushCommitItsCleanupBeforeSuspending() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-suspension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let topic = try await Self.seed(root)
        let transport = ParkedPosts()
        let session = try AppSession(
            configuration: .init(
                location: StoreLocation(root: root), transport: transport, notifier: nil,
                notificationCenter: .default))
        await session.start()
        #expect(session.phase == .ready)
        let store = try #require(session.store)

        let id = try await session.log(topic: topic, answers: ["n": .int(1)], version: 1)
        await transport.waitForPost()  // the flush's POST is in flight
        let episode = session.beginBackground()
        let background = Task { await session.didEnterBackground(episode) }
        await session.backgroundTimeExpiring(episode, within: .seconds(10))
        _ = await background.value

        // Resume to look: the cleanup must already be on disk.
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        let item = try #require(try await store.outbox.item(id: id.wireString))
        #expect(item.state == .uncertain && item.maybeDelivered && item.claimToken == nil)
        let lease = try await store.writer.read { db in try LeaseTable.record(db, .flush) }
        #expect(lease.owner == nil, "the flush lease was released before the suspend")
        await session.shutdown()
    }

    /// GRDB's real suspension, end to end: once the session has gone to the background, a write to
    /// its pool is refused ("Database is suspended", what an app write after suspending would get);
    /// back in the foreground the same write succeeds. The hosted app tests (SyncControllerTests)
    /// use their own notification center, so this suite is where real suspension is covered.
    @Test func aBackgroundedSessionRefusesWritesUntilItIsActiveAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-suspension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await Self.seed(root)
        let session = try AppSession(
            configuration: .init(
                location: StoreLocation(root: root), transport: ParkedPosts(), notifier: nil,
                notificationCenter: .default))
        await session.start()
        let store = try #require(session.store)
        @Sendable func touch(_ db: Database) throws { try db.execute(sql: "UPDATE sync_state SET epoch = epoch") }
        try await store.writer.write(touch)  // writable before

        _ = await session.didEnterBackground(session.beginBackground())
        do {
            try await store.writer.write(touch)
            Issue.record("a suspended database accepted a write")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_ABORT, "\(error)")
            #expect(error.message?.contains("suspended") == true, "\(error)")
        }

        await session.didBecomeActive()
        try await store.writer.write(touch)  // the same write, resumed
        await session.shutdown()
    }

    /// HANDLER-RESUME: a notification action tapped while the app is alive but suspended in the
    /// background (its GRDB suspended, the common case on a phone) logs its entry, and the store is
    /// suspended again afterwards. The handler runs with the store held resumed, as
    /// `NotificationResponder.run` runs it; without that it is refused
    /// (`storeUnavailable`) and nothing is written.
    @Test func aNotificationActionWhileSuspendedLogsAndSuspendsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "quickr-suspension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mood = try await Self.seedChoiceTopic(root)
        let session = try AppSession(
            configuration: .init(
                location: StoreLocation(root: root), transport: ParkedPosts(), notifier: nil,
                notificationCenter: .default))
        await session.start()
        let store = try #require(session.store)
        @Sendable func touch(_ db: Database) throws { try db.execute(sql: "UPDATE sync_state SET epoch = epoch") }

        _ = await session.didEnterBackground(session.beginBackground())
        await #expect(throws: DatabaseError.self, "suspended before the action") { try await store.writer.write(touch) }

        let descriptor = try #require(
            NotificationCategory.descriptor(questions: mood.questions, counts: [:], last: nil))
        let category = NotificationCategory(
            serverId: Self.serverA, topicId: mood.id.wireString, version: mood.currentVersion, descriptor: descriptor)
        let info = QuickrNotificationInfo(
            kind: "due", serverId: Self.serverA, topicId: mood.id.wireString, topicSlug: mood.slug,
            version: mood.currentVersion, dueSince: "2026-03-04T11:00:00Z", url: "/t/\(mood.slug)/record",
            quickLog: descriptor)
        let handler = NotificationActionHandler(
            partitions: session.partitions, center: FakeNotificationCenter(), sender: { _ in nil },
            owner: "app:test", gate: RegistryActiveGate(registry: session.partitions.registry))
        let outcome = await session.withStoreResumed {
            await handler.handle(
                NotificationActionResponse(
                    action: .custom(category.actions[0].identifier), title: "Mood", quickr: info))
        }
        guard case .logged(let entryId, let serverId, _) = outcome else {
            Issue.record("the action wasn't logged: \(outcome)")
            return
        }
        #expect(serverId == Self.serverA)
        let item = try await store.outbox.item(id: entryId.wireString)
        #expect(item?.kind == .entryCreate, "the entry is written")

        await #expect(throws: DatabaseError.self, "suspended again after the action") {
            try await store.writer.write(touch)
        }
        await session.didBecomeActive()
        try await store.writer.write(touch)
        await session.shutdown()
    }

    /// Action identifiers carry canonical UUIDs, so this test's server has one.
    static let serverA = "0b9e0000-0000-4000-8000-0000000000aa"

    /// A store bootstrapped from server `serverA` (epoch E1) with one single-choice topic (Mood),
    /// so a reminder's chips are its actions.
    static func seedChoiceTopic(_ root: URL) async throws -> Topic {
        let partitions = try StorePartitions.open(at: StoreLocation(root: root), notifier: nil)
        let store = try await partitions.createStore(serverId: Self.serverA, baseURL: "https://quickr.example")
        try await partitions.registry.setActive(Self.serverA)
        let question = Question(
            key: "mood", label: "Mood",
            kind: .choice(.init(options: ["good", "ok", "bad"].map { EnumOption(value: $0, label: $0.capitalized) })))
        let now = Date()
        let topic = Topic(
            id: UUID(), slug: "mood", name: "Mood", currentVersion: 1, revision: 1, questionCount: 1, createdAt: now,
            updatedAt: now, questions: [question])
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.upsert(db, topic: topic)
        }
        return topic
    }

    /// A store bootstrapped from server `s` (epoch E1) with one topic, so the session binds without
    /// the network.
    static func seed(_ root: URL) async throws -> TopicRef {
        let partitions = try StorePartitions.open(at: StoreLocation(root: root), notifier: nil)
        let store = try await partitions.createStore(serverId: "s", baseURL: "https://quickr.example")
        try await partitions.registry.setActive("s")
        let topic = try #require(try await PlaceholderTopicRepository().topics().first?.topic)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
            _ = try ServerLayer.upsert(db, topic: topic)
        }
        return TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
    }
}

/// POSTs never get an answer (they are "in the network"); anything else fails fast.
private final class ParkedPosts: Transport {
    private let arrived = Mutex<[CheckedContinuation<Void, Never>]?>([])

    func waitForPost() async {
        await withCheckedContinuation { continuation in
            let ready = arrived.withLock { waiters -> Bool in
                guard waiters != nil else { return true }
                waiters!.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == .post else { throw TransportError.unreachable("not in this test") }
        let waiters = arrived.withLock { waiters in
            defer { waiters = nil }
            return waiters ?? []
        }
        for waiter in waiters { waiter.resume() }
        return await withUnsafeContinuation { _ in }
    }
}
