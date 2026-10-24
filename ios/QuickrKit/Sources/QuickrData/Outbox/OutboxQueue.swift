import Foundation
import GRDB
import QuickrCore

/// What an enqueue left in the queue (outbox.md §8).
public enum OutboxEnqueueResult: Sendable, Hashable {
    /// Appended as a new item.
    case appended(OutboxItem)
    /// Merged into the adjacent, never-attempted item (K1, K2), which is returned.
    case merged(OutboxItem)
    /// Nothing remains for it: K3 cancelled an archive/unarchive pair, or a delete went with the
    /// unsent create it deleted (§8.3, §9.1).
    case cancelled
}

/// What `createEntryIfAbsent` did (notifications.md §7.1 step 5).
public enum OutboxCreateOnceResult: Sendable, Hashable {
    case created(OutboxItem)
    /// The id was already used; nothing was written.
    case duplicate(Duplicate)

    public enum Duplicate: Sendable, Hashable {
        /// An item for the entry is in the queue (pending, in flight, uncertain or failed).
        case queued
        /// The server layer has the entry.
        case onServer
        /// The entry was deleted: its tombstone reserves the id.
        case deleted
    }
}

/// The result of Undo on a log (outbox.md §9.1).
public enum OutboxUndoLogResult: Sendable, Hashable {
    /// The create was removed before the server could have seen it. No request will be made.
    case removed
    /// An `entry.delete` is queued: it reserves the id (or deletes the entry), so the entry can
    /// never appear. Undone either way.
    case deleteQueued
    /// Already deleted, tombstoned or unknown.
    case nothingToDo
}

/// The result of Undo on a delete (outbox.md §9.2).
public enum OutboxUndoDeleteResult: Sendable, Hashable {
    /// The held delete was removed; the entry shows exactly as before.
    case restored
    /// The hold was already released; Undo is no longer offered.
    case tooLate
    case nothingToDo
}

/// Why the outbox refused a call.
public enum OutboxError: Error, Sendable, Hashable, CustomStringConvertible {
    /// C0 (outbox.md §8.3): an update or delete for an entry with a tombstone or an unresolved
    /// delete.
    case entryDeleted
    /// The item is gone.
    case itemNotFound(String)
    /// The user action isn't allowed in the item's state (outbox.md §11).
    case notAllowed(String)
    /// Fix's CAS on `row_version` failed: the item changed; reload it.
    case itemChanged
    /// A hold was given to a kind other than `entry.delete`.
    case invalidHold

    public var description: String {
        switch self {
        case .entryDeleted: OutboxMessage.entryDeleted
        case .itemNotFound(let id): "outbox item \(id) not found"
        case .notAllowed(let reason): reason
        case .itemChanged: "the item changed; reload it"
        case .invalidHold: "only entry.delete can be held"
        }
    }
}

/// The queue operations that need no lease: enqueue with coalescing, undo, hold release, the sync
/// sheet's actions and the effects sync applies inside its page transaction. Each runs inside an
/// `IMMEDIATE` transaction the caller holds. Wall time is for `created_at`/`updated_at` only;
/// deadlines are lease time sampled inside that transaction.
enum OutboxQueue {
    // MARK: - Enqueue (§8.1, §8.2)

    static func enqueue(
        _ db: Database, _ new: NewOutboxItem, holdFor hold: Duration?, now: LeaseInstant, wall: Date
    ) throws -> OutboxEnqueueResult {
        if try StoreFence.isRetired(db) { throw StoreError.retired }
        let payload = new.payload
        let kind = payload.kind
        let entityId = payload.entityId(itemId: new.id)
        if kind == .entryUpdate || kind == .entryDelete { try requireVisible(db, entryId: entityId) }
        var new = new
        new.cancelsCreate = false
        if let hold {
            // K5: a held delete is appended and nothing before it changes, so Undo is exact.
            guard kind == .entryDelete else { throw OutboxError.invalidHold }
            new.hold = now.adding(hold)
            return .appended(try OutboxStorage.append(db, new, now: wall))
        }
        new.hold = nil
        if let previous = try OutboxStorage.items(db, topicId: payload.topicId).last,
            previous.entityKind == kind.entityKind, previous.entityId == entityId, previous.state == .pending,
            previous.attempts == 0
        {
            switch (kind, previous.kind) {
            case (.entryUpdate, .entryCreate), (.entryUpdate, .entryUpdate):
                if let merged = try merge(db, payload, into: previous, wall: wall) { return .merged(merged) }
            case (.topicArchive, .topicUnarchive), (.topicUnarchive, .topicArchive):
                try remove(db, previous)
                return .cancelled
            default:
                break
            }
        }
        let item = try OutboxStorage.append(db, new, now: wall)
        guard kind == .entryDelete else { return .appended(item) }
        // K4: an immediate delete is released at once.
        return try releaseDelete(db, item, wall: wall).map(OutboxEnqueueResult.appended) ?? .cancelled
    }

    /// C0: an entry with a tombstone or any unresolved delete takes no more writes. A failed
    /// delete still shows its row ("Couldn't delete"), but it stays unresolved until the user
    /// retries or discards it, so nothing may queue behind it.
    static func requireVisible(_ db: Database, entryId: String) throws {
        if try ServerLayer.isTombstoned(db, kind: .entry, id: entryId) { throw OutboxError.entryDeleted }
        let items = try OutboxStorage.items(db, entityKind: .entry, entityId: entryId)
        if items.contains(where: { $0.kind == .entryDelete }) { throw OutboxError.entryDeleted }
    }

    /// K1/K2: merges an update's patch into the adjacent never-attempted create or update, with
    /// a CAS on `row_version` (S6). Nil if the CAS lost (then the caller appends).
    private static func merge(_ db: Database, _ payload: OutboxPayload, into target: OutboxItem, wall: Date) throws
        -> OutboxItem?
    {
        guard case .entryUpdate(_, _, let patch) = payload else { return nil }
        let merged: OutboxPayload
        switch try target.payload() {
        case .entryCreate(let topic, var body):
            for (key, value) in patch.answers ?? [:] {
                if let value { body.answers[key] = .some(value) } else { body.answers.removeValue(forKey: key) }
            }
            body.capturedAt = patch.capturedAt ?? body.capturedAt
            body.notes = patch.notes ?? body.notes
            body.source = patch.source ?? body.source
            body.meta = patch.meta ?? body.meta
            merged = .entryCreate(topic: topic, body: body)
        case .entryUpdate(let entryId, let topicId, var earlier):
            if let answers = patch.answers {
                var combined = earlier.answers ?? [:]
                // Keep explicit nulls: in a patch they remove the key on the server.
                for (key, value) in answers { combined.updateValue(value, forKey: key) }
                earlier.answers = combined
            }
            earlier.capturedAt = patch.capturedAt ?? earlier.capturedAt
            earlier.notes = patch.notes ?? earlier.notes
            earlier.source = patch.source ?? earlier.source
            earlier.meta = patch.meta ?? earlier.meta
            merged = .entryUpdate(entryId: entryId, topicId: topicId, patch: earlier)
        default:
            return nil
        }
        try db.execute(
            sql: """
                UPDATE outbox_item SET payload_json = ?, row_version = row_version + 1, updated_at = ?
                WHERE id = ? AND row_version = ? AND state = 'pending' AND attempts = 0
                """,
            arguments: [try merged.encoded(), wall.unixSeconds, target.id, target.rowVersion])
        guard db.changesCount > 0 else { return nil }
        return try OutboxStorage.item(db, id: target.id)
    }

    // MARK: - Delete release (§8.3, §9.2 step 3)

    /// Runs on a delete D that just became `pending` (an immediate delete, or a released hold).
    /// If D's entity still has its create queued, D takes the role §9.1 gives the DELETE: the
    /// create is cancelled, and D is dropped (never delivered), kept standalone (maybe delivered)
    /// or marked `cancels_create` (in flight). Then §8.3 drops the contiguous run of
    /// never-attempted items before D. Returns D, or nil when D was dropped.
    static func releaseDelete(_ db: Database, _ delete: OutboxItem, wall: Date) throws -> OutboxItem? {
        let items = try OutboxStorage.items(db, entityKind: .entry, entityId: delete.entityId)
        if let create = items.first(where: { $0.kind == .entryCreate }), create.state != .inFlight {
            for item in items where item.id != delete.id { try OutboxStorage.delete(db, id: item.id) }
            guard create.maybeDelivered else {
                try OutboxStorage.delete(db, id: delete.id)
                return nil
            }
            return try OutboxStorage.item(db, id: delete.id)
        }
        if items.contains(where: { $0.kind == .entryCreate }) {
            try db.execute(sql: "UPDATE outbox_item SET cancels_create = 1 WHERE id = ?", arguments: [delete.id])
        }
        guard try coalesceDelete(db, delete) else { return nil }
        return try OutboxStorage.item(db, id: delete.id)
    }

    /// §8.3: walk back from D through its topic scope while the preceding item is D's entity,
    /// `pending` and never attempted. A run holding the create goes with D; a run of updates goes
    /// and D stays. Returns whether D stays.
    private static func coalesceDelete(_ db: Database, _ delete: OutboxItem) throws -> Bool {
        var run: [OutboxItem] = []
        for item in try OutboxStorage.items(db, topicId: delete.topicId).reversed() where item.seq < delete.seq {
            guard item.entityKind == .entry, item.entityId == delete.entityId, item.state == .pending,
                item.attempts == 0
            else { break }
            run.append(item)
        }
        for item in run { try OutboxStorage.delete(db, id: item.id) }
        if run.contains(where: { $0.kind == .entryCreate }) {
            try OutboxStorage.delete(db, id: delete.id)
            return false
        }
        try OutboxStorage.chainRevision(db, entityKind: .entry, entityId: delete.entityId)
        return true
    }

    /// Releases held deletes whose hold has passed, or all of them (`all`: the app went to the
    /// background), each through `releaseDelete`. Returns how many were released.
    @discardableResult
    static func releaseHolds(_ db: Database, all: Bool, now: LeaseInstant, wall: Date) throws -> Int {
        let held = try OutboxStorage.items(db).filter { item in
            item.state == .held && (all || item.hold.map { now.hasPassed(deadline: $0) } ?? true)
        }
        for item in held {
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'pending', hold_boot_id = NULL, hold_ct = NULL, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [wall.unixSeconds, item.id])
            guard let released = try OutboxStorage.item(db, id: item.id) else { continue }
            _ = try releaseDelete(db, released, wall: wall)
        }
        return held.count
    }

    // MARK: - Undo (§9)

    /// `cancelCreate(E)` (§9.1). Cancelling is not coalescing: only E's own items change.
    static func cancelCreate(_ db: Database, entryId: String, origin: OutboxOrigin, now: LeaseInstant, wall: Date)
        throws -> OutboxUndoLogResult
    {
        if try StoreFence.isRetired(db) { throw StoreError.retired }
        if try ServerLayer.isTombstoned(db, kind: .entry, id: entryId) { return .nothingToDo }
        let items = try OutboxStorage.items(db, entityKind: .entry, entityId: entryId)
        if let held = items.first(where: { $0.kind == .entryDelete && $0.state == .held }) {
            // A delete-with-undo is pending for E: undoing the log releases it now.
            try releaseHolds(db, ids: [held.id], wall: wall)
            return try OutboxStorage.items(db, entityKind: .entry, entityId: entryId).isEmpty ? .removed : .deleteQueued
        }
        // Already being deleted; a failed delete is retried or discarded from the sync sheet.
        if items.contains(where: { $0.kind == .entryDelete }) { return .nothingToDo }
        guard let create = items.first(where: { $0.kind == .entryCreate }) else {
            // Acked: delete it like any server entry.
            guard
                let topicId = try String.fetchOne(
                    db, sql: "SELECT topic_id FROM entry WHERE id = ?", arguments: [entryId])
            else { return .nothingToDo }
            let delete = NewOutboxItem(payload: .entryDelete(entryId: entryId, topicId: topicId), origin: origin)
            return switch try enqueue(db, delete, holdFor: nil, now: now, wall: wall) {
            case .cancelled: .removed
            case .appended, .merged: .deleteQueued
            }
        }
        let delete = NewOutboxItem(
            payload: .entryDelete(entryId: entryId, topicId: create.topicId), origin: origin,
            cancelsCreate: create.state == .inFlight)
        if create.state == .inFlight {
            // The POST may be on the wire: the DELETE follows it, and S8 removes the create if it
            // doesn't succeed. E's queued updates were never attempted (they wait for the create).
            for item in items where item.id != create.id { try OutboxStorage.delete(db, id: item.id) }
            _ = try OutboxStorage.append(db, delete, now: wall)
            return .deleteQueued
        }
        for item in items { try OutboxStorage.delete(db, id: item.id) }
        guard create.maybeDelivered else { return .removed }
        // The POST may have committed: a standalone DELETE reserves the id (§6a rule 2).
        _ = try OutboxStorage.append(db, delete, now: wall)
        return .deleteQueued
    }

    /// §9.2 step 2: removes only the held delete.
    static func undoDelete(_ db: Database, entryId: String) throws -> OutboxUndoDeleteResult {
        let deletes = try OutboxStorage.items(db, entityKind: .entry, entityId: entryId).filter {
            $0.kind == .entryDelete
        }
        if let held = deletes.first(where: { $0.state == .held }) {
            try remove(db, held)
            return .restored
        }
        return deletes.isEmpty ? .nothingToDo : .tooLate
    }

    private static func releaseHolds(_ db: Database, ids: [String], wall: Date) throws {
        for id in ids {
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'pending', hold_boot_id = NULL, hold_ct = NULL, updated_at = ?
                    WHERE id = ? AND state = 'held'
                    """,
                arguments: [wall.unixSeconds, id])
            if let released = try OutboxStorage.item(db, id: id) { _ = try releaseDelete(db, released, wall: wall) }
        }
    }

    // MARK: - User actions (§11)

    static func retry(_ db: Database, itemId: String, wall: Date) throws {
        let item = try require(db, itemId)
        switch item.state {
        case .failed where item.failureReason != .deletedElsewhere, .pending, .uncertain:
            try db.execute(
                sql: """
                    UPDATE outbox_item
                    SET state = ?, failure_reason = NULL, due_boot_id = NULL, due_ct = NULL, rebase_count = 0,
                        updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    (item.maybeDelivered ? OutboxState.uncertain : .pending).rawValue, wall.unixSeconds, item.id,
                ])
        default:
            throw OutboxError.notAllowed("Retry isn't available for this item")
        }
    }

    /// Fix (§11): replaces a failed create's or update's payload (CAS on `row_version`) and makes
    /// it pending. For an update, `overriding` names the fields the user corrected: later queued
    /// (never in-flight) updates of the entity lose those fields, and one left with nothing is
    /// removed, all in this transaction. The user's correction is their latest word: it must not
    /// be undone by an edit queued before it was made (§11 leaves this open; this is the rule).
    static func fix(
        _ db: Database, itemId: String, payload: OutboxPayload, rowVersion: Int, overriding: EntryOverride? = nil,
        wall: Date
    ) throws {
        let item = try require(db, itemId)
        let fixable: Set<OutboxFailureReason> = [.rejected, .topicArchived, .futureTime]
        guard item.state == .failed, !item.maybeDelivered, item.kind == .entryCreate || item.kind == .entryUpdate,
            payload.kind == item.kind, item.failureReason.map(fixable.contains) ?? false
        else { throw OutboxError.notAllowed("Fix isn't available for this item") }
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET payload_json = ?, state = 'pending', failure_reason = NULL, due_boot_id = NULL, due_ct = NULL,
                    rebase_count = 0, row_version = row_version + 1, updated_at = ?
                WHERE id = ? AND row_version = ?
                """,
            arguments: [try payload.encoded(), wall.unixSeconds, item.id, rowVersion])
        guard db.changesCount > 0 else { throw OutboxError.itemChanged }
        guard let overriding, !overriding.isEmpty, item.kind == .entryUpdate else { return }
        let later = try OutboxStorage.items(db, entityKind: .entry, entityId: item.entityId)
            .filter { $0.seq > item.seq && $0.kind == .entryUpdate && $0.state != .inFlight }
        for next in later {
            guard case .entryUpdate(let entryId, let topicId, var patch) = try next.payload() else { continue }
            if let answers = patch.answers {
                let kept = answers.filter { !overriding.answerKeys.contains($0.key) }
                patch.answers = kept.isEmpty ? nil : kept
            }
            if overriding.capturedAt { patch.capturedAt = nil }
            if overriding.notes { patch.notes = nil }
            if overriding.source { patch.source = nil }
            if patch.answers == nil, patch.capturedAt == nil, patch.notes == nil, patch.source == nil, patch.meta == nil
            {
                try remove(db, next)
                continue
            }
            try db.execute(
                sql:
                    "UPDATE outbox_item SET payload_json = ?, row_version = row_version + 1, updated_at = ? WHERE id = ?",
                arguments: [
                    try OutboxPayload.entryUpdate(entryId: entryId, topicId: topicId, patch: patch).encoded(),
                    wall.unixSeconds, next.id,
                ])
        }
    }

    static func discard(_ db: Database, itemId: String, origin: OutboxOrigin, now: LeaseInstant, wall: Date) throws {
        let item = try require(db, itemId)
        guard item.state != .inFlight else { throw OutboxError.notAllowed("The item is being sent") }
        guard item.kind == .entryCreate else {
            try remove(db, item)
            return
        }
        // A discarded create cascades to every later item of its entity; one that may have been
        // delivered is cancelled with a standalone DELETE (cancelCreate).
        _ = try cancelCreate(db, entryId: item.entityId, origin: origin, now: now, wall: wall)
    }

    static func dismiss(_ db: Database, itemId: String) throws {
        let item = try require(db, itemId)
        guard item.state == .failed, item.failureReason == .deletedElsewhere else {
            throw OutboxError.notAllowed("Only items deleted elsewhere can be dismissed")
        }
        try OutboxStorage.delete(db, id: item.id)
    }

    // MARK: - Helpers

    /// Removes an item and chains its entity's next revision (§7.3).
    static func remove(_ db: Database, _ item: OutboxItem) throws {
        try OutboxStorage.delete(db, id: item.id)
        try OutboxStorage.chainRevision(db, entityKind: item.entityKind, entityId: item.entityId)
    }

    /// Fails an item: terminal until the user acts (S5: only with a reason).
    static func fail(
        _ db: Database, _ itemId: String, _ reason: OutboxFailureReason, _ error: OutboxErrorInfo?, wall: Date
    ) throws {
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = 'failed', failure_reason = ?, last_error_json = COALESCE(?, last_error_json),
                    due_boot_id = NULL, due_ct = NULL, claim_token = NULL, claim_owner = NULL,
                    claim_layer_gen = NULL, claim_epoch = NULL, pre_claim_json = NULL, updated_at = ?
                WHERE id = ?
                """,
            arguments: [reason.rawValue, try error.map(StoreJSON.encode), wall.unixSeconds, itemId])
    }

    private static func require(_ db: Database, _ itemId: String) throws -> OutboxItem {
        guard let item = try OutboxStorage.item(db, id: itemId) else { throw OutboxError.itemNotFound(itemId) }
        return item
    }
}

/// The outbox side of sync's page transaction (sync-protocol.md §4.3 step 3, §4.4) and of the
/// S8 rule. SYNC calls these inside its fenced page transaction; the outbox calls them inside its
/// sender-checked outcome transactions.
public enum OutboxSyncEffects {
    /// §4.3 step 3: resolves the items that depend on a deleted entity (an entry's items, or every
    /// item of a topic). In-flight items are left to their outcome.
    public static func resolveDependents(_ db: Database, kind: Deletion.EntityKind, id: String, wall: Date) throws {
        let items: [OutboxItem]
        switch kind {
        case .entry: items = try OutboxStorage.items(db, entityKind: .entry, entityId: id)
        case .topic: items = try OutboxStorage.items(db, topicId: id)
        // A run's queued events are kept and sent (timers.md §7.2).
        case .version, .run: return
        }
        let deletes = items.filter { $0.kind == .entryDelete }
        let gone = OutboxErrorInfo(message: OutboxMessage.deletedElsewhere)
        for item in items where item.state != .inFlight {
            switch item.kind {
            case .entryDelete, .topicArchive:
                try OutboxStorage.delete(db, id: item.id)
            case .entryCreate, .entryUpdate:
                let laterDelete = deletes.contains { $0.entityId == item.entityId && $0.seq > item.seq }
                if laterDelete {
                    try OutboxStorage.delete(db, id: item.id)
                } else {
                    try OutboxQueue.fail(db, item.id, .deletedElsewhere, gone, wall: wall)
                }
            case .topicUnarchive:
                try OutboxQueue.fail(db, item.id, .deletedElsewhere, gone, wall: wall)
            }
        }
    }

    /// §4.4: a server row arrived for an entity whose create is still queued. Unless the create
    /// is in flight (its sender resolves it), removing it is its ack.
    public static func pullAck(_ db: Database, entryId: String) throws {
        let items = try OutboxStorage.items(db, entityKind: .entry, entityId: entryId)
        guard let create = items.first(where: { $0.kind == .entryCreate }), create.state != .inFlight else { return }
        try OutboxQueue.remove(db, create)
    }

    /// Flush-expiry recovery (outbox.md §6.3) with S8, in the transaction that takes over an
    /// abandoned `flush` lease (a flusher's, or a rebuild swap's) and in the swap itself: every
    /// in-flight item becomes uncertain and loses its claim, then cancelled creates go.
    public static func recoverExpiredFlush(_ db: Database, now: Date) throws {
        try FlushRecovery.recoverInFlight(db, now: now)
        try removeCancelledCreates(db)
    }

    /// S8: a create that has left `in_flight` without a 2xx while a later `cancels_create` delete
    /// exists is removed, with the updates queued between the two. The delete then has no
    /// predecessor and is sent on its own. Idempotent; run after every exit from `in_flight`.
    public static func removeCancelledCreates(_ db: Database) throws {
        let cancels = try OutboxStorage.items(db).filter { $0.kind == .entryDelete && $0.cancelsCreate }
        for delete in cancels {
            let items = try OutboxStorage.items(db, entityKind: .entry, entityId: delete.entityId)
            guard let create = items.first(where: { $0.kind == .entryCreate }), create.state != .inFlight,
                create.seq < delete.seq
            else { continue }
            for item in items where item.seq >= create.seq && item.seq < delete.seq {
                try OutboxStorage.delete(db, id: item.id)
            }
            try OutboxStorage.chainRevision(db, entityKind: .entry, entityId: delete.entityId)
        }
    }
}
