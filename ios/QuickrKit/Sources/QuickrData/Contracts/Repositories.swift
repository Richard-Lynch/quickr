import Foundation
import QuickrCore

// Repository contracts. Implementations (STORE) wrap a GRDB `DatabaseReader`/`DatabaseWriter`,
// which are `Sendable`, so a repository is a `Sendable` struct that any actor or process can
// hold. Every method is `async` and runs its database access on GRDB's queue, never on the
// caller's executor; no method keeps a transaction open across an `await`
// (sync-protocol.md §5.2 rule 3). Reads return the **view** (server layer + outbox overlay,
// derived fields recomputed) unless the name says otherwise.
//
// These are the read and enqueue surfaces other WPs code against. The coordinator, flusher and
// ack paths are fenced, multi-table transactions that STORE, SYNC and OUTBOX define next to their
// implementations.

public protocol TopicRepository: Sendable {
    /// Every view topic, archived included, in display order, each with its overlay state.
    func topics() async throws -> [ViewTopic]
    func topic(id: UUID) async throws -> ViewTopic?
    func topic(slug: String) async throws -> ViewTopic?
}

public protocol TopicVersionRepository: Sendable {
    /// Every version of a topic, oldest first.
    func versions(topicId: UUID) async throws -> [TopicVersion]
    func version(topicId: UUID, number: Int) async throws -> TopicVersion?
}

public protocol EntryRepository: Sendable {
    /// A topic's view entries, newest `captured_at` first.
    func entries(topicId: UUID, limit: Int?) async throws -> [ViewEntry]
    func entry(id: UUID) async throws -> ViewEntry?
    /// The latest counted entry of a topic (repeat-last, quick-log `last_value`).
    func latestEntry(topicId: UUID) async throws -> ViewEntry?
}

/// Reads of the outbox. Writes go through `Outbox` (OUTBOX), which applies the coalescing rules
/// (outbox.md §8), the C0 visibility check and the K1–K5 undo semantics.
public protocol OutboxRepository: Sendable {
    /// Every unresolved item, by `seq`.
    func items() async throws -> [OutboxItem]
    func items(topicId: String) async throws -> [OutboxItem]
    func item(id: String) async throws -> OutboxItem?
    /// `(count, max seq)`: the reset warning's inputs (sync-protocol.md §12.1).
    func summary() async throws -> (count: Int, maxSeq: Int64)
}

public protocol SyncStateRepository: Sendable {
    /// The store's `sync_state` row; nil before the store has been bootstrapped.
    func syncState() async throws -> SyncState?
}

public protocol RegistryRepository: Sendable {
    func servers() async throws -> [RegisteredServer]
    func server(id: String) async throws -> RegisteredServer?
    func activeServerId() async throws -> String?
    /// Every row of the table (notifications.md §5.1).
    func notificationCategories() async throws -> [NotificationCategoryRecord]
}
