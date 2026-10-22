import Foundation
import GRDB
import QuickrCore

/// When a feed request was sent and its response received, by the device wall clock (§10).
public struct FeedTiming: Sendable, Hashable {
    public var sentAt: Date
    public var receivedAt: Date

    public init(sentAt: Date, receivedAt: Date) {
        self.sentAt = sentAt
        self.receivedAt = receivedAt
    }
}

/// What a live pull captured before its request (sync-protocol.md §5.4 `liveStep`): the page is
/// applied only if all of it is still current.
public struct LiveContext: Sendable, Hashable {
    public var layerGen: Int
    /// nil before the first page (a bootstrap adopts the page's epoch).
    public var epoch: String?
    public var cursor: Int
    public var claim: LeaseClaim

    public init(layerGen: Int, epoch: String?, cursor: Int, claim: LeaseClaim) {
        self.layerGen = layerGen
        self.epoch = epoch
        self.cursor = cursor
        self.claim = claim
    }

    var fence: [StoreFence.Condition] { [.notRetired, .layerGen(layerGen), .liveEpoch(epoch), .lease(claim)] }
}

/// The staging context (§7 step 2): built from the persisted state, so a coordinator that takes
/// over a half-finished rebuild builds the same one.
public struct StageContext: Sendable, Hashable {
    public var layerGen: Int
    public var targetEpoch: String
    /// `stage_state.cursor` when the request was built.
    public var cursor: Int
    public var claim: LeaseClaim

    public init(layerGen: Int, targetEpoch: String, cursor: Int, claim: LeaseClaim) {
        self.layerGen = layerGen
        self.targetEpoch = targetEpoch
        self.cursor = cursor
        self.claim = claim
    }

    var fence: [StoreFence.Condition] { [.notRetired, .layerGen(layerGen), .stagedEpoch(targetEpoch), .lease(claim)] }
}

/// Why a fenced coordinator transaction wrote nothing.
public enum CoordinatorFence: Error, Sendable, Hashable {
    case fence(FenceFailure)
    /// The cursor the request was built from moved (only a newer coordinator could move it).
    case cursorMoved
    /// The `sync` lease couldn't be renewed.
    case renewFailed
}

public enum PageApplyResult: Sendable, Hashable {
    /// Committed with the cursor advance. `deletedTopics` are the topic tombstones the page
    /// added, for `SyncEvent.topicsDeleted`.
    case applied(deletedTopics: [UUID])
    /// Nothing was written (§5.5): a newer coordinator owns the store, or the context is stale.
    case fenced(CoordinatorFence)
    /// `next < cursor` (§2.2): nothing was written.
    case protocolError(String)
}

public enum StartRebuildResult: Sendable, Hashable {
    /// `rebuilding` is now the target; staging was cleared.
    case started
    /// Already staging for this target: nothing changed (§5.4, S15).
    case alreadyStaging
    case fenced(CoordinatorFence)
}

public enum SwapResult: Sendable, Hashable {
    case swapped(layerGen: Int, deletedTopics: [UUID])
    case fenced(CoordinatorFence)
}

/// The coordinator's transactions on one store file (sync-protocol.md §4, §5.4, §7). Each
/// function is the body of one `IMMEDIATE` transaction and **starts with its fence**: if the
/// fence fails it returns before writing anything. `now` is lease time and must be sampled
/// inside the transaction.
public enum SyncTransactions {
    // MARK: - Live pages (§4.1)

    public static func applyLivePage(
        _ db: Database, page: ChangePage, context: LiveContext, now: LeaseInstant, wallNow: Date, timing: FeedTiming?
    ) throws -> PageApplyResult {
        if let failure = try fence(db, context.fence, claim: context.claim, now: now) { return .fenced(failure) }
        let state = try syncState(db)
        guard state.cursor == context.cursor else { return .fenced(.cursorMoved) }
        guard page.next >= state.cursor else {
            return .protocolError("next \(page.next) is below the cursor \(state.cursor)")
        }
        try applyUpserts(db, page.items, layer: .live)
        let deletedTopics = try applyDeletions(db, page.deleted, layer: .live, wallNow: wallNow)
        try pullAck(db, entryIds: page.items.compactMap(\.entryId))
        let skew = Skew.updated(state: state, serverTime: page.serverTime, timing: timing)
        try db.execute(
            sql: """
                UPDATE sync_state
                SET epoch = ?, cursor = ?, head_seen = ?, last_pull_at = ?, epoch_suspect = 0,
                    skew_ms = ?, skew_measured_at = ?,
                    bootstrap_complete = CASE WHEN ? THEN 1 ELSE bootstrap_complete END
                WHERE id = 1
                """,
            arguments: [
                page.epoch, page.next, page.head, wallNow.unixSeconds, skew.ms, skew.measuredAt?.unixSeconds,
                !page.hasMore,
            ])
        return .applied(deletedTopics: deletedTopics)
    }

    // MARK: - Rebuild (§7)

    /// `startRebuild(E)` (§5.4): idempotent for the same target, so a staged page or a flusher's
    /// report for the epoch being staged never clears staging again.
    public static func startRebuild(
        _ db: Database, target: String, layerGen: Int, claim: LeaseClaim, now: LeaseInstant
    ) throws -> StartRebuildResult {
        if let failure = try fence(db, [.notRetired, .layerGen(layerGen), .lease(claim)], claim: claim, now: now) {
            return .fenced(failure)
        }
        if try syncState(db).rebuilding == target { return .alreadyStaging }
        try clearStaging(db)
        try db.execute(sql: "UPDATE sync_state SET rebuilding = ? WHERE id = 1", arguments: [target])
        return .started
    }

    /// One staged page (§7 step 2): the same guards, against the stage tables. No outbox work:
    /// dependents and pull-acks run once, at the swap.
    public static func applyStagedPage(
        _ db: Database, page: ChangePage, context: StageContext, now: LeaseInstant, wallNow: Date, timing: FeedTiming?
    ) throws -> PageApplyResult {
        if let failure = try fence(db, context.fence, claim: context.claim, now: now) { return .fenced(failure) }
        let stageCursor = try stageCursor(db)
        guard stageCursor == context.cursor else { return .fenced(.cursorMoved) }
        guard page.next >= stageCursor else {
            return .protocolError("next \(page.next) is below the stage cursor \(stageCursor)")
        }
        try applyUpserts(db, page.items, layer: .stage)
        _ = try applyDeletions(db, page.deleted, layer: .stage, wallNow: wallNow)
        try db.execute(sql: "UPDATE stage_state SET cursor = ? WHERE id = 1", arguments: [page.next])
        let skew = Skew.updated(state: try syncState(db), serverTime: page.serverTime, timing: timing)
        try db.execute(
            sql: "UPDATE sync_state SET skew_ms = ?, skew_measured_at = ? WHERE id = 1",
            arguments: [skew.ms, skew.measuredAt?.unixSeconds])
        return .applied(deletedTopics: [])
    }

    /// The swap (§7 step 3.2), fenced on both leases: the staged rows replace the server layer,
    /// `layer_gen += 1`, in-flight items become uncertain (their senders' fences now fail), then
    /// pull-ack, cancelled creates (outbox.md S8) and tombstone dependents over the whole outbox.
    public static func swap(
        _ db: Database, context: StageContext, flush: LeaseClaim, head: Int, now: LeaseInstant, wallNow: Date
    ) throws -> SwapResult {
        if let failure = try fence(db, context.fence + [.lease(flush)], claim: nil, now: now) {
            return .fenced(failure)
        }
        let stageCursor = try stageCursor(db)
        guard stageCursor == context.cursor else { return .fenced(.cursorMoved) }
        let topicsBefore = Set(try String.fetchAll(db, sql: "SELECT id FROM topic"))
        for table in StoreSchema.serverLayerTables {
            try db.execute(sql: "DELETE FROM \(table)")
            try db.execute(sql: "INSERT INTO \(table) SELECT * FROM stage_\(table)")
        }
        try clearStaging(db)
        try db.execute(
            sql: """
                UPDATE sync_state
                SET epoch = ?, cursor = ?, head_seen = ?, rebuilding = NULL, epoch_suspect = 0,
                    layer_gen = layer_gen + 1, last_pull_at = ?, bootstrap_complete = 1
                WHERE id = 1
                """,
            arguments: [context.targetEpoch, stageCursor, head, wallNow.unixSeconds])

        try OutboxSyncEffects.recoverExpiredFlush(db, now: wallNow)
        try pullAck(
            db, entryIds: try String.fetchAll(db, sql: "SELECT entity_id FROM outbox_item WHERE kind = 'entry.create'"))
        try resolveTombstonedDependents(db, wallNow: wallNow)

        let topicsAfter = Set(try String.fetchAll(db, sql: "SELECT id FROM topic"))
        let layerGen = try syncState(db).layerGen
        return .swapped(
            layerGen: layerGen, deletedTopics: topicsBefore.subtracting(topicsAfter).sorted().compactMap(UUID.init))
    }

    // MARK: - Flags

    /// A page from another server (§8.3): stop syncing and flushing this store.
    public static func setIdentityMismatch(_ db: Database, layerGen: Int, claim: LeaseClaim, now: LeaseInstant) throws
        -> CoordinatorFence?
    {
        if let failure = try fence(db, [.notRetired, .layerGen(layerGen), .lease(claim)], claim: claim, now: now) {
            return failure
        }
        try db.execute(sql: "UPDATE sync_state SET identity_mismatch = 1 WHERE id = 1")
        return nil
    }

    /// Clears identity mismatch once a page names the store's server again (§8.3 Keep waiting).
    public static func clearIdentityMismatch(_ db: Database, layerGen: Int, claim: LeaseClaim, now: LeaseInstant)
        throws -> CoordinatorFence?
    {
        if let failure = try fence(db, [.notRetired, .layerGen(layerGen), .lease(claim)], claim: claim, now: now) {
            return failure
        }
        try db.execute(sql: "UPDATE sync_state SET identity_mismatch = 0 WHERE id = 1")
        return nil
    }

    /// A response from another epoch outside a page (§5.6): claims stop until a page confirms
    /// the epoch or a swap clears it. Fenced on the request context only (any process may run it).
    public static func setEpochSuspect(_ db: Database, conditions: [StoreFence.Condition], now: LeaseInstant) throws
        -> FenceFailure?
    {
        if let failure = try StoreFence.check(db, conditions, at: now) { return failure }
        try db.execute(sql: "UPDATE sync_state SET epoch_suspect = 1 WHERE id = 1")
        return nil
    }

    // MARK: - Pieces

    /// Fence, then renew `claim` (the `sync` lease) in the same transaction.
    private static func fence(
        _ db: Database, _ conditions: [StoreFence.Condition], claim: LeaseClaim?, now: LeaseInstant
    ) throws -> CoordinatorFence? {
        if let failure = try StoreFence.check(db, conditions, at: now) { return .fence(failure) }
        if let claim, try !LeaseTable.renew(db, claim, at: now) { return .renewFailed }
        return nil
    }

    static func syncState(_ db: Database) throws -> SyncState {
        guard let state = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
        else { throw StoreError.notBootstrapped }
        return state
    }

    static func stageCursor(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state WHERE id = 1") ?? 0
    }

    private static func clearStaging(_ db: Database) throws {
        for table in StoreSchema.serverLayerTables { try db.execute(sql: "DELETE FROM stage_\(table)") }
        try db.execute(sql: "UPDATE stage_state SET cursor = 0 WHERE id = 1")
    }

    /// §4.1 step 2: topics, then versions, then entries, each through the §4.2 guards.
    private static func applyUpserts(_ db: Database, _ items: [ChangeItem], layer: ServerLayer.Layer) throws {
        for item in items {
            if case .topic(_, let topic) = item { _ = try ServerLayer.upsert(db, topic: topic, into: layer) }
        }
        for item in items {
            if case .version(_, let id, let topicId, let version) = item {
                _ = try ServerLayer.insert(db, version: version, id: id, topicId: topicId, into: layer)
            }
        }
        for item in items {
            if case .entry(_, let entry) = item { _ = try ServerLayer.upsert(db, entry: entry, into: layer) }
        }
    }

    /// §4.3: tombstones and the local cascade, then (live only) the dependent outbox items.
    /// Returns the topics this page tombstoned.
    private static func applyDeletions(
        _ db: Database, _ deletions: [Deletion], layer: ServerLayer.Layer, wallNow: Date
    ) throws -> [UUID] {
        var deletedTopics: [UUID] = []
        for deletion in deletions {
            let wasTombstoned =
                try deletion.kind == .topic
                && ServerLayer.isTombstoned(db, kind: .topic, id: deletion.id.wireString, layer: layer)
            try ServerLayer.applyDeletion(
                db, kind: deletion.kind, id: deletion.id, topicId: deletion.topicId, seq: deletion.seq, into: layer)
            guard layer == .live else { continue }
            switch deletion.kind {
            case .topic:
                if !wasTombstoned { deletedTopics.append(deletion.id) }
                try OutboxSyncEffects.resolveDependents(db, kind: .topic, id: deletion.id.wireString, wall: wallNow)
            case .entry:
                try OutboxSyncEffects.resolveDependents(db, kind: .entry, id: deletion.id.wireString, wall: wallNow)
            case .version:
                break
            }
        }
        return deletedTopics
    }

    /// §4.4: an `entry.create` whose entity now has a server row has landed. Remove it unless it
    /// is in flight (its sender resolves it), then chain the entity's next item.
    /// Only for entities whose server row is present now: an upsert the tombstone guard dropped
    /// is not a landing (its dependents resolve through the tombstone instead), and the swap runs
    /// this over the whole outbox.
    private static func pullAck(_ db: Database, entryIds: [String]) throws {
        for id in Set(entryIds) {
            let landed =
                try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entry WHERE id = ?)", arguments: [id]) ?? false
            if landed { try OutboxSyncEffects.pullAck(db, entryId: id) }
        }
    }

    /// The swap's pass (§7 step 3.2): every outbox entity tombstoned in the new layer, directly or
    /// through its topic, resolves by the §4.3 table.
    private static func resolveTombstonedDependents(_ db: Database, wallNow: Date) throws {
        let topics = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT topic_id FROM outbox_item
                WHERE topic_id IN (SELECT id FROM tombstone WHERE kind = 'topic')
                """)
        for topicId in topics {
            try OutboxSyncEffects.resolveDependents(db, kind: .topic, id: topicId, wall: wallNow)
        }
        let entries = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT entity_id FROM outbox_item
                WHERE entity_kind = 'entry' AND entity_id IN (SELECT id FROM tombstone WHERE kind = 'entry')
                  AND topic_id NOT IN (SELECT id FROM tombstone WHERE kind = 'topic')
                """)
        for entryId in entries {
            try OutboxSyncEffects.resolveDependents(db, kind: .entry, id: entryId, wall: wallNow)
        }
    }
}

extension ChangeItem {
    var entryId: String? {
        if case .entry(_, let entry) = self { return entry.id.wireString }
        return nil
    }
}

/// Clock skew (sync-protocol.md §10): `server_time − (t_send + t_recv)/2`, smoothed with
/// α = 0.3; samples with a round trip over 5 s are discarded. The first sample is taken as is.
public enum Skew {
    public static let alpha = 0.3
    public static let maxRoundTrip: TimeInterval = 5

    public static func updated(state: SyncState, serverTime: Date, timing: FeedTiming?) -> (
        ms: Double, measuredAt: Date?
    ) {
        let unchanged = (state.skewMilliseconds, state.skewMeasuredAt)
        guard let timing else { return unchanged }
        let roundTrip = timing.receivedAt.timeIntervalSince(timing.sentAt)
        guard roundTrip >= 0, roundTrip <= maxRoundTrip else { return unchanged }
        let midpoint = timing.sentAt.addingTimeInterval(roundTrip / 2)
        let sample = serverTime.timeIntervalSince(midpoint) * 1000
        let smoothed =
            state.skewMeasuredAt == nil ? sample : (1 - alpha) * state.skewMilliseconds + alpha * sample
        return (smoothed, timing.receivedAt)
    }
}
