import Foundation

/// One `/changes` page (sync-protocol.md §1.2).
public struct ChangePage: Sendable, Hashable {
    public var serverId: String
    public var epoch: String
    /// The server's highest seq when the page was built.
    public var head: Int
    /// The highest seq this page covers; equal to `after` when the page is empty.
    public var next: Int
    public var hasMore: Bool
    public var serverTime: Date
    public var items: [ChangeItem]
    public var deleted: [Deletion]

    public init(
        serverId: String, epoch: String, head: Int, next: Int, hasMore: Bool, serverTime: Date,
        items: [ChangeItem], deleted: [Deletion]
    ) {
        self.serverId = serverId
        self.epoch = epoch
        self.head = head
        self.next = next
        self.hasMore = hasMore
        self.serverTime = serverTime
        self.items = items
        self.deleted = deleted
    }
}

/// An upserted entity on a feed page, with the change_log `seq` that put it there. The entity is
/// its latest state in the page's snapshot (F1).
public enum ChangeItem: Sendable, Hashable {
    case topic(seq: Int, topic: Topic)
    case version(seq: Int, id: UUID, topicId: UUID, version: TopicVersion)
    case entry(seq: Int, entry: Entry)
    /// A run that is open or finishing in the page's snapshot (timers.md §7.1).
    case run(seq: Int, run: Run)

    public var seq: Int {
        switch self {
        case .topic(let seq, _), .version(let seq, _, _, _), .entry(let seq, _), .run(let seq, _): seq
        }
    }
}

/// A tombstone on a feed page. `topicId` is never null; for a topic it equals `id`.
public struct Deletion: Sendable, Hashable {
    public var kind: EntityKind
    public var seq: Int
    public var id: UUID
    public var topicId: UUID
    public var deletedAt: Date

    public init(kind: EntityKind, seq: Int, id: UUID, topicId: UUID, deletedAt: Date) {
        self.kind = kind
        self.seq = seq
        self.id = id
        self.topicId = topicId
        self.deletedAt = deletedAt
    }

    public enum EntityKind: String, Sendable, Hashable, CaseIterable, Codable {
        case entry
        case topic
        case version
        /// A run that closed (stopped or discarded) or was deleted: "no longer open" (timers.md
        /// §2.4). A topic's deletion also lists its runs' aliases under this kind.
        case run
    }
}
