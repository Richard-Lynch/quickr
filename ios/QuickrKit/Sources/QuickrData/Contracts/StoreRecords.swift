import Foundation
import QuickrCore

// Typed views of the store and registry rows (StoreSchema, RegistrySchema). Column names are in
// the schema; these types are what repositories return.

// MARK: - Sync state (sync-protocol.md §3.1)

/// The single `sync_state` row of a store.
public struct SyncState: Sendable, Hashable {
    public var serverId: String
    public var baseURL: String
    /// nil until the first page is applied.
    public var epoch: String?
    /// The highest seq fully applied; 0 before bootstrap.
    public var cursor: Int
    public var headSeen: Int
    /// Incremented by every rebuild swap (§7).
    public var layerGen: Int
    /// The target epoch while a rebuild is staging.
    public var rebuilding: String?
    public var epochSuspect: Bool
    /// A retired file is never written again (§12).
    public var retired: Bool
    public var identityMismatch: Bool
    public var lastPullAt: Date?
    /// `server_time − device_time`, smoothed (§10).
    public var skewMilliseconds: Double
    public var skewMeasuredAt: Date?
    public var bootstrapComplete: Bool

    public init(
        serverId: String, baseURL: String, epoch: String? = nil, cursor: Int = 0, headSeen: Int = 0, layerGen: Int = 1,
        rebuilding: String? = nil, epochSuspect: Bool = false, retired: Bool = false, identityMismatch: Bool = false,
        lastPullAt: Date? = nil, skewMilliseconds: Double = 0, skewMeasuredAt: Date? = nil,
        bootstrapComplete: Bool = false
    ) {
        self.serverId = serverId
        self.baseURL = baseURL
        self.epoch = epoch
        self.cursor = cursor
        self.headSeen = headSeen
        self.layerGen = layerGen
        self.rebuilding = rebuilding
        self.epochSuspect = epochSuspect
        self.retired = retired
        self.identityMismatch = identityMismatch
        self.lastPullAt = lastPullAt
        self.skewMilliseconds = skewMilliseconds
        self.skewMeasuredAt = skewMeasuredAt
        self.bootstrapComplete = bootstrapComplete
    }
}

/// The two lease rows of a store (sync-protocol.md §5.3). Lock order: `sync` → `flush`.
public enum LeaseName: String, Sendable, Hashable, CaseIterable {
    case sync
    case flush
}

public struct LeaseRecord: Sendable, Hashable {
    public var name: LeaseName
    /// `"<process kind>:<launch uuid>"`, nil when free.
    public var owner: String?
    /// Fencing token, new on every acquisition.
    public var token: String?
    /// `(boot_id, expires_ct)`.
    public var expires: LeaseInstant?

    public init(name: LeaseName, owner: String? = nil, token: String? = nil, expires: LeaseInstant? = nil) {
        self.name = name
        self.owner = owner
        self.token = token
        self.expires = expires
    }
}

// MARK: - View

/// How a view row relates to the server (sync-protocol.md §3.2).
public enum RecordSyncState: Sendable, Hashable {
    /// The row is exactly the server's.
    case synced
    /// An outbox item for it is active or held.
    case pending
    /// An outbox item for it failed; shown with its error.
    case failed(OutboxFailureReason)
}

/// An entry as the view shows it: the server row with the outbox applied.
public struct ViewEntry: Sendable, Hashable, Identifiable {
    public var entry: Entry
    public var syncState: RecordSyncState
    /// The error of the failed item behind `.failed`, for display and Fix.
    public var lastError: OutboxErrorInfo?
    /// The `seq` of its create when the server doesn't have the entry yet (pending or failed); nil
    /// for a server row, edited or not. The entries list pins these, in outbox order.
    public var createSeq: Int64?

    public init(entry: Entry, syncState: RecordSyncState, lastError: OutboxErrorInfo? = nil, createSeq: Int64? = nil) {
        self.entry = entry
        self.syncState = syncState
        self.lastError = lastError
        self.createSeq = createSeq
    }

    /// Only on this device so far: its create is queued or failed.
    public var isLocalOnly: Bool { createSeq != nil }

    public var id: UUID { entry.id }
}

/// A topic as the view shows it (sync-protocol.md §3.2), from one read so the topic and its
/// overlay state come from the same snapshot.
///
/// `topic` has active and held `topic.archive`/`topic.unarchive` items applied (`status`,
/// `archived_at`) and derived fields recomputed. A **failed** archive or unarchive is not
/// applied: `topic` keeps the server's status, and the failure shows in `syncState` and
/// `lastError`.
public struct ViewTopic: Sendable, Hashable, Identifiable {
    public var topic: Topic
    /// `.pending` while an archive or unarchive is queued; `.failed` when the latest one failed.
    public var syncState: RecordSyncState
    /// The kind of the queued or failed topic item, if any.
    public var pendingChange: OutboxKind?
    public var lastError: OutboxErrorInfo?

    public init(
        topic: Topic, syncState: RecordSyncState = .synced, pendingChange: OutboxKind? = nil,
        lastError: OutboxErrorInfo? = nil
    ) {
        self.topic = topic
        self.syncState = syncState
        self.pendingChange = pendingChange
        self.lastError = lastError
    }

    public var id: UUID { topic.id }
}

/// `outbox_item.last_error_json`: the PWA `OutboxError` shape `{message, status, body?}`.
public struct OutboxErrorInfo: Codable, Sendable, Hashable {
    public var message: String
    /// The HTTP status, nil when no response arrived.
    public var status: Int?
    public var body: JSONValue?

    public init(message: String, status: Int? = nil, body: JSONValue? = nil) {
        self.message = message
        self.status = status
        self.body = body
    }
}

// MARK: - Outbox (outbox.md §1–§3)

public enum OutboxKind: String, Sendable, Hashable, CaseIterable, Codable {
    case entryCreate = "entry.create"
    case entryUpdate = "entry.update"
    case entryDelete = "entry.delete"
    case topicArchive = "topic.archive"
    case topicUnarchive = "topic.unarchive"

    public var entityKind: OutboxEntityKind {
        switch self {
        case .entryCreate, .entryUpdate, .entryDelete: .entry
        case .topicArchive, .topicUnarchive: .topic
        }
    }
}

public enum OutboxEntityKind: String, Sendable, Hashable, CaseIterable, Codable {
    case entry
    case topic
}

public enum OutboxState: String, Sendable, Hashable, CaseIterable, Codable {
    /// `entry.delete` inside its undo window; never sent.
    case held
    case pending
    case inFlight = "in_flight"
    /// Like pending, but a request may have reached the server (`maybe_delivered = 1`).
    case uncertain
    /// Terminal until the user retries, fixes or discards it.
    case failed

    /// pending, in_flight or uncertain.
    public var isActive: Bool { self == .pending || self == .inFlight || self == .uncertain }
}

public enum OutboxFailureReason: String, Sendable, Hashable, CaseIterable, Codable {
    case rejected
    case deletedElsewhere = "deleted_elsewhere"
    case conflict
    case topicArchived = "topic_archived"
    case topicMissing = "topic_missing"
    case futureTime = "future_time"
}

/// The process that enqueued an item; decides `source` for creates (outbox.md §4).
public enum OutboxOrigin: String, Sendable, Hashable, CaseIterable, Codable {
    case app
    case widget
    case notification
    case siri

    public var source: String {
        switch self {
        case .app: "ios"
        case .widget: "ios.widget"
        case .notification: "ios.notification"
        case .siri: "ios.siri"
        }
    }
}

/// The topic an `entry.create` belongs to, kept so the entry can show before the topic arrives.
public struct TopicRef: Codable, Sendable, Hashable {
    public var id: String
    public var slug: String
    public var name: String

    public init(id: UUID, slug: String, name: String) {
        self.id = id.wireString
        self.slug = slug
        self.name = name
    }
}

/// `outbox_item.payload_json`, by kind (outbox.md §1).
public enum OutboxPayload: Sendable, Hashable {
    /// `{topic: {id, slug, name}, body: EntryCreate without id}`; `body.version` and
    /// `body.captured_at` are always set. The item id is the entry id.
    case entryCreate(topic: TopicRef, body: EntryCreateDTO)
    /// `{entry_id, topic_id, patch}`, holding only the changed keys.
    case entryUpdate(entryId: String, topicId: String, patch: EntryUpdateDTO)
    /// `{entry_id, topic_id}`
    case entryDelete(entryId: String, topicId: String)
    /// `{topic_id}`
    case topicArchive(topicId: String)
    /// `{topic_id}`
    case topicUnarchive(topicId: String)

    public var kind: OutboxKind {
        switch self {
        case .entryCreate: .entryCreate
        case .entryUpdate: .entryUpdate
        case .entryDelete: .entryDelete
        case .topicArchive: .topicArchive
        case .topicUnarchive: .topicUnarchive
        }
    }

    private enum Keys: String, CodingKey {
        case topic, body, patch
        case entryId = "entry_id"
        case topicId = "topic_id"
    }

    /// The JSON stored in `payload_json`.
    public func encoded() throws -> String {
        let encoder = WireCoding.encoder()
        let data: Data
        switch self {
        case .entryCreate(let topic, let body):
            data = try encoder.encode(CreateShape(topic: topic, body: body))
        case .entryUpdate(let entryId, let topicId, let patch):
            data = try encoder.encode(UpdateShape(entryId: entryId, topicId: topicId, patch: patch))
        case .entryDelete(let entryId, let topicId):
            data = try encoder.encode(DeleteShape(entryId: entryId, topicId: topicId))
        case .topicArchive(let topicId), .topicUnarchive(let topicId):
            data = try encoder.encode(TopicShape(topicId: topicId))
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(kind: OutboxKind, json: String) throws -> OutboxPayload {
        let decoder = WireCoding.decoder()
        let data = Data(json.utf8)
        switch kind {
        case .entryCreate:
            let shape = try decoder.decode(CreateShape.self, from: data)
            return .entryCreate(topic: shape.topic, body: shape.body)
        case .entryUpdate:
            let shape = try decoder.decode(UpdateShape.self, from: data)
            return .entryUpdate(entryId: shape.entryId, topicId: shape.topicId, patch: shape.patch)
        case .entryDelete:
            let shape = try decoder.decode(DeleteShape.self, from: data)
            return .entryDelete(entryId: shape.entryId, topicId: shape.topicId)
        case .topicArchive:
            return .topicArchive(topicId: try decoder.decode(TopicShape.self, from: data).topicId)
        case .topicUnarchive:
            return .topicUnarchive(topicId: try decoder.decode(TopicShape.self, from: data).topicId)
        }
    }

    private struct CreateShape: Codable {
        var topic: TopicRef
        var body: EntryCreateDTO
    }

    private struct UpdateShape: Codable {
        var entryId: String
        var topicId: String
        var patch: EntryUpdateDTO

        enum CodingKeys: String, CodingKey {
            case patch
            case entryId = "entry_id"
            case topicId = "topic_id"
        }
    }

    private struct DeleteShape: Codable {
        var entryId: String
        var topicId: String

        enum CodingKeys: String, CodingKey {
            case entryId = "entry_id"
            case topicId = "topic_id"
        }
    }

    private struct TopicShape: Codable {
        var topicId: String

        enum CodingKeys: String, CodingKey { case topicId = "topic_id" }
    }
}

/// One `outbox_item` row.
public struct OutboxItem: Sendable, Hashable, Identifiable {
    /// Local total order of user intent across processes.
    public var seq: Int64
    /// The entry id for `entry.create`; a fresh UUID otherwise.
    public var id: String
    public var kind: OutboxKind
    public var entityKind: OutboxEntityKind
    public var entityId: String
    public var topicId: String
    public var payloadJSON: String
    /// nil: inherit from the predecessor (outbox.md §7.3).
    public var baseRevision: Int?
    public var state: OutboxState
    /// Sticky once set.
    public var maybeDelivered: Bool
    public var attempts: Int
    /// Backoff deadline in lease time; nil means due now.
    public var due: LeaseInstant?
    /// Undo-hold deadline in lease time (state `held`).
    public var hold: LeaseInstant?
    public var claimToken: String?
    public var claimOwner: String?
    public var claimLayerGen: Int?
    public var claimEpoch: String?
    public var preClaimJSON: String?
    public var failureReason: OutboxFailureReason?
    /// `{message, status, body?}`, the PWA `OutboxError` shape.
    public var lastErrorJSON: String?
    public var rebaseCount: Int
    /// An `entry.delete` enqueued to cancel an in-flight create (outbox.md §9.1).
    public var cancelsCreate: Bool
    public var origin: OutboxOrigin
    /// Wall clock; for display and `archived_at` only.
    public var createdAt: Date
    public var updatedAt: Date
    /// CAS for user edits.
    public var rowVersion: Int

    public init(
        seq: Int64, id: String, kind: OutboxKind, entityId: String, topicId: String, payloadJSON: String,
        baseRevision: Int? = nil, state: OutboxState, maybeDelivered: Bool = false, attempts: Int = 0,
        due: LeaseInstant? = nil, hold: LeaseInstant? = nil, claimToken: String? = nil, claimOwner: String? = nil,
        claimLayerGen: Int? = nil, claimEpoch: String? = nil, preClaimJSON: String? = nil,
        failureReason: OutboxFailureReason? = nil, lastErrorJSON: String? = nil, rebaseCount: Int = 0,
        cancelsCreate: Bool = false, origin: OutboxOrigin, createdAt: Date, updatedAt: Date, rowVersion: Int = 0
    ) {
        self.seq = seq
        self.id = id
        self.kind = kind
        self.entityKind = kind.entityKind
        self.entityId = entityId
        self.topicId = topicId
        self.payloadJSON = payloadJSON
        self.baseRevision = baseRevision
        self.state = state
        self.maybeDelivered = maybeDelivered
        self.attempts = attempts
        self.due = due
        self.hold = hold
        self.claimToken = claimToken
        self.claimOwner = claimOwner
        self.claimLayerGen = claimLayerGen
        self.claimEpoch = claimEpoch
        self.preClaimJSON = preClaimJSON
        self.failureReason = failureReason
        self.lastErrorJSON = lastErrorJSON
        self.rebaseCount = rebaseCount
        self.cancelsCreate = cancelsCreate
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rowVersion = rowVersion
    }
}

/// What a caller hands the outbox to enqueue; the outbox assigns `seq` and the bookkeeping.
public struct NewOutboxItem: Sendable, Hashable {
    /// For `entry.create`, the new entry's id.
    public var id: UUID
    public var payload: OutboxPayload
    public var baseRevision: Int?
    public var origin: OutboxOrigin
    /// Set for `entry.delete` with an undo window.
    public var hold: LeaseInstant?
    public var cancelsCreate: Bool

    public init(
        id: UUID = UUID(), payload: OutboxPayload, baseRevision: Int? = nil, origin: OutboxOrigin,
        hold: LeaseInstant? = nil, cancelsCreate: Bool = false
    ) {
        self.id = id
        self.payload = payload
        self.baseRevision = baseRevision
        self.origin = origin
        self.hold = hold
        self.cancelsCreate = cancelsCreate
    }
}

// MARK: - Registry (sync-protocol.md §8, §12; notifications.md §5, §9)

/// One `server` row of the registry.
public struct RegisteredServer: Sendable, Hashable, Identifiable {
    public var id: String
    public var baseURL: String
    public var displayName: String?
    /// Part of the store's file name: `stores/<server_id>.g<store_gen>.sqlite`.
    public var storeGen: Int
    public var createdAt: Date
    public var lastSyncAt: Date?
    /// Reset intent (§12.1 step 2); all nil when no reset is in progress.
    public var pendingGen: Int?
    public var pendingConfirmedCount: Int?
    public var pendingConfirmedMaxSeq: Int64?
    /// Unique per reset attempt: completion and abort are fenced on it.
    public var pendingToken: String?

    public init(
        id: String, baseURL: String, displayName: String? = nil, storeGen: Int = 1, createdAt: Date,
        lastSyncAt: Date? = nil, pendingGen: Int? = nil, pendingConfirmedCount: Int? = nil,
        pendingConfirmedMaxSeq: Int64? = nil, pendingToken: String? = nil
    ) {
        self.id = id
        self.baseURL = baseURL
        self.displayName = displayName
        self.storeGen = storeGen
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.pendingGen = pendingGen
        self.pendingConfirmedCount = pendingConfirmedCount
        self.pendingConfirmedMaxSeq = pendingConfirmedMaxSeq
        self.pendingToken = pendingToken
    }

    /// The store file name, relative to `<AppGroup>/Library/quickr/`.
    public var storeFileName: String { "stores/\(id).g\(storeGen).sqlite" }
}

/// One `notification_category` row: append-only, never pruned in v1.
public struct NotificationCategoryRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var serverId: String
    public var topicId: String
    /// The rendered action descriptor.
    public var actionsJSON: String
    public var createdAt: Date

    public init(id: String, serverId: String, topicId: String, actionsJSON: String, createdAt: Date) {
        self.id = id
        self.serverId = serverId
        self.topicId = topicId
        self.actionsJSON = actionsJSON
        self.createdAt = createdAt
    }
}
