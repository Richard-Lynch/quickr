import Foundation
import GRDB
import QuickrCore

/// Row-level access to `outbox_item` (outbox.md §2). CRUD and queries only: the state machine,
/// coalescing, claims and classification are OUTBOX's, built on these. Everything runs inside a
/// transaction the caller holds.
public enum OutboxStorage {
    /// Inserts `item` at the end of the queue: `held` when it carries a hold, `pending` otherwise.
    /// `base_revision` follows the enqueue rows of §7.3: nil (inherit) when the entity already has
    /// an unresolved item, else the caller's base, else the current server-layer revision.
    /// No coalescing; OUTBOX applies §8 before or instead of this.
    public static func append(_ db: Database, _ item: NewOutboxItem, now: Date) throws -> OutboxItem {
        let payload = item.payload
        let kind = payload.kind
        let entityId = payload.entityId(itemId: item.id)
        let hasPredecessor = try !items(db, entityKind: kind.entityKind, entityId: entityId).isEmpty
        let baseRevision: Int? =
            hasPredecessor
            ? nil : try item.baseRevision ?? ServerLayer.revision(db, entityKind: kind.entityKind, id: entityId)
        try db.execute(
            sql: """
                INSERT INTO outbox_item
                  (id, kind, entity_kind, entity_id, topic_id, payload_json, base_revision, state, hold_boot_id,
                   hold_ct, cancels_create, origin, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.id.wireString, kind.rawValue, kind.entityKind.rawValue, entityId, payload.topicId,
                try payload.encoded(), baseRevision, (item.hold == nil ? OutboxState.pending : .held).rawValue,
                item.hold?.bootId, item.hold?.ct, item.cancelsCreate, item.origin.rawValue, now.unixSeconds,
                now.unixSeconds,
            ])
        guard let stored = try self.item(db, id: item.id.wireString) else {
            throw StoreError.corruptRow("outbox item \(item.id) vanished after insert")
        }
        return stored
    }

    /// Every unresolved item, by `seq`.
    public static func items(_ db: Database) throws -> [OutboxItem] {
        try fetch(db, "SELECT * FROM outbox_item ORDER BY seq")
    }

    public static func items(_ db: Database, topicId: String) throws -> [OutboxItem] {
        try fetch(db, "SELECT * FROM outbox_item WHERE topic_id = ? ORDER BY seq", [topicId])
    }

    public static func items(_ db: Database, entityKind: OutboxEntityKind, entityId: String) throws -> [OutboxItem] {
        try fetch(
            db, "SELECT * FROM outbox_item WHERE entity_kind = ? AND entity_id = ? ORDER BY seq",
            [entityKind.rawValue, entityId])
    }

    /// Items for any of `entityIds` of one kind, by `seq`.
    public static func items(_ db: Database, entityKind: OutboxEntityKind, entityIds: [String]) throws -> [OutboxItem] {
        guard !entityIds.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: entityIds.count).joined(separator: ",")
        return try fetch(
            db, "SELECT * FROM outbox_item WHERE entity_kind = ? AND entity_id IN (\(marks)) ORDER BY seq",
            StatementArguments([entityKind.rawValue] + entityIds))
    }

    public static func item(_ db: Database, id: String) throws -> OutboxItem? {
        try fetch(db, "SELECT * FROM outbox_item WHERE id = ?", [id]).first
    }

    /// Removes an item. Returns whether it existed.
    @discardableResult
    public static func delete(_ db: Database, id: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM outbox_item WHERE id = ?", arguments: [id])
        return db.changesCount > 0
    }

    /// `(count, max seq)`, the reset warning's inputs (sync-protocol.md §12.1); `(0, 0)` when empty.
    public static func summary(_ db: Database) throws -> (count: Int, maxSeq: Int64) {
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(MAX(seq), 0) AS m FROM outbox_item")
        return (row?["n"] ?? 0, row?["m"] ?? 0)
    }

    /// Revision chaining (outbox.md §7.3): after an item of the entity is removed, the next
    /// unresolved item with `base_revision IS NULL` takes the entity's current server-layer
    /// revision. Run in the transaction that removed the item.
    public static func chainRevision(_ db: Database, entityKind: OutboxEntityKind, entityId: String) throws {
        guard let next = try items(db, entityKind: entityKind, entityId: entityId).first, next.baseRevision == nil,
            let revision = try ServerLayer.revision(db, entityKind: entityKind, id: entityId)
        else { return }
        try db.execute(
            sql: "UPDATE outbox_item SET base_revision = ? WHERE id = ?", arguments: [revision, next.id])
    }

    private static func fetch(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws
        -> [OutboxItem]
    {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(OutboxItem.init(row:))
    }
}

extension OutboxPayload {
    /// The entity the item changes; for `entry.create` the item id is the entry id.
    func entityId(itemId: UUID) -> String {
        switch self {
        case .entryCreate: itemId.wireString
        case .entryUpdate(let entryId, _, _), .entryDelete(let entryId, _): entryId
        case .topicArchive(let topicId), .topicUnarchive(let topicId): topicId
        }
    }

    var topicId: String {
        switch self {
        case .entryCreate(let topic, _): topic.id
        case .entryUpdate(_, let topicId, _), .entryDelete(_, let topicId): topicId
        case .topicArchive(let topicId), .topicUnarchive(let topicId): topicId
        }
    }
}

extension OutboxItem {
    init(row: Row) throws {
        let id: String = row["id"]
        let kind: String = row["kind"]
        let state: String = row["state"]
        let origin: String = row["origin"]
        guard let kind = OutboxKind(rawValue: kind), let state = OutboxState(rawValue: state),
            let origin = OutboxOrigin(rawValue: origin)
        else { throw StoreError.corruptRow("outbox item \(id)") }
        let reason: String? = row["failure_reason"]
        self.init(
            seq: row["seq"], id: id, kind: kind, entityId: row["entity_id"], topicId: row["topic_id"],
            payloadJSON: row["payload_json"], baseRevision: row["base_revision"], state: state,
            maybeDelivered: row["maybe_delivered"], attempts: row["attempts"],
            due: LeaseInstant(bootId: row["due_boot_id"], ct: row["due_ct"]),
            hold: LeaseInstant(bootId: row["hold_boot_id"], ct: row["hold_ct"]), claimToken: row["claim_token"],
            claimOwner: row["claim_owner"], claimLayerGen: row["claim_layer_gen"], claimEpoch: row["claim_epoch"],
            preClaimJSON: row["pre_claim_json"], failureReason: reason.flatMap(OutboxFailureReason.init(rawValue:)),
            lastErrorJSON: row["last_error_json"], rebaseCount: row["rebase_count"],
            cancelsCreate: row["cancels_create"], origin: origin, createdAt: Date(unixSeconds: row["created_at"]),
            updatedAt: Date(unixSeconds: row["updated_at"]), rowVersion: row["row_version"])
    }

    /// The decoded payload.
    public func payload() throws -> OutboxPayload { try OutboxPayload.decode(kind: kind, json: payloadJSON) }
}

extension LeaseInstant {
    /// A `(boot_id, ct)` column pair; nil when either is null.
    init?(bootId: String?, ct: Int64?) {
        guard let bootId, let ct else { return nil }
        self.init(bootId: bootId, ct: ct)
    }
}
