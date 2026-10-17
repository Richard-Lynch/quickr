import Foundation
import GRDB

// Lease primitives on a store's `lease` rows `sync` and `flush` (sync-protocol.md §5.2–§5.3,
// outbox.md §6). Every operation is one short `IMMEDIATE` transaction; no transaction is ever
// open while a caller waits. Time is lease time (`LeaseClock`), never wall clock, so moving the
// wall clock either way changes nothing, and a lease from another boot has expired.

extension LeaseName {
    /// Position in the single global lock order: `sync` → `flush` (§5.2).
    public var lockRank: Int {
        switch self {
        case .sync: 0
        case .flush: 1
        }
    }

    /// `sync` 60 s, renewed before every page; `flush` 30 s, renewed in every claim (§5.3).
    public var ttl: Duration {
        switch self {
        case .sync: .seconds(60)
        case .flush: .seconds(30)
        }
    }

    /// Throws unless `self` may be acquired while `holding` is held: everything held must come
    /// strictly earlier in the order. A process holding `flush` never waits for `sync` (§5.2 rule 1).
    public func checkLockOrder(holding: [LeaseClaim]) throws {
        if let held = holding.first(where: { $0.name.lockRank >= lockRank }) {
            throw StoreError.lockOrderViolation(acquiring: self, holding: held.name)
        }
    }
}

/// A held lease: the proof a holder carries into its fenced transactions.
public struct LeaseClaim: Sendable, Hashable {
    public var name: LeaseName
    /// `"<process kind>:<launch uuid>"`.
    public var owner: String
    /// The fencing token, new on every acquisition.
    public var token: String

    public init(name: LeaseName, owner: String, token: String) {
        self.name = name
        self.owner = owner
        self.token = token
    }

    /// The lease owner string for one process launch, for example `app:<uuid>` or `widget:<uuid>`.
    public static func owner(kind: String, launchId: UUID) -> String { "\(kind):\(launchId.wireString)" }
}

/// The lease operations inside a transaction the caller already holds. Use these to fence or
/// renew inside a larger transaction (a page, a claim, an ack); use `Leases` for standalone calls.
/// Sample `now` **inside** the write closure, after `BEGIN IMMEDIATE` holds the lock: a time
/// sampled before may be arbitrarily old by the time the transaction runs.
public enum LeaseTable {
    /// Runs in the acquiring transaction when the previous holder left the lease behind (it is
    /// still owned but no longer valid). Receives the stale row.
    public typealias Takeover = @Sendable (Database, LeaseRecord) throws -> Void

    public static func record(_ db: Database, _ name: LeaseName) throws -> LeaseRecord {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM lease WHERE name = ?", arguments: [name.rawValue])
        else { throw StoreError.corruptRow("lease \(name.rawValue) is missing") }
        let bootId: String? = row["boot_id"]
        let expiresCt: Int64? = row["expires_ct"]
        return LeaseRecord(
            name: name, owner: row["owner"], token: row["token"],
            expires: bootId.flatMap { bootId in expiresCt.map { LeaseInstant(bootId: bootId, ct: $0) } })
    }

    /// Valid iff owned, from this boot, and not yet expired (§5.3).
    public static func isValid(_ record: LeaseRecord, at now: LeaseInstant) -> Bool {
        guard record.owner != nil, let expires = record.expires else { return false }
        return !now.hasPassed(deadline: expires)
    }

    /// Whether `claim` is still the valid holder.
    public static func holds(_ db: Database, _ claim: LeaseClaim, at now: LeaseInstant) throws -> Bool {
        let record = try record(db, claim.name)
        return record.owner == claim.owner && record.token == claim.token && isValid(record, at: now)
    }

    /// Acquires `name` if it isn't valid, with a fresh token. Returns nil if someone (including
    /// this owner) holds it.
    public static func acquire(
        _ db: Database, _ name: LeaseName, owner: String, ttl: Duration? = nil, at now: LeaseInstant,
        takeover: Takeover? = nil
    ) throws -> LeaseClaim? {
        let current = try record(db, name)
        if isValid(current, at: now) { return nil }
        if current.owner != nil { try takeover?(db, current) }
        let claim = LeaseClaim(name: name, owner: owner, token: UUID().uuidString.lowercased())
        let expires = now.adding(ttl ?? name.ttl)
        try db.execute(
            sql: "UPDATE lease SET owner = ?, token = ?, boot_id = ?, expires_ct = ? WHERE name = ?",
            arguments: [owner, claim.token, expires.bootId, expires.ct, name.rawValue])
        return claim
    }

    /// Extends a lease that `claim` still validly holds. False means the lease is lost and the
    /// holder must stop at once.
    public static func renew(_ db: Database, _ claim: LeaseClaim, ttl: Duration? = nil, at now: LeaseInstant) throws
        -> Bool
    {
        guard try holds(db, claim, at: now) else { return false }
        let expires = now.adding(ttl ?? claim.name.ttl)
        try db.execute(
            sql: "UPDATE lease SET boot_id = ?, expires_ct = ? WHERE name = ? AND token = ?",
            arguments: [expires.bootId, expires.ct, claim.name.rawValue, claim.token])
        return true
    }

    /// Frees the lease if it still carries `claim`'s token, valid or not. False if someone else
    /// took it over.
    public static func release(_ db: Database, _ claim: LeaseClaim) throws -> Bool {
        try db.execute(
            sql: """
                UPDATE lease SET owner = NULL, token = NULL, boot_id = NULL, expires_ct = NULL
                WHERE name = ? AND token = ?
                """,
            arguments: [claim.name.rawValue, claim.token])
        return db.changesCount > 0
    }
}

/// Flush-expiry recovery (outbox.md §6.3), run in the transaction that takes over a `flush` lease
/// a previous holder left behind: every `in_flight` item becomes `uncertain` with
/// `maybe_delivered = 1`, loses its claim (so the old holder's sender check fails) and is due now.
/// `attempts` is unchanged. OUTBOX layers its S8 cancelled-create removal on top of this.
public enum FlushRecovery {
    public static func recoverInFlight(_ db: Database, now: Date) throws {
        try db.execute(
            sql: """
                UPDATE outbox_item
                SET state = 'uncertain', maybe_delivered = 1,
                    claim_token = NULL, claim_owner = NULL, claim_layer_gen = NULL, claim_epoch = NULL,
                    pre_claim_json = NULL, due_boot_id = NULL, due_ct = NULL, updated_at = ?
                WHERE state = 'in_flight'
                """,
            arguments: [now.timeIntervalSince1970])
    }
}

/// Standalone lease calls on one store, each its own `IMMEDIATE` transaction. Waiting polls
/// between transactions, never inside one.
public struct Leases: Sendable {
    public let writer: any DatabaseWriter
    public let clock: any LeaseClock
    public let wallClock: any WallClock

    public init(writer: any DatabaseWriter, clock: any LeaseClock, wallClock: any WallClock = SystemWallClock()) {
        self.writer = writer
        self.clock = clock
        self.wallClock = wallClock
    }

    /// One attempt. `holding` is what the caller already holds, checked against the lock order.
    /// With no `takeover`, a `flush` takeover runs `FlushRecovery`.
    public func tryAcquire(
        _ name: LeaseName, owner: String, ttl: Duration? = nil, holding: [LeaseClaim] = [],
        takeover: LeaseTable.Takeover? = nil
    ) async throws -> LeaseClaim? {
        try name.checkLockOrder(holding: holding)
        let takeover = takeover ?? defaultTakeover(name)
        let clock = clock
        return try await writer.write { db in
            try LeaseTable.acquire(db, name, owner: owner, ttl: ttl, at: clock.now(), takeover: takeover)
        }
    }

    /// Polls until the lease is acquired or `timeout` passes (then nil).
    public func acquire(
        _ name: LeaseName, owner: String, ttl: Duration? = nil, holding: [LeaseClaim] = [],
        waitingUpTo timeout: Duration,
        pollInterval: Duration = .milliseconds(200), takeover: LeaseTable.Takeover? = nil
    ) async throws -> LeaseClaim? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let claim = try await tryAcquire(name, owner: owner, ttl: ttl, holding: holding, takeover: takeover) {
                return claim
            }
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: min(pollInterval, deadline - ContinuousClock.now))
        }
    }

    /// `sync`, then `flush`, in the global order (§5.2 rule 2: rebuild swap and reset). If `flush`
    /// doesn't come within the remaining time, or acquiring it throws (cancellation included),
    /// `sync` is released before returning nil or rethrowing.
    public func acquireSyncThenFlush(owner: String, waitingUpTo timeout: Duration) async throws -> (
        sync: LeaseClaim, flush: LeaseClaim
    )? {
        let start = ContinuousClock.now
        guard let sync = try await acquire(.sync, owner: owner, waitingUpTo: timeout) else { return nil }
        let flush: LeaseClaim?
        do {
            let remaining = max(.zero, timeout - (ContinuousClock.now - start))
            flush = try await acquire(.flush, owner: owner, holding: [sync], waitingUpTo: remaining)
        } catch {
            await releaseUncancellably(sync)
            throw error
        }
        guard let flush else {
            await releaseUncancellably(sync)
            return nil
        }
        return (sync, flush)
    }

    /// Releases `claim` from an unstructured task, so the caller's cancellation can't stop the
    /// cleanup. Errors are dropped: an unreleased lease still expires.
    private func releaseUncancellably(_ claim: LeaseClaim) async {
        let leases = self
        _ = try? await Task { try await leases.release(claim) }.value
    }

    public func renew(_ claim: LeaseClaim, ttl: Duration? = nil) async throws -> Bool {
        let clock = clock
        return try await writer.write { db in try LeaseTable.renew(db, claim, ttl: ttl, at: clock.now()) }
    }

    /// Releases `claim`. `beforeRelease` runs first in the same transaction (the flusher's
    /// "in_flight with my token → uncertain", outbox.md §12).
    public func release(_ claim: LeaseClaim, beforeRelease: (@Sendable (Database) throws -> Void)? = nil) async throws
        -> Bool
    {
        try await writer.write { db in
            try beforeRelease?(db)
            return try LeaseTable.release(db, claim)
        }
    }

    public func record(_ name: LeaseName) async throws -> LeaseRecord {
        try await writer.read { db in try LeaseTable.record(db, name) }
    }

    private func defaultTakeover(_ name: LeaseName) -> LeaseTable.Takeover? {
        guard name == .flush else { return nil }
        let wallClock = wallClock
        return { db, _ in try FlushRecovery.recoverInFlight(db, now: wallClock.now()) }
    }
}
