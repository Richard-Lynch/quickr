import Foundation
import QuickrCore

/// `ChangesPage` (listChanges, `GET /changes`; sync-protocol.md §1.2).
public struct ChangePageDTO: Codable, Sendable, Hashable, WireResponse {
    public var items: [FeedItemDTO]
    public var deleted: [FeedDeletionDTO]
    public var next: Int
    public var hasMore: Bool
    public var head: Int
    public var epoch: String
    public var serverId: String
    public var serverTime: Date

    enum CodingKeys: String, CodingKey {
        case items, deleted, next, head, epoch
        case hasMore = "has_more"
        case serverId = "server_id"
        case serverTime = "server_time"
    }

    /// Runs decode (so every row is checked) but are dropped here until the store keeps them
    /// (I-SYNC, timers.md §7.2).
    public func toDomain() throws -> ChangePage {
        ChangePage(
            serverId: serverId, epoch: epoch, head: head, next: next, hasMore: hasMore, serverTime: serverTime,
            items: try items.compactMap { try $0.toDomain() }, deleted: try deleted.compactMap { try $0.toDomain() })
    }
}

/// A feed item, tagged by `kind`. An unknown kind fails decoding, which fails the page
/// (sync-protocol.md §2.2, "every row decodes").
public enum FeedItemDTO: Codable, Sendable, Hashable {
    case topic(seq: Int, topic: TopicDetailDTO)
    case version(seq: Int, id: String, topicId: String, version: TopicVersionDTO)
    case entry(seq: Int, entry: EntryDTO)
    /// An open or finishing run (timers.md §7.1).
    case run(seq: Int, run: RunDTO)

    enum CodingKeys: String, CodingKey {
        case kind, seq, topic, id, version, entry, run
        case topicId = "topic_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seq = try container.decode(Int.self, forKey: .seq)
        switch try container.decode(String.self, forKey: .kind) {
        case "topic":
            self = .topic(seq: seq, topic: try container.decode(TopicDetailDTO.self, forKey: .topic))
        case "version":
            self = .version(
                seq: seq, id: try container.decode(String.self, forKey: .id),
                topicId: try container.decode(String.self, forKey: .topicId),
                version: try container.decode(TopicVersionDTO.self, forKey: .version))
        case "entry":
            self = .entry(seq: seq, entry: try container.decode(EntryDTO.self, forKey: .entry))
        case "run":
            self = .run(seq: seq, run: try container.decode(RunDTO.self, forKey: .run))
        case let kind:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown feed item kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .topic(let seq, let topic):
            try container.encode("topic", forKey: .kind)
            try container.encode(seq, forKey: .seq)
            try container.encode(topic, forKey: .topic)
        case .version(let seq, let id, let topicId, let version):
            try container.encode("version", forKey: .kind)
            try container.encode(seq, forKey: .seq)
            try container.encode(id, forKey: .id)
            try container.encode(topicId, forKey: .topicId)
            try container.encode(version, forKey: .version)
        case .entry(let seq, let entry):
            try container.encode("entry", forKey: .kind)
            try container.encode(seq, forKey: .seq)
            try container.encode(entry, forKey: .entry)
        case .run(let seq, let run):
            try container.encode("run", forKey: .kind)
            try container.encode(seq, forKey: .seq)
            try container.encode(run, forKey: .run)
        }
    }

    /// The domain item, or nil for a run, which the store doesn't keep yet (I-SYNC).
    public func toDomain() throws -> ChangeItem? {
        switch self {
        case .topic(let seq, let topic):
            .topic(seq: seq, topic: try topic.toDomain())
        case .version(let seq, let id, let topicId, let version):
            .version(
                seq: seq, id: try .wire(id, "version.id"), topicId: try .wire(topicId, "version.topic_id"),
                version: try version.toDomain())
        case .entry(let seq, let entry):
            .entry(seq: seq, entry: try entry.toDomain())
        case .run:
            nil
        }
    }
}

/// `DeletionKind`: the domain's kinds, and `run`, which the store doesn't keep yet (I-SYNC).
public enum FeedDeletionKindDTO: String, Codable, Sendable, Hashable {
    case entry, topic, version, run
}

/// `FeedDeletion`: a tombstone on a feed page.
public struct FeedDeletionDTO: Codable, Sendable, Hashable {
    public var kind: FeedDeletionKindDTO
    public var seq: Int
    public var id: String
    public var topicId: String
    public var deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case kind, seq, id
        case topicId = "topic_id"
        case deletedAt = "deleted_at"
    }

    /// The domain deletion, or nil for a run's (I-SYNC).
    public func toDomain() throws -> Deletion? {
        let kind: Deletion.EntityKind
        switch self.kind {
        case .entry: kind = .entry
        case .topic: kind = .topic
        case .version: kind = .version
        case .run: return nil
        }
        return Deletion(
            kind: kind, seq: seq, id: try .wire(id, "deletion.id"), topicId: try .wire(topicId, "deletion.topic_id"),
            deletedAt: deletedAt)
    }
}
