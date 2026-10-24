import Foundation
import GRDB
import QuickrCore

/// Why a fenced transaction wrote nothing (sync-protocol.md §5.5).
public enum FenceFailure: Error, Sendable, Hashable {
    /// The file is retired (§12); reopen through the registry.
    case retired
    case notBootstrapped
    /// `layer_gen` changed: a rebuild swap happened since the request was built.
    case layerGen
    /// The epoch differs from the request context's, or a rebuild is staging (live pages).
    case epoch
    /// `rebuilding` is not the staged page's target epoch.
    case stagedEpoch
    /// The lease is no longer valid or no longer carries this token.
    case lease(LeaseName)
    /// The outbox item is gone or no longer carries this claim token.
    case claim
}

/// The fence checks every transaction that applies a network outcome must start with (§5.5).
/// Combine the conditions the outcome needs; the first one that fails is returned and the caller
/// writes nothing.
public enum StoreFence {
    public enum Condition: Sendable, Hashable {
        /// `sync_state.retired = 0`. Everything.
        case notRetired
        /// `sync_state.layer_gen = ctx.layer_gen`. Everything that writes the server layer or
        /// outbox state.
        case layerGen(Int)
        /// `sync_state.epoch = epoch`; the sender check (outbox glossary).
        case epoch(String?)
        /// `sync_state.epoch = epoch AND rebuilding IS NULL`. Live pages.
        case liveEpoch(String?)
        /// `sync_state.rebuilding = target`. Staged pages.
        case stagedEpoch(String)
        /// The lease is valid and carries this token. Coordinator work (`sync`), outbox outcomes
        /// (`flush`).
        case lease(LeaseClaim)
        /// The item still carries this `claim_token`. Outbox outcomes.
        case claim(itemId: String, token: String)
    }

    public static func check(_ db: Database, _ conditions: [Condition], at now: LeaseInstant) throws -> FenceFailure? {
        guard let state = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
        else { return .notBootstrapped }
        for condition in conditions {
            switch condition {
            case .notRetired:
                if state.retired { return .retired }
            case .layerGen(let layerGen):
                if state.layerGen != layerGen { return .layerGen }
            case .epoch(let epoch):
                if state.epoch != epoch { return .epoch }
            case .liveEpoch(let epoch):
                if state.epoch != epoch || state.rebuilding != nil { return .epoch }
            case .stagedEpoch(let target):
                if state.rebuilding != target { return .stagedEpoch }
            case .lease(let claim):
                if try !LeaseTable.holds(db, claim, at: now) { return .lease(claim.name) }
            case .claim(let itemId, let token):
                let current = try String.fetchOne(
                    db, sql: "SELECT claim_token FROM outbox_item WHERE id = ?", arguments: [itemId])
                if current != token { return .claim }
            }
        }
        return nil
    }

    /// Whether the store file is retired. A missing `sync_state` counts as not retired.
    public static func isRetired(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT retired FROM sync_state WHERE id = 1") ?? false
    }
}

/// What a sender captured when it claimed an item (outbox.md S1): the input of the sender check.
public struct SenderContext: Sendable, Hashable {
    public var flush: LeaseClaim
    public var claimToken: String
    public var layerGen: Int
    public var epoch: String?

    public init(flush: LeaseClaim, claimToken: String, layerGen: Int, epoch: String?) {
        self.flush = flush
        self.claimToken = claimToken
        self.layerGen = layerGen
        self.epoch = epoch
    }

    /// The sender check (outbox glossary, sync §6 step 1).
    public func conditions(itemId: String) -> [StoreFence.Condition] {
        [.notRetired, .layerGen(layerGen), .epoch(epoch), .lease(flush), .claim(itemId: itemId, token: claimToken)]
    }
}

/// The server state a definitive success carries (sync-protocol.md §6 step 2).
public enum AckEffect: Sendable, Hashable {
    /// A POST or PATCH response row.
    case entry(Entry)
    /// An archive or unarchive response row.
    case topic(Topic)
    /// A DELETE that succeeded (204, 404 or `entry_deleted`): remove the row, insert a tombstone.
    case entryDeleted(id: UUID, topicId: UUID)
    /// A `run.event` answered (timers.md §8.1), applied or void: its run (and entry), with
    /// `runId`, the id the event was sent to, recorded as an alias when the run differs.
    case runEvent(RunEventResult, runId: UUID)
}

public enum AckOutcome: Sendable, Hashable {
    /// The item is gone and the server state applied (or dropped by a guard, which is still an ack).
    case acked(ServerLayer.UpsertOutcome?)
    /// The fence failed: nothing was written.
    case fenced(FenceFailure)
}

/// The atomic ack (sync-protocol.md §6, PLAN §6a rule 7), as one function to call inside one
/// `IMMEDIATE` transaction: fence, apply the server state under the §4.2 guards, delete the item,
/// chain the entity's next revision. Derived fields are computed on read, so they follow in the
/// same commit. The server row and the overlay change together, so the view never shows the
/// operation twice or not at all.
public enum AtomicAck {
    public static func ack(
        _ db: Database, itemId: String, sender: SenderContext, effect: AckEffect, at now: LeaseInstant
    ) throws -> AckOutcome {
        if let failure = try StoreFence.check(db, sender.conditions(itemId: itemId), at: now) {
            return .fenced(failure)
        }
        guard let item = try OutboxStorage.item(db, id: itemId) else { return .fenced(.claim) }
        let upsert: ServerLayer.UpsertOutcome?
        switch effect {
        case .entry(let entry): upsert = try ServerLayer.upsert(db, entry: entry)
        case .topic(let topic): upsert = try ServerLayer.upsert(db, topic: topic)
        case .entryDeleted(let id, let topicId):
            try ServerLayer.applyDeletion(db, kind: .entry, id: id, topicId: topicId, seq: nil)
            upsert = nil
        case .runEvent(let result, let runId):
            upsert = try ServerLayer.apply(db, runEvent: result, sentTo: runId)
        }
        try OutboxStorage.delete(db, id: itemId)
        try OutboxStorage.chainRevision(db, entityKind: item.entityKind, entityId: item.entityId)
        return .acked(upsert)
    }
}

/// Reset step 4 on the old file (sync-protocol.md §12.1).
public enum RetireOutcome: Sendable, Hashable {
    case retired
    /// Writes were committed after the user's warning: nothing was retired; warn again.
    case writesArrived(count: Int, maxSeq: Int64)
    case fenced(FenceFailure)
    /// The attempt identified by the intent token was aborted on this file (`vetoReset`):
    /// nothing was retired.
    case intentAborted
}

/// Aborting a reset attempt on the old file (§12.1 steps 3–4).
public enum ResetVeto: Sendable, Hashable {
    /// The attempt can no longer retire this file; clear its registry intent.
    case vetoed
    /// Too late: the file is already retired, so the reset goes ahead (step 6 completes it).
    case alreadyRetired
}

public enum StoreRetirement {
    /// Re-checks the outbox against the confirmed count and max seq and, if nothing new arrived,
    /// sets `retired = 1`. Fenced on both leases (taken `sync` → `flush`) and, with
    /// `intentToken`, on that attempt not having been vetoed in this file. Idempotent: an
    /// already retired file reports `.retired`.
    public static func retire(
        _ db: Database, confirmedCount: Int, confirmedMaxSeq: Int64, intentToken: String? = nil, sync: LeaseClaim,
        flush: LeaseClaim, at now: LeaseInstant
    ) throws -> RetireOutcome {
        if try StoreFence.isRetired(db) { return .retired }
        if let failure = try StoreFence.check(db, [.lease(sync), .lease(flush)], at: now) { return .fenced(failure) }
        if let intentToken,
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM reset_veto WHERE token = ?)", arguments: [intentToken]) == true
        {
            return .intentAborted
        }
        let (count, maxSeq) = try OutboxStorage.summary(db)
        if count > confirmedCount || maxSeq > confirmedMaxSeq { return .writesArrived(count: count, maxSeq: maxSeq) }
        try db.execute(sql: "UPDATE sync_state SET retired = 1 WHERE id = 1")
        return .retired
    }

    /// Marks the attempt `intentToken` aborted on this file, unless the file is already retired.
    /// Retirement and abort are serialized by this file's write lock, so the retire of a vetoed
    /// attempt is refused in its own transaction, and an attempt that already retired is never
    /// reported aborted. Needs no lease: a caller that timed out waiting for them uses it.
    public static func vetoReset(_ db: Database, intentToken: String) throws -> ResetVeto {
        if try StoreFence.isRetired(db) { return .alreadyRetired }
        try db.execute(sql: "INSERT OR IGNORE INTO reset_veto (token) VALUES (?)", arguments: [intentToken])
        return .vetoed
    }
}
