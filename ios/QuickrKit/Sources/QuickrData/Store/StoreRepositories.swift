import Foundation
import GRDB
import QuickrCore

// The C1 repository protocols over one store file. Reads return the view (`StoreView`); each
// method is one read or one `IMMEDIATE` write transaction on GRDB's queue.

public struct GRDBTopicRepository: TopicRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func topics() async throws -> [ViewTopic] {
        try await reader.read { db in try StoreView.topics(db) }
    }

    public func topic(id: UUID) async throws -> ViewTopic? {
        try await reader.read { db in try StoreView.topic(db, id: id.wireString) }
    }

    public func topic(slug: String) async throws -> ViewTopic? {
        try await reader.read { db in try StoreView.topic(db, slug: slug) }
    }
}

public struct GRDBTopicVersionRepository: TopicVersionRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func versions(topicId: UUID) async throws -> [TopicVersion] {
        try await reader.read { db in try StoreView.versions(db, topicId: topicId.wireString) }
    }

    public func version(topicId: UUID, number: Int) async throws -> TopicVersion? {
        try await reader.read { db in try StoreView.version(db, topicId: topicId.wireString, number: number) }
    }
}

public struct GRDBEntryRepository: EntryRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func entries(topicId: UUID, limit: Int?) async throws -> [ViewEntry] {
        try await reader.read { db in try StoreView.entries(db, topicId: topicId.wireString, limit: limit) }
    }

    public func entry(id: UUID) async throws -> ViewEntry? {
        try await reader.read { db in try StoreView.entry(db, id: id.wireString) }
    }

    /// The entry before outbox item `seq` (`StoreView.entry(_:id:before:)`).
    public func entry(id: UUID, before seq: Int64) async throws -> Entry? {
        try await reader.read { db in try StoreView.entry(db, id: id.wireString, before: seq) }
    }

    public func latestEntry(topicId: UUID) async throws -> ViewEntry? {
        try await reader.read { db in try StoreView.latestEntry(db, topicId: topicId.wireString) }
    }
}

/// Queries over `outbox_item`. Production writes go through `Outbox`; `appendRawForTesting` is
/// a test seam.
public struct GRDBOutboxRepository: OutboxRepository {
    private let writer: any DatabaseWriter
    private let wallClock: any WallClock

    public init(writer: any DatabaseWriter, wallClock: any WallClock = SystemWallClock()) {
        self.writer = writer
        self.wallClock = wallClock
    }

    /// Appends one item as is, for tests that need a row in a given shape: **no** coalescing
    /// (outbox.md §8), **no** visibility check (C0), no undo semantics; only the §7.3 base revision
    /// and the retired-file check. Never use it for a real enqueue: that is `Outbox.enqueue`.
    @_spi(Testing)
    public func appendRawForTesting(_ item: NewOutboxItem) async throws -> OutboxItem {
        let now = wallClock.now()
        return try await writer.write { db in
            if try StoreFence.isRetired(db) { throw StoreError.retired }
            return try OutboxStorage.append(db, item, now: now)
        }
    }

    public func items() async throws -> [OutboxItem] {
        try await writer.read { db in try OutboxStorage.items(db) }
    }

    public func items(topicId: String) async throws -> [OutboxItem] {
        try await writer.read { db in try OutboxStorage.items(db, topicId: topicId) }
    }

    public func item(id: String) async throws -> OutboxItem? {
        try await writer.read { db in try OutboxStorage.item(db, id: id) }
    }

    public func summary() async throws -> (count: Int, maxSeq: Int64) {
        try await writer.read { db in try OutboxStorage.summary(db) }
    }
}
