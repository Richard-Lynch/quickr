import Foundation
import GRDB
import QuickrCore

/// What sync does to outbox items when the server layer changes under them (sync-protocol.md
/// §4.3 step 3, §7 step 3). Runs inside the page or swap transaction that caused it.
enum OutboxResolution {
    static let deletedElsewhere = OutboxErrorInfo(message: "Deleted on another device")

    /// The §4.3 dependent-item table for the items of one deleted entity, or of a deleted topic.
    /// In-flight items are left to their sender's outcome.
    ///
    /// | Item                                                          | Result                    |
    /// | ------------------------------------------------------------- | ------------------------- |
    /// | `entry.delete` (any state, `held` included), `topic.archive`  | retired silently          |
    /// | `entry.create`/`entry.update` with a later `entry.delete`     | retired silently          |
    /// | `entry.create`, `entry.update`, `topic.unarchive` otherwise   | failed, deleted_elsewhere |
    static func resolveDependents(_ db: Database, items: [OutboxItem], wallNow: Date) throws {
        for item in items where item.state != .inFlight {
            switch item.kind {
            case .entryDelete, .topicArchive:
                try OutboxStorage.delete(db, id: item.id)
            case .entryCreate, .entryUpdate:
                let deletedLater = items.contains {
                    $0.kind == .entryDelete && $0.entityId == item.entityId && $0.seq > item.seq
                }
                if deletedLater {
                    try OutboxStorage.delete(db, id: item.id)
                } else {
                    try fail(db, item, wallNow: wallNow)
                }
            case .topicUnarchive:
                try fail(db, item, wallNow: wallNow)
            }
        }
    }

    /// The swap's pass (§7 step 3.2): every outbox entity that is tombstoned in the new layer,
    /// directly or through its topic, resolves by the same table.
    static func resolveTombstonedDependents(_ db: Database, wallNow: Date) throws {
        let topics = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT topic_id FROM outbox_item
                WHERE topic_id IN (SELECT id FROM tombstone WHERE kind = 'topic')
                """)
        for topicId in topics {
            try resolveDependents(db, items: try OutboxStorage.items(db, topicId: topicId), wallNow: wallNow)
        }
        let entries = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT entity_id FROM outbox_item
                WHERE entity_kind = 'entry' AND entity_id IN (SELECT id FROM tombstone WHERE kind = 'entry')
                """)
        for entryId in entries {
            let items = try OutboxStorage.items(db, entityKind: .entry, entityId: entryId)
            // Already failed by the topic pass: failed items stay failed (§7 step 4).
            guard items.contains(where: { $0.failureReason != .deletedElsewhere }) else { continue }
            try resolveDependents(db, items: items, wallNow: wallNow)
        }
    }

    /// outbox.md S8 at a swap: a create that just left `in_flight` without a 2xx and has a later
    /// `cancels_create` delete is removed, with the updates queued between the two, so the
    /// delete is sent on its own.
    static func removeCancelledCreates(_ db: Database, createIds: [String]) throws {
        for id in createIds {
            guard let create = try OutboxStorage.item(db, id: id) else { continue }
            let items = try OutboxStorage.items(db, entityKind: .entry, entityId: create.entityId)
            guard
                let cancel = items.first(where: { $0.kind == .entryDelete && $0.cancelsCreate && $0.seq > create.seq })
            else { continue }
            for item in items where item.seq >= create.seq && item.seq < cancel.seq && item.kind != .entryDelete {
                try OutboxStorage.delete(db, id: item.id)
            }
        }
    }

    private static func fail(_ db: Database, _ item: OutboxItem, wallNow: Date) throws {
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = 'failed', failure_reason = ?, last_error_json = ?, due_boot_id = NULL, due_ct = NULL,
                    updated_at = ?, row_version = row_version + 1
                WHERE id = ?
                """,
            arguments: [
                OutboxFailureReason.deletedElsewhere.rawValue, try StoreJSON.encode(deletedElsewhere),
                wallNow.unixSeconds, item.id,
            ])
    }
}
