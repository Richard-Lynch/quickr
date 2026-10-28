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

    /// An item or deletion of a kind this build doesn't know is skipped, not a page failure
    /// (sync-protocol.md §2.2, client-versions.md §4.4): a newer server's optional kind doesn't
    /// force an update. A known kind that doesn't decode still fails the page.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([KnownKind<FeedItemDTO>].self, forKey: .items).compactMap(\.value)
        deleted = try container.decode([KnownKind<FeedDeletionDTO>].self, forKey: .deleted).compactMap(\.value)
        next = try container.decode(Int.self, forKey: .next)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        head = try container.decode(Int.self, forKey: .head)
        epoch = try container.decode(String.self, forKey: .epoch)
        serverId = try container.decode(String.self, forKey: .serverId)
        serverTime = try container.decode(Date.self, forKey: .serverTime)
    }

    public func toDomain() throws -> ChangePage {
        ChangePage(
            serverId: serverId, epoch: epoch, head: head, next: next, hasMore: hasMore, serverTime: serverTime,
            items: try items.map { try $0.toDomain() }, deleted: try deleted.map { try $0.toDomain() })
    }
}

/// A feed row tagged by `kind`, of the kinds in `knownKinds`.
protocol FeedRowDTO: Decodable {
    static var knownKinds: Set<String> { get }
}

/// One feed row: decoded when its `kind` is known, nil (skipped) when it isn't.
private struct KnownKind<Row: FeedRowDTO>: Decodable {
    var value: Row?

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .kind)
        value = Row.knownKinds.contains(kind) ? try Row(from: decoder) : nil
    }
}

/// A feed item, tagged by `kind`. An unknown kind fails decoding on its own; on a page it is
/// skipped (`ChangePageDTO`, sync-protocol.md §2.2).
public enum FeedItemDTO: Codable, Sendable, Hashable, FeedRowDTO {
    static let knownKinds: Set<String> = ["topic", "version", "entry", "run"]

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

    public func toDomain() throws -> ChangeItem {
        switch self {
        case .topic(let seq, let topic):
            .topic(seq: seq, topic: try topic.toDomain())
        case .version(let seq, let id, let topicId, let version):
            .version(
                seq: seq, id: try .wire(id, "version.id"), topicId: try .wire(topicId, "version.topic_id"),
                version: try version.toDomain())
        case .entry(let seq, let entry):
            .entry(seq: seq, entry: try entry.toDomain())
        case .run(let seq, let run):
            .run(seq: seq, run: try run.toDomain())
        }
    }
}

/// `DeletionKind`.
public enum FeedDeletionKindDTO: String, Codable, Sendable, Hashable, CaseIterable {
    case entry, topic, version, run
}

/// `FeedDeletion`: a tombstone on a feed page.
public struct FeedDeletionDTO: Codable, Sendable, Hashable, FeedRowDTO {
    static let knownKinds = Set(FeedDeletionKindDTO.allCases.map(\.rawValue))

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

    public func toDomain() throws -> Deletion {
        let kind: Deletion.EntityKind
        switch self.kind {
        case .entry: kind = .entry
        case .topic: kind = .topic
        case .version: kind = .version
        case .run: kind = .run
        }
        return Deletion(
            kind: kind, seq: seq, id: try .wire(id, "deletion.id"), topicId: try .wire(topicId, "deletion.topic_id"),
            deletedAt: deletedAt)
    }
}
