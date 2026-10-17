import Foundation
import GRDB
import QuickrCore

// The C1 repository protocols over one store file. Reads return the view (`StoreView`); each
// method is one read or one `IMMEDIATE` write transaction on GRDB's queue.

public struct GRDBTopicRepository: TopicRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func topics() async throws -> [Topic] { try await viewTopics().map(\.topic) }

    public func topic(id: UUID) async throws -> Topic? { try await viewTopic(id: id)?.topic }

    public func topic(slug: String) async throws -> Topic? {
        try await reader.read { db in try StoreView.topic(db, slug: slug)?.topic }
    }

    /// The topics with their sync flags (failed archive items flag the topic, §3.2).
    public func viewTopics() async throws -> [ViewTopic] {
        try await reader.read { db in try StoreView.topics(db) }
    }

    public func viewTopic(id: UUID) async throws -> ViewTopic? {
        try await reader.read { db in try StoreView.topic(db, id: id.wireString) }
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

    public func latestEntry(topicId: UUID) async throws -> ViewEntry? {
        try await reader.read { db in try StoreView.latestEntry(db, topicId: topicId.wireString) }
    }
}

/// CRUD and queries over `outbox_item`. `enqueue` is a plain append (with the §7.3 base revision)
/// that refuses a retired file; OUTBOX wraps it with coalescing (§8) and validation.
public struct GRDBOutboxRepository: OutboxRepository {
    private let writer: any DatabaseWriter
    private let wallClock: any WallClock

    public init(writer: any DatabaseWriter, wallClock: any WallClock = SystemWallClock()) {
        self.writer = writer
        self.wallClock = wallClock
    }

    public func enqueue(_ item: NewOutboxItem) async throws -> OutboxItem {
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
