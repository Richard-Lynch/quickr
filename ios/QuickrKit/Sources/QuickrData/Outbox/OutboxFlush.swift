import Foundation
import GRDB
import QuickrCore

/// The ordering scopes of outbox.md §7.1, built by walking the unresolved items in `seq` order.
/// An `entry.*` item waits for every earlier item of its entity and every earlier `topic.*` item
/// of its topic; a `topic.*` item waits for every earlier item of its topic. `held` and `failed`
/// items count.
///
/// A `run.event` (timers.md §8.1) waits only for its run's start item and for earlier `topic.*`
/// items of its topic: events are idempotent and folded by time, so they don't wait for each other,
/// and a failed non-start event blocks nothing. A failed start blocks its run until it is retried
/// or discarded. Two more waits:
/// - A `finish` waits for its run's earlier active `stop`s, so the answers never reach the server
///   before the stop they follow (a failed stop doesn't hold it: the finish goes, and fails on
///   `run_open` with its answers kept).
/// - A `start` waits for the earlier active `stop`s and `discard`s of the topic's other runs, so it
///   can't overtake a retrying stop and be merged into the run still open on the server (§4.5). A
///   failed one doesn't hold it (the server merges if it must), nor does one of a run whose own
///   start failed (that run never existed on the server).
///
/// Run ids are resolved through `run_alias` first: an event sent to a merged id is its target's.
struct OutboxScope {
    private var firstOfEntity: [String: OutboxItem] = [:]
    private var firstTopicItem: [String: OutboxItem] = [:]
    private var firstOfTopic: [String: OutboxItem] = [:]
    /// Merged run id → the run it joined (`run_alias`).
    private let aliases: [String: String]
    /// By run id: the run's start item.
    private var startOfRun: [String: OutboxItem] = [:]
    /// By run id: the run's first active `stop` item.
    private var activeStopOfRun: [String: OutboxItem] = [:]
    /// By topic id: the active `stop`s and `discard`s that can hold another run's start, with
    /// their run ids, in `seq` order.
    private var activeEndsOfTopic: [String: [(run: String, item: OutboxItem)]] = [:]

    init(aliases: [String: String] = [:]) { self.aliases = aliases }

    /// `run_alias`, for `init(aliases:)`.
    static func aliases(_ db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, run_id FROM run_alias") { result[row["id"]] = row["run_id"] }
        return result
    }

    private func run(_ item: OutboxItem) -> String { aliases[item.entityId] ?? item.entityId }

    /// The earliest unresolved item in `item`'s scope seen so far, if any.
    func earliest(before item: OutboxItem) -> OutboxItem? {
        switch item.entityKind {
        case .entry:
            return [firstOfEntity[item.entityId], firstTopicItem[item.topicId]].compactMap { $0 }
                .min { $0.seq < $1.seq }
        case .topic:
            return firstOfTopic[item.topicId]
        case .run:
            let run = run(item)
            var blockers = [firstTopicItem[item.topicId], startOfRun[run]]
            switch (try? item.runEventPayload())?.type {
            case .finish:
                blockers.append(activeStopOfRun[run])
            case .start:
                blockers.append(activeEndsOfTopic[item.topicId]?.first { $0.run != run }?.item)
            default:
                break
            }
            return blockers.compactMap { $0 }.min { $0.seq < $1.seq }
        }
    }

    mutating func add(_ item: OutboxItem) {
        if item.entityKind == .entry, firstOfEntity[item.entityId] == nil { firstOfEntity[item.entityId] = item }
        if item.entityKind == .topic, firstTopicItem[item.topicId] == nil { firstTopicItem[item.topicId] = item }
        if firstOfTopic[item.topicId] == nil { firstOfTopic[item.topicId] = item }
        guard item.entityKind == .run, let type = (try? item.runEventPayload())?.type else { return }
        let run = run(item)
        if type == .start, item.id == item.entityId, startOfRun[run] == nil { startOfRun[run] = item }
        guard item.state.isActive else { return }
        if type == .stop, activeStopOfRun[run] == nil { activeStopOfRun[run] = item }
        if type == .stop || type == .discard, startOfRun[run]?.state != .failed {
            activeEndsOfTopic[item.topicId, default: []].append((run, item))
        }
    }
}

/// A claimed item and what its sender needs (S1).
struct OutboxClaim: Sendable {
    var item: OutboxItem
    var sender: SenderContext
    /// `(store.server_id, claim_epoch)`.
    var expecting: ServerIdentity
}

/// The `{state, attempts, due_*}` saved by a claim (S1), restored by a precondition 409 (§5.2).
struct PreClaim: Codable, Hashable {
    var state: OutboxState
    var attempts: Int
    var dueBootId: String? = nil
    var dueCt: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case state, attempts
        case dueBootId = "due_boot_id"
        case dueCt = "due_ct"
    }
}

/// What an outcome transaction did to the item.
enum OutboxApplied: Sendable, Hashable {
    /// The sender check failed: nothing was written (S2).
    case fenced(FenceFailure)
    case acked
    case retired
    case failed(OutboxFailureReason)
    case retried
    /// Pre-claim state restored after a precondition 409.
    case restored
    /// S8 removed a cancelled create on its way out of `in_flight`.
    case cancelled
}

/// The flusher's transactions (outbox.md §6, §12). Every one after the claim begins with the sender
/// check (S2); lease time is sampled by the caller inside the transaction.
enum OutboxFlush {
    static let capturedAtMin = Date(timeIntervalSince1970: 946_684_800)  // 2000-01-01T00:00:00Z
    static let capturedAtMaxFutureHours = 24

    enum ClaimStep: Sendable {
        case claimed(OutboxClaim)
        case drained
        case paused
        /// `client_outdated_min` refuses this build (client-versions.md §4.1).
        case clientOutdated
        case leaseLost
    }

    /// One claim transaction (S1, §6.2, §7.1): renews the lease, checks the rebuild guard and
    /// claims the first eligible item. Items failing the `captured_at` bound fail on the way
    /// (sync-protocol.md §10).
    static func claimNext(
        _ db: Database, lease: LeaseClaim, force: Bool, skipping: Set<String>, now: LeaseInstant, wall: Date
    ) throws -> ClaimStep {
        guard try LeaseTable.renew(db, lease, at: now) else { return .leaseLost }
        guard let state = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:)),
            !state.retired, !state.identityMismatch, !state.epochSuspect, state.rebuilding == nil,
            let epoch = state.epoch
        else { return .paused }
        // Enqueue still works; nothing is sent until quickR is updated (client-versions.md §4.1).
        if state.isClientOutdated { return .clientOutdated }
        try OutboxSyncEffects.removeCancelledCreates(db)
        let serverNow = state.serverClock.now(at: wall)
        let items = try OutboxStorage.items(db)
        // An entity whose delete is held waits for the hold: its release may drop or cancel
        // everything queued before it (§8.3, §9.2), and Undo restores it unchanged.
        let held = Set(items.filter { $0.state == .held }.map(\.entityId))
        var scope = OutboxScope(aliases: try OutboxScope.aliases(db))
        for var item in items {
            defer { scope.add(item) }
            guard item.state == .pending || item.state == .uncertain, !skipping.contains(item.id),
                item.entityKind != .entry || !held.contains(item.entityId),
                force || item.due.map({ now.hasPassed(deadline: $0) }) ?? true, scope.earliest(before: item) == nil
            else { continue }
            if let issue = try capturedAtIssue(item, serverNow: serverNow) {
                try OutboxQueue.fail(db, item.id, .futureTime, OutboxErrorInfo(message: issue), wall: wall)
                item.state = .failed
                continue
            }
            return .claimed(
                try claim(
                    db, item, lease: lease, layerGen: state.layerGen, epoch: epoch, wall: wall,
                    expecting: ServerIdentity(serverId: state.serverId, epoch: epoch)))
        }
        return .drained
    }

    private static func claim(
        _ db: Database, _ item: OutboxItem, lease: LeaseClaim, layerGen: Int, epoch: String, wall: Date,
        expecting: ServerIdentity
    ) throws -> OutboxClaim {
        let token = UUID().uuidString.lowercased()
        let pre = PreClaim(state: item.state, attempts: item.attempts, dueBootId: item.due?.bootId, dueCt: item.due?.ct)
        var base = item.baseRevision
        if base == nil, item.kind == .entryUpdate || item.kind == .topicArchive || item.kind == .topicUnarchive {
            // §7.3: can't happen given §7.1 ordering; fall back to the server-layer revision.
            base = try ServerLayer.revision(db, entityKind: item.entityKind, id: item.entityId)
        }
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = 'in_flight', claim_token = ?, claim_owner = ?, claim_layer_gen = ?, claim_epoch = ?,
                    pre_claim_json = ?, attempts = attempts + 1, base_revision = ?, updated_at = ?
                WHERE id = ?
                """,
            arguments: [
                token, lease.owner, layerGen, epoch, try StoreJSON.encode(pre), base, wall.unixSeconds, item.id,
            ])
        guard let claimed = try OutboxStorage.item(db, id: item.id) else { throw OutboxError.itemNotFound(item.id) }
        return OutboxClaim(
            item: claimed, sender: SenderContext(flush: lease, claimToken: token, layerGen: layerGen, epoch: epoch),
            expecting: expecting)
    }

    /// The send-time `captured_at` bound: `2000-01-01 ≤ captured_at ≤ server_now + 24 h`.
    static func capturedAtIssue(_ item: OutboxItem, serverNow: Date) throws -> String? {
        let capturedAt: Date?
        switch try item.payload() {
        case .entryCreate(_, let body): capturedAt = body.capturedAt
        case .entryUpdate(_, _, let patch): capturedAt = patch.capturedAt
        default: capturedAt = nil
        }
        guard let capturedAt else { return nil }
        if capturedAt < capturedAtMin { return OutboxMessage.beforeMinimum }
        if capturedAt > serverNow.addingTimeInterval(TimeInterval(capturedAtMaxFutureHours) * 3600) {
            return OutboxMessage.futureTime(hours: capturedAtMaxFutureHours)
        }
        return nil
    }

    /// The request for a claimed item, built at send time (§1, §4).
    static func request(for item: OutboxItem, expecting: ServerIdentity, timeout: Duration) throws -> OutboxRequest {
        let operation: OutboxOperation
        switch try item.payload() {
        case .entryCreate(let topic, var body):
            body.id = item.id
            // §4: `source` is the enqueuing process's, whatever the payload carries.
            body.source = item.origin.source
            operation = .createEntry(topicId: topic.id, body: body)
        case .entryUpdate(let entryId, _, var patch):
            patch.expectedRevision = item.baseRevision
            operation = .updateEntry(entryId: try .wire(entryId, "outbox.entry_id"), body: patch)
        case .entryDelete(let entryId, _):
            operation = .deleteEntry(entryId: try .wire(entryId, "outbox.entry_id"))
        case .topicArchive(let topicId):
            operation = .archiveTopic(topicId: topicId, expectedRevision: item.baseRevision)
        case .topicUnarchive(let topicId):
            operation = .unarchiveTopic(topicId: topicId, expectedRevision: item.baseRevision)
        case .runEvent(let payload):
            var body = payload.event
            body.id = item.id
            // As for a create (§4): `source` is the enqueuing process's.
            body.source = item.origin.source
            operation = .recordRunEvent(runId: try .wire(payload.runId, "outbox.run_id"), body: body)
        }
        return OutboxRequest(operation: operation, expecting: expecting, timeout: timeout)
    }

    /// The §7.4 refetch of a claimed item's entity.
    static func refetch(for item: OutboxItem, expecting: ServerIdentity, timeout: Duration) throws -> OutboxRequest {
        let operation: OutboxOperation =
            item.entityKind == .entry
            ? .getEntry(entryId: try .wire(item.entityId, "outbox.entity_id")) : .getTopic(topicId: item.entityId)
        return OutboxRequest(operation: operation, expecting: expecting, timeout: timeout)
    }

    // MARK: - Fenced transactions (S2)

    /// The outcome transaction: sender check, then the resolution, then S8.
    static func apply(
        _ db: Database, itemId: String, sender: SenderContext, resolution: OutboxResolution,
        error: OutboxErrorInfo?, random: Double, now: LeaseInstant, wall: Date
    ) throws -> OutboxApplied {
        if let failure = try StoreFence.check(db, sender.conditions(itemId: itemId), at: now) {
            return .fenced(failure)
        }
        guard let item = try OutboxStorage.item(db, id: itemId) else { return .fenced(.claim) }
        var applied: OutboxApplied
        switch resolution {
        case .ack(let success):
            switch try AtomicAck.ack(db, itemId: itemId, sender: sender, effect: ackEffect(item, success), at: now) {
            case .fenced(let failure): return .fenced(failure)
            case .acked: applied = .acked
            }
        case .entityGone:
            applied = try entityGone(db, item, error: error, wall: wall)
        case .retire:
            try OutboxQueue.remove(db, item)
            applied = .retired
        case .fail(let reason, _):
            let error =
                reason == .topicArchived
                ? OutboxErrorInfo(message: OutboxMessage.topicArchived, status: error?.status, body: error?.body)
                : error
            try OutboxQueue.fail(db, item.id, reason, error, wall: wall)
            applied = .failed(reason)
        case .retry(let maybeDelivered):
            try retry(db, item, maybeDelivered: maybeDelivered, error: error, random: random, now: now, wall: wall)
            applied = .retried
        case .rebase:
            // Resolved by `rebase` before reaching here; a stray one is a plain retry.
            try retry(db, item, maybeDelivered: false, error: error, random: random, now: now, wall: wall)
            applied = .retried
        case .startKnown:
            // Resolved by `Outbox.checkStart` before reaching here; a stray one fails as before.
            try OutboxQueue.fail(db, item.id, .rejected, error, wall: wall)
            applied = .failed(.rejected)
        case .loggedElsewhere:
            try loggedElsewhere(db, item, wall: wall)
            applied = .retired
        case .restore(let mismatch):
            try restore(db, item, wall: wall)
            try flag(db, mismatch)
            applied = .restored
        case .mismatchUncertain(let mismatch):
            try retry(db, item, maybeDelivered: true, error: error, random: random, now: now, wall: wall)
            try flag(db, mismatch)
            applied = .retried
        case .hold(let minimum):
            try restore(db, item, wall: wall)
            try db.execute(
                sql: """
                    UPDATE sync_state SET client_outdated_min = MAX(COALESCE(client_outdated_min, 0), ?)
                    WHERE id = 1
                    """,
                arguments: [max(minimum, APILevel.current + 1)])
            applied = .restored
        }
        try OutboxSyncEffects.removeCancelledCreates(db)
        if item.kind == .entryCreate, applied != .acked, try OutboxStorage.item(db, id: itemId) == nil,
            applied != .retired
        {
            applied = .cancelled
        }
        return applied
    }

    /// §7.4 steps 1 (and the lease renewal of step 3): the sender check, then renew `flush`.
    static func verify(_ db: Database, itemId: String, sender: SenderContext, now: LeaseInstant) throws
        -> FenceFailure?
    {
        if let failure = try StoreFence.check(db, sender.conditions(itemId: itemId), at: now) { return failure }
        return try LeaseTable.renew(db, sender.flush, at: now) ? nil : .lease(.flush)
    }

    enum RebaseStep: Sendable {
        case fenced(FenceFailure)
        /// Resend the item under the same claim.
        case resend(OutboxItem)
        /// More than 3 rebases: `failed/conflict`.
        case conflict
    }

    /// §7.4 steps 3 and 4: verify, upsert the fetched row under the guards, rebase, and decide.
    static func rebase(
        _ db: Database, itemId: String, sender: SenderContext, fetched: OutboxSuccess, now: LeaseInstant, wall: Date
    ) throws -> RebaseStep {
        if let failure = try verify(db, itemId: itemId, sender: sender, now: now) { return .fenced(failure) }
        let revision: Int
        switch fetched {
        case .entry(let entry):
            _ = try ServerLayer.upsert(db, entry: entry)
            revision = entry.revision
        case .topic(let topic):
            _ = try ServerLayer.upsert(db, topic: topic)
            revision = topic.revision
        case .runEvent, .run, .empty:
            return .fenced(.claim)
        }
        try db.execute(
            sql:
                "UPDATE outbox_item SET base_revision = ?, rebase_count = rebase_count + 1, updated_at = ? WHERE id = ?",
            arguments: [revision, wall.unixSeconds, itemId])
        guard let item = try OutboxStorage.item(db, id: itemId) else { return .fenced(.claim) }
        guard item.rebaseCount > Outbox.maxRebases else { return .resend(item) }
        try OutboxQueue.fail(
            db, itemId, .conflict, OutboxErrorInfo(message: OutboxMessage.conflict, status: 409), wall: wall)
        return .conflict
    }

    /// The flusher's release (§10, §12): the item it still holds `in_flight` with its claim token
    /// becomes `uncertain` (S3) and due now, S8 runs, and the lease is freed.
    static func release(_ db: Database, lease: LeaseClaim, current: (itemId: String, token: String)?, wall: Date)
        throws
    {
        if let current {
            try db.execute(
                sql: """
                    UPDATE outbox_item
                    SET state = 'uncertain', maybe_delivered = 1, claim_token = NULL, claim_owner = NULL,
                        claim_layer_gen = NULL, claim_epoch = NULL, pre_claim_json = NULL, due_boot_id = NULL,
                        due_ct = NULL, updated_at = ?
                    WHERE id = ? AND claim_token = ? AND state = 'in_flight'
                    """,
                arguments: [wall.unixSeconds, current.itemId, current.token])
            try OutboxSyncEffects.removeCancelledCreates(db)
        }
        _ = try LeaseTable.release(db, lease)
    }

    /// Expiry recovery (§6.3) with S8, run when this flusher takes over an abandoned lease.
    static func takeover(wallClock: any WallClock) -> LeaseTable.Takeover {
        { db, _ in try OutboxSyncEffects.recoverExpiredFlush(db, now: wallClock.now()) }
    }

    // MARK: - Outcome pieces

    private static func ackEffect(_ item: OutboxItem, _ success: OutboxSuccess) throws -> AckEffect {
        switch success {
        case .entry(let entry): .entry(entry)
        case .topic(let topic): .topic(topic)
        case .runEvent(let result): .runEvent(result, runId: try .wire(item.entityId, "outbox.entity_id"))
        case .run: throw OutboxError.notAllowed("a run read is never acked as is")
        case .empty:
            .entryDeleted(
                id: try .wire(item.entityId, "outbox.entity_id"), topicId: try .wire(item.topicId, "outbox.topic_id"))
        }
    }

    /// `loggedElsewhere`: the start is retired and every other item of its run fails
    /// `logged_elsewhere`, in this transaction: nothing of the run can be sent, and the user sees
    /// (and discards) what was tapped, a Stop's answers included.
    private static func loggedElsewhere(_ db: Database, _ start: OutboxItem, wall: Date) throws {
        try OutboxQueue.remove(db, start)
        let info = OutboxErrorInfo(message: OutboxMessage.loggedElsewhere, status: 409)
        for other in try OutboxStorage.items(db, entityKind: .run, entityId: start.entityId) where other.id != start.id
        {
            try OutboxQueue.fail(db, other.id, .loggedElsewhere, info, wall: wall)
        }
    }

    /// §5.2 "entity gone": tombstone the entry, resolve its other items (sync §4.3), and retire
    /// this one if a later delete exists, else fail it `deleted_elsewhere`.
    private static func entityGone(_ db: Database, _ item: OutboxItem, error: OutboxErrorInfo?, wall: Date) throws
        -> OutboxApplied
    {
        let laterDelete = try OutboxStorage.items(db, entityKind: .entry, entityId: item.entityId).contains {
            $0.kind == .entryDelete && $0.seq > item.seq
        }
        try ServerLayer.applyDeletion(
            db, kind: .entry, id: try .wire(item.entityId, "outbox.entity_id"),
            topicId: try .wire(item.topicId, "outbox.topic_id"), seq: nil)
        try OutboxSyncEffects.resolveDependents(db, kind: .entry, id: item.entityId, wall: wall)
        if laterDelete {
            try OutboxStorage.delete(db, id: item.id)
            return .retired
        }
        let info = OutboxErrorInfo(message: OutboxMessage.deletedElsewhere, status: error?.status, body: error?.body)
        try OutboxQueue.fail(db, item.id, .deletedElsewhere, info, wall: wall)
        return .failed(.deletedElsewhere)
    }

    /// S3/S4: back to `uncertain` (maybe delivered) or `pending`, due after the backoff.
    private static func retry(
        _ db: Database, _ item: OutboxItem, maybeDelivered: Bool, error: OutboxErrorInfo?, random: Double,
        now: LeaseInstant, wall: Date
    ) throws {
        let delivered = item.maybeDelivered || maybeDelivered
        let due = now.adding(OutboxBackoff.delay(attempts: max(1, item.attempts), random: random))
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = ?, maybe_delivered = ?, due_boot_id = ?, due_ct = ?,
                    last_error_json = COALESCE(?, last_error_json), claim_token = NULL, claim_owner = NULL,
                    claim_layer_gen = NULL, claim_epoch = NULL, pre_claim_json = NULL, updated_at = ?
                WHERE id = ?
                """,
            arguments: [
                (delivered ? OutboxState.uncertain : .pending).rawValue, delivered, due.bootId, due.ct,
                try error.map(StoreJSON.encode), wall.unixSeconds, item.id,
            ])
    }

    /// §5.2 precondition 409, and a 426 `client_outdated`: nothing executed. State, attempts and
    /// deadline as before the claim; every claim field cleared; `maybe_delivered` unchanged.
    private static func restore(_ db: Database, _ item: OutboxItem, wall: Date) throws {
        let pre =
            try item.preClaimJSON.map { try StoreJSON.decode(PreClaim.self, $0) }
            ?? PreClaim(state: item.maybeDelivered ? .uncertain : .pending, attempts: max(0, item.attempts - 1))
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = ?, attempts = ?, due_boot_id = ?, due_ct = ?, claim_token = NULL, claim_owner = NULL,
                    claim_layer_gen = NULL, claim_epoch = NULL, pre_claim_json = NULL, updated_at = ?
                WHERE id = ?
                """,
            arguments: [pre.state.rawValue, pre.attempts, pre.dueBootId, pre.dueCt, wall.unixSeconds, item.id])
    }

    private static func flag(_ db: Database, _ mismatch: OutboxMismatch) throws {
        try db.execute(sql: "UPDATE sync_state SET \(mismatch.column) = 1 WHERE id = 1")
    }
}
