import Foundation
import GRDB
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// Lease primitives (sync-protocol.md §5.3, outbox.md §6) with the fake lease clock.
@Suite struct LeaseTests {
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
            try await leases.acquire(.flush, owner: "app:1", waitingUpTo: .seconds(5), pollInterval: .milliseconds(10))
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

/// The single global lock order: `sync` → `flush` (sync-protocol.md §5.2).
@Suite struct LockOrderTests {
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

    @Test func twoCoordinatorsSerialiseWithoutDeadlock() async throws {
        // S13 in one process: a rebuild swap and a reset both take sync → flush.
        let s = try TestStore()
        let leases = s.store.leases
        let order = Flag()
        async let first: Void = {
            let pair = try #require(
                try await leases.acquireSyncThenFlush(owner: "app:rebuild", waitingUpTo: .seconds(5)))
            order.set()
            try await Task.sleep(for: .milliseconds(30))
            _ = try await leases.release(pair.flush)
            _ = try await leases.release(pair.sync)
        }()
        try await Task.sleep(for: .milliseconds(5))
        let second = try await leases.acquireSyncThenFlush(owner: "app:reset", waitingUpTo: .seconds(5))
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
