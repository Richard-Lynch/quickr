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
@Suite(.serialized) @MainActor struct SuspensionTests {
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
        let background = Task { await session.didEnterBackground() }
        while !session.isBackgrounded { await Task.yield() }
        await session.backgroundTimeExpiring(within: .seconds(10))
        _ = await background.value

        // Resume to look: the cleanup must already be on disk.
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        let item = try #require(try await store.outbox.item(id: id.wireString))
        #expect(item.state == .uncertain && item.maybeDelivered && item.claimToken == nil)
        let lease = try await store.writer.read { db in try LeaseTable.record(db, .flush) }
        #expect(lease.owner == nil, "the flush lease was released before the suspend")
        await session.shutdown()
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
