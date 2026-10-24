import Foundation
import GRDB
import QuickrCore

/// One open store file: `stores/<server_id>.g<store_gen>.sqlite` (sync-protocol.md §8.1). A
/// `Sendable` handle any actor or process can hold; the repositories, leases and fenced writes of
/// that file hang off it.
public struct LocalStore: Sendable {
    public let serverId: String
    public let storeGen: Int
    /// The store's identity for writes and outbox rows (`EntryScope`).
    public var scope: EntryScope { EntryScope(serverId: serverId, storeGen: storeGen) }
    /// nil for an in-memory test store.
    public let url: URL?
    public let writer: any DatabaseWriter
    public let leaseClock: any LeaseClock
    public let wallClock: any WallClock

    public init(
        serverId: String, storeGen: Int, url: URL?, writer: any DatabaseWriter, leaseClock: any LeaseClock,
        wallClock: any WallClock
    ) {
        self.serverId = serverId
        self.storeGen = storeGen
        self.url = url
        self.writer = writer
        self.leaseClock = leaseClock
        self.wallClock = wallClock
    }

    /// Inserts the `sync_state` row of a new store file (§2.1 step 3) unless it exists.
    public static func createSyncState(_ db: Database, serverId: String, baseURL: String) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO sync_state (id, server_id, base_url) VALUES (1, ?, ?)",
            arguments: [serverId, baseURL])
    }

    /// Records the server's new address in this store's `sync_state` (pulls read it there).
    public static func setBaseURL(_ db: Database, _ baseURL: String) throws {
        try db.execute(sql: "UPDATE sync_state SET base_url = ? WHERE id = 1", arguments: [baseURL])
    }

    // MARK: - Repositories

    public var topics: GRDBTopicRepository { GRDBTopicRepository(reader: writer) }
    public var versions: GRDBTopicVersionRepository { GRDBTopicVersionRepository(reader: writer) }
    public var entries: GRDBEntryRepository { GRDBEntryRepository(reader: writer) }
    public var runs: GRDBRunRepository { GRDBRunRepository(reader: writer) }
    public var outbox: GRDBOutboxRepository { GRDBOutboxRepository(writer: writer, wallClock: wallClock) }
    public var syncState: GRDBSyncStateRepository { GRDBSyncStateRepository(reader: writer) }
    public var leases: Leases { Leases(writer: writer, clock: leaseClock, wallClock: wallClock) }

    // MARK: - Fenced writes

    /// The atomic ack (sync-protocol.md §6) in one `IMMEDIATE` transaction.
    public func ack(itemId: String, sender: SenderContext, effect: AckEffect) async throws -> AckOutcome {
        let clock = leaseClock
        return try await writer.write { db in
            try AtomicAck.ack(db, itemId: itemId, sender: sender, effect: effect, at: clock.now())
        }
    }

    /// Reset step 4 (§12.1) on this file. With `intentToken`, refused if that attempt was vetoed.
    public func retire(
        confirmedCount: Int, confirmedMaxSeq: Int64, intentToken: String? = nil, sync: LeaseClaim, flush: LeaseClaim
    ) async throws -> RetireOutcome {
        let clock = leaseClock
        return try await writer.write { db in
            try StoreRetirement.retire(
                db, confirmedCount: confirmedCount, confirmedMaxSeq: confirmedMaxSeq, intentToken: intentToken,
                sync: sync, flush: flush, at: clock.now())
        }
    }

    /// Marks a reset attempt aborted on this file (see `StoreRetirement.vetoReset`).
    public func vetoReset(intentToken: String) async throws -> ResetVeto {
        try await writer.write { db in try StoreRetirement.vetoReset(db, intentToken: intentToken) }
    }

    public func isRetired() async throws -> Bool {
        try await writer.read { db in try StoreFence.isRetired(db) }
    }

    // MARK: - Observation

    /// The view topics, re-emitted on every change (here, or signalled by `refresh`).
    public func observeTopics(refresh: AsyncStream<Void>? = nil) -> AsyncThrowingStream<[ViewTopic], any Error> {
        StoreObservation.values(in: writer, refresh: refresh) { db in try StoreView.topics(db) }
    }

    public func observeEntries(topicId: UUID, limit: Int? = nil, refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<[ViewEntry], any Error>
    {
        let topicId = topicId.wireString
        return StoreObservation.values(in: writer, refresh: refresh) { db in
            try StoreView.entries(db, topicId: topicId, limit: limit)
        }
    }

    /// A topic's versions, oldest first, with their counted entries (`StoreView.versions`).
    public func observeVersions(topicId: UUID, refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<[TopicVersion], any Error>
    {
        let topicId = topicId.wireString
        return StoreObservation.values(in: writer, refresh: refresh) { db in
            try StoreView.versions(db, topicId: topicId)
        }
    }

    /// The server layer's runs (open or finishing) of a topic, or of every topic when `topicId` is
    /// nil (`StoreView.runs`), re-emitted on every change.
    public func observeRuns(topicId: UUID? = nil, refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<[Run], any Error>
    {
        let topicId = topicId?.wireString
        return StoreObservation.values(in: writer, refresh: refresh) { db in try StoreView.runs(db, topicId: topicId) }
    }

    public func observeOutbox(refresh: AsyncStream<Void>? = nil) -> AsyncThrowingStream<[OutboxItem], any Error> {
        StoreObservation.values(in: writer, refresh: refresh) { db in try OutboxStorage.items(db) }
    }

    public func observeSyncState(refresh: AsyncStream<Void>? = nil) -> AsyncThrowingStream<SyncState?, any Error> {
        StoreObservation.values(in: writer, refresh: refresh) { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
        }
    }
}
