import Foundation
import GRDB
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Lease primitives (sync-protocol.md §5.3, outbox.md §6) with the fake lease clock.
@Suite(.timeLimit(.minutes(5))) struct LeaseTests {
    @Test(arguments: LeaseName.allCases) func acquireRenewRelease(_ name: LeaseName) async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let claim = try #require(try await leases.tryAcquire(name, owner: "app:1"))
        #expect(claim.owner == "app:1" && claim.name == name)
        // Held: nobody else, not even the same owner, acquires it.
        #expect(try await leases.tryAcquire(name, owner: "widget:1") == nil)
        #expect(try await leases.tryAcquire(name, owner: "app:1") == nil)

        s.clock.advance(by: name.ttl - .seconds(1))
        #expect(try await leases.renew(claim))
        s.clock.advance(by: name.ttl - .seconds(1))  // still inside the renewed TTL
        #expect(try await leases.tryAcquire(name, owner: "widget:1") == nil)

        #expect(try await leases.release(claim))
        let record = try await leases.record(name)
        #expect(record.owner == nil && record.token == nil && record.expires == nil)
        let next = try #require(try await leases.tryAcquire(name, owner: "widget:1"))
        #expect(next.token != claim.token)
    }

    @Test func anExpiredLeaseIsTakenOverAndTheOldHolderIsFenced() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let old = try #require(try await leases.tryAcquire(.sync, owner: "app:1"))
        s.clock.advance(by: .seconds(59))
        #expect(try await leases.tryAcquire(.sync, owner: "app:2") == nil)
        s.clock.advance(by: .seconds(1))  // exactly at expiry: no longer valid
        let new = try #require(try await leases.tryAcquire(.sync, owner: "app:2"))
        #expect(new.token != old.token)
        // The old holder can neither renew nor release, and fails the fence.
        #expect(try await !leases.renew(old))
        #expect(try await !leases.release(old))
        try s.read { (db: Database) throws in
            #expect(try !LeaseTable.holds(db, old, at: s.clock.now()))
            #expect(try LeaseTable.holds(db, new, at: s.clock.now()))
            #expect(try StoreFence.check(db, [.lease(old)], at: s.clock.now()) == .lease(.sync))
        }
    }

    @Test func aLeaseFromAnotherBootHasExpired() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let old = try #require(try await leases.tryAcquire(.flush, owner: "app:1", ttl: .seconds(3600)))
        // After a reboot the counter restarts low, even below the old expiry: still expired.
        s.clock.reboot(bootId: "boot-2", ct: 1)
        #expect(try await !leases.renew(old))
        _ = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
    }

    @Test func wallClockChangesDoNothing() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        _ = try #require(try await leases.tryAcquire(.sync, owner: "app:1"))
        // S11: the wall clock jumps back 3 h, then forward 3 h; lease time doesn't move.
        s.wall.advance(by: -3 * 3600)
        #expect(try await leases.tryAcquire(.sync, owner: "app:2") == nil)
        s.wall.advance(by: 6 * 3600)
        #expect(try await leases.tryAcquire(.sync, owner: "app:2") == nil)
        // Only lease time expires it.
        s.clock.advance(by: .seconds(60))
        #expect(try await leases.tryAcquire(.sync, owner: "app:2") != nil)
    }

    @Test func leaseTimeRunningBackwardWithinABootNeverExtendsAndNeverStrands() async throws {
        // mach_continuous_time is monotonic, but the comparison must still be safe if a stored
        // deadline is far ahead of `now` (another process's longer TTL) or far behind.
        let s = try TestStore()
        let leases = s.store.leases
        let long = try #require(try await leases.tryAcquire(.flush, owner: "app:1", ttl: .seconds(3600)))
        s.clock.advance(by: .seconds(3599))
        #expect(try await leases.tryAcquire(.flush, owner: "widget:1") == nil)
        s.clock.advance(by: .seconds(1))
        #expect(try await leases.tryAcquire(.flush, owner: "widget:1") != nil)
        #expect(try await !leases.renew(long))
    }

    @Test func takingOverFlushRecoversInFlightItems() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let item = try s.enqueue(Make.createPayload(topic: topic))
        let leases = s.store.leases
        _ = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        try s.write { (db: Database) throws in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = 't', claim_owner = 'widget:1',
                      claim_layer_gen = 1, claim_epoch = 'E1', pre_claim_json = '{}', attempts = 2,
                      due_boot_id = 'boot-1', due_ct = 5 WHERE id = ?
                    """,
                arguments: [item.id])
        }
        s.clock.advance(by: .seconds(30))
        _ = try #require(try await leases.tryAcquire(.flush, owner: "app:1"))
        let recovered = try #require(try await s.store.outbox.item(id: item.id))
        #expect(recovered.state == .uncertain && recovered.maybeDelivered)
        #expect(recovered.claimToken == nil && recovered.claimOwner == nil && recovered.claimLayerGen == nil)
        #expect(recovered.claimEpoch == nil && recovered.preClaimJSON == nil && recovered.due == nil)
        #expect(recovered.attempts == 2)
    }

    @Test func aCleanReleaseIsNotATakeover() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let claim = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        #expect(try await leases.release(claim))
        let ran = Flag()
        _ = try #require(try await leases.tryAcquire(.flush, owner: "app:1", takeover: { _, _ in ran.set() }))
        #expect(!ran.value)
        s.clock.advance(by: .seconds(31))
        _ = try #require(
            try await leases.tryAcquire(
                .flush, owner: "app:2",
                takeover: { _, previous in
                    #expect(previous.owner == "app:1")
                    ran.set()
                }))
        #expect(ran.value)
    }

    @Test func waitingAcquirePollsBetweenTransactions() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let held = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        #expect(
            try await leases.acquire(
                .flush, owner: "app:1", waitingUpTo: .milliseconds(50), pollInterval: .milliseconds(10)) == nil)
        let waiter = Task {
            try await leases.acquire(.flush, owner: "app:1", waitingUpTo: .seconds(60), pollInterval: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        // The waiter holds no transaction while it waits, so the holder can release.
        #expect(try await leases.release(held))
        #expect(try await waiter.value?.owner == "app:1")
    }

    @Test func systemLeaseClockIsMonotonicWithAStableBootId() async throws {
        let clock = SystemLeaseClock()
        let first = clock.now()
        try await Task.sleep(for: .milliseconds(5))
        let second = clock.now()
        #expect(!first.bootId.isEmpty)
        #expect(first.bootId == second.bootId)
        #expect(SystemLeaseClock().bootId == first.bootId)
        #expect(second.ct - first.ct >= 4_000_000)
        #expect(first.ct > 0)
    }
}

/// Lease time is read inside the transaction, after `BEGIN IMMEDIATE` has the lock, never before
/// a wait for another writer.
@Suite(.timeLimit(.minutes(5))) struct LeaseTimeSamplingTests {
    /// Runs `operation` while a second connection to `s`'s file holds the write lock. Once the
    /// operation's `BEGIN IMMEDIATE` is waiting for that lock (seen by a statement trace, not
    /// guessed with a sleep), advances the lease clock past every TTL and lets it run.
    ///
    /// The blocking connection parks a thread of its own queue, never one of Swift concurrency's
    /// cooperative pool. The pool is as wide as the CPU count, so on a 3-core CI runner these
    /// tests' blocked writers once took every pool thread, and nothing was left to open their gates.
    private func behindABlockedWriter<T: Sendable>(
        _ s: TestStore, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let path = try #require(s.path, "needs a file-backed store, so a second connection can lock it")
        let other = try DatabaseQueue(path: path, configuration: StoreDatabase.configuration(label: "blocker"))
        let gate = DispatchSemaphore(value: 0)
        let (locked, lock) = AsyncStream<Void>.makeStream()
        let blocker = Task {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                DispatchQueue(label: "LeaseTimeSamplingTests.blocker").async {
                    done.resume(
                        with: Result {
                            try other.write { _ in  // BEGIN IMMEDIATE: holds the write lock until the gate opens
                                lock.yield()
                                gate.wait()
                            }
                        })
                }
            }
        }
        for await _ in locked { break }
        let (waiting, wait) = AsyncStream<Void>.makeStream()
        try await s.writer.writeWithoutTransaction { db in
            // A statement is traced as it starts, before SQLite's busy handler waits for the lock.
            db.trace { event in if "\(event)".hasPrefix("BEGIN IMMEDIATE") { wait.yield() } }
        }
        let queued = Task { try await operation() }
        for await _ in waiting { break }
        s.clock.advance(by: .seconds(61))
        gate.signal()
        try await blocker.value
        return try await queued.value
    }

    /// A store in a file of its own, so `behindABlockedWriter` can lock it from a second connection.
    private func fileStore(_ directory: TempDirectory) -> String {
        directory.url.appending(path: "store.sqlite").path
    }

    @Test func renewalAfterExpiryFails() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let s = try TestStore(path: fileStore(directory))
        let leases = s.store.leases
        let claim = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        #expect(try await !behindABlockedWriter(s) { try await leases.renew(claim) })
        #expect(try await leases.tryAcquire(.flush, owner: "app:2") != nil)
    }

    @Test func ackAfterExpiryIsFenced() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let f = try await AtomicAckTests.Fixture(path: fileStore(directory))
        let store = f.s.store
        let (itemId, sender, effect) = (f.item.id, f.sender, AckEffect.entry(f.acked))
        let outcome = try await behindABlockedWriter(f.s) {
            try await store.ack(itemId: itemId, sender: sender, effect: effect)
        }
        #expect(outcome == .fenced(.lease(.flush)))
        #expect(try await store.outbox.item(id: itemId) != nil)
    }

    @Test func retireAfterExpiryIsFenced() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let s = try TestStore(path: fileStore(directory))
        let store = s.store
        let pair = try #require(try await store.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(60)))
        let outcome = try await behindABlockedWriter(s) {
            try await store.retire(confirmedCount: 0, confirmedMaxSeq: 0, sync: pair.sync, flush: pair.flush)
        }
        #expect(outcome == .fenced(.lease(.sync)))
        #expect(try await !store.isRetired())
    }

    @Test func acquisitionSeesTheTimeAfterTheWait() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let s = try TestStore(path: fileStore(directory))
        let leases = s.store.leases
        _ = try #require(try await leases.tryAcquire(.sync, owner: "app:1"))
        // Sampled before the wait, the old lease would still look valid.
        let claim = try await behindABlockedWriter(s) { try await leases.tryAcquire(.sync, owner: "app:2") }
        #expect(claim?.owner == "app:2")
    }
}

/// The single global lock order: `sync` → `flush` (sync-protocol.md §5.2).
@Suite(.timeLimit(.minutes(5))) struct LockOrderTests {
    @Test func flushHoldersNeverWaitForSync() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let flush = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        await #expect(throws: StoreError.lockOrderViolation(acquiring: .sync, holding: .flush)) {
            try await leases.tryAcquire(.sync, owner: "widget:1", holding: [flush])
        }
        await #expect(throws: StoreError.lockOrderViolation(acquiring: .flush, holding: .flush)) {
            try await leases.acquire(.flush, owner: "widget:1", holding: [flush], waitingUpTo: .seconds(1))
        }
        #expect(throws: Never.self) { try LeaseName.flush.checkLockOrder(holding: [.fake(.sync)]) }
        #expect(LeaseName.allCases.sorted { $0.lockRank < $1.lockRank } == [.sync, .flush])
    }

    @Test func syncThenFlush() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        let pair = try #require(try await leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(1)))
        #expect(pair.sync.name == .sync && pair.flush.name == .flush)
        try s.read { (db: Database) throws in
            #expect(try StoreFence.check(db, [.lease(pair.sync), .lease(pair.flush)], at: s.clock.now()) == nil)
        }
    }

    @Test func aFlushTimeoutReleasesSync() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        _ = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        #expect(try await leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .milliseconds(50)) == nil)
        #expect(try await leases.record(.sync).owner == nil)
    }

    @Test func cancellationWhileWaitingForFlushReleasesSync() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        _ = try #require(try await leases.tryAcquire(.flush, owner: "widget:1"))
        let waiter = Task {
            try await leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(30))
        }
        // Ordering, not timing: the waiter holds sync and waits for flush.
        try await eventually("the waiter holds sync") { try await leases.record(.sync).owner == "app:1" }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await leases.record(.sync).owner == nil)
    }

    @Test func anErrorWhileAcquiringFlushReleasesSync() async throws {
        let s = try TestStore()
        let leases = s.store.leases
        try s.write { (db: Database) throws in try db.execute(sql: "DELETE FROM lease WHERE name = 'flush'") }
        await #expect(throws: StoreError.self) {
            try await leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(1))
        }
        #expect(try await leases.record(.sync).owner == nil)
    }

    @Test func twoCoordinatorsSerialiseWithoutDeadlock() async throws {
        // S13 in one process: a rebuild swap and a reset both take sync → flush.
        let s = try TestStore()
        let leases = s.store.leases
        let order = Flag()
        async let first: Void = {
            let pair = try #require(
                try await leases.acquireSyncThenFlush(owner: "app:rebuild", waitingUpTo: .seconds(60)))
            order.set()
            try await Task.sleep(for: .milliseconds(30))
            _ = try await leases.release(pair.flush)
            _ = try await leases.release(pair.sync)
        }()
        try await Task.sleep(for: .milliseconds(5))
        // Upper bounds only (both acquisitions succeed): generous so a starved CI pool can't
        // time the second out while the first still holds the lease.
        let second = try await leases.acquireSyncThenFlush(owner: "app:reset", waitingUpTo: .seconds(60))
        try await first
        #expect(order.value)
        #expect(second?.sync.owner == "app:reset")
    }
}

/// A thread-safe boolean for closures.
final class Flag: Sendable {
    private let state = Mutex(false)

    var value: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
