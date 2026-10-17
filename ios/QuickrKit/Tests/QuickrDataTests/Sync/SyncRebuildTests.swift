import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Epoch rebuilds, takeover and fencing (sync-protocol.md §5, §7, §11; §13 S3–S6, S9, S15, S16,
/// S20), file-backed. Multi-process cases are simulated in one process with a second registry
/// pool per "process" and lease time moved by hand; the real-subprocess versions are the MP stubs.
@Suite(.timeLimit(.minutes(1))) struct SyncRebuildTests {
    static let e2 = "00000000-0000-4000-8000-0000000000e2"
    static let e3 = "00000000-0000-4000-8000-0000000000e3"

    // MARK: - §7 rebuild

    /// S9's coordinator side (unit): the epoch rotates with items queued. The live page's header
    /// starts a rebuild; staging, swap, then a live pull; the outbox is kept, failed items stay
    /// failed, and the flush after the swap resends the rest with the new epoch.
    @Test func s9EpochRotationRebuildsAndKeepsTheOutbox() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let pending = try await store.enqueue(Payloads.create())
        let uncertain = try await store.enqueue(Payloads.update("0f1e2d3c-4b5a-4968-8778-000000000004"))
        try await store.setItemState(uncertain.id, .uncertain)
        let failed = try await store.enqueue(Payloads.create(glasses: 99))
        try await store.writer.write { db in
            try db.execute(
                sql: "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected' WHERE id = ?",
                arguments: [failed.id])
        }
        env.server.rotateEpoch(to: Self.e2)
        env.server.addEntry()
        let requests = env.transport.requests.count
        #expect(await coordinator.sync(reason: .activation) == .synced)
        // Live (header mismatch) → staging from 0 → swap → live from the new cursor.
        #expect(env.afters(from: requests) == [16, 0, 17])
        let state = try await store.state()
        #expect(state.epoch == Self.e2 && state.layerGen == 2 && state.rebuilding == nil && state.cursor == 17)
        #expect(try await store.count("stage_entry") == 0)
        #expect(try await store.count("stage_topic") == 0)
        #expect(try await store.ids("entry") == Set(env.server.liveEntries().keys))
        #expect(try await store.item(pending.id)?.state == .pending)
        #expect(try await store.item(uncertain.id)?.state == .uncertain)
        #expect(try await store.item(failed.id)?.failureReason == .rejected)
        #expect(env.recorder.flushes.last == .afterSwap)
        #expect(env.recorder.events.contains(.layerSwapped(serverId: FakeFeedServer.defaultServerId, layerGen: 2)))
    }

    /// §6a rule 5: `cursor > head` in the same epoch (a restore without `make rotate-epoch`) is
    /// an epoch mismatch. Items whose entity vanished are kept (restore recovery, §7 step 4).
    @Test func restoreWithoutRotationIsDetectedByCursorAboveHead() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let snapshot = env.server.snapshot()
        let lost = env.server.addEntry(glasses: 4)
        for _ in 0..<3 { env.server.addEntry() }
        #expect(await coordinator.sync(reason: .timer) == .synced)
        #expect(try await store.state().cursor == 20)
        let update = try await store.enqueue(Payloads.update(lost))
        env.server.restore(snapshot)
        #expect(await coordinator.sync(reason: .timer) == .synced)
        let state = try await store.state()
        #expect(state.epoch == FakeFeedServer.fixtureEpoch && state.layerGen == 2 && state.cursor == 16)
        #expect(try await store.count("entry", "id = '\(lost)'") == 0)
        #expect(try await store.item(update.id)?.state == .pending)
    }

    /// §7 step 3.2: in-flight items become uncertain and lose their claim (their senders' fences
    /// now fail); a cancelled in-flight create is removed (outbox.md S8); tombstoned entities'
    /// items resolve by the §4.3 table; a landed create is pull-acked.
    @Test func swapResolvesTheWholeOutbox() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let gone = "0f1e2d3c-4b5a-4968-8778-000000000004"
        let inFlight = try await store.enqueue(Payloads.update("0f1e2d3c-4b5a-4968-8778-000000000002"))
        let cancelled = try await store.enqueue(Payloads.create())
        let cancel = try await store.outbox.enqueue(
            NewOutboxItem(
                payload: Payloads.delete(cancelled.id), origin: .app, cancelsCreate: true))
        let doomedUpdate = try await store.enqueue(Payloads.update(gone))
        let landedId = UUID()
        let landed = try await store.enqueue(Payloads.create(), id: landedId)
        try await store.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = 'tok', claim_owner = 'widget:1',
                      claim_layer_gen = 1, claim_epoch = ? WHERE id IN (?, ?)
                    """,
                arguments: [FakeFeedServer.fixtureEpoch, inFlight.id, cancelled.id])
        }
        env.server.rotateEpoch(to: Self.e2)
        env.server.deleteEntry(gone)
        env.server.addEntry(id: landedId)
        #expect(await coordinator.sync(reason: .activation) == .synced)
        let recovered = try #require(try await store.item(inFlight.id))
        #expect(recovered.state == .uncertain && recovered.maybeDelivered && recovered.claimToken == nil)
        #expect(try await store.item(cancelled.id) == nil)
        #expect(try await store.item(cancel.id)?.state == .pending)
        #expect(try await store.item(doomedUpdate.id)?.failureReason == .deletedElsewhere)
        #expect(try await store.item(landed.id) == nil)
        // The old sender's check now fails on layer_gen and its token.
        let sender = SenderContext(
            flush: LeaseClaim(name: .flush, owner: "widget:1", token: "f"), claimToken: "tok", layerGen: 1,
            epoch: FakeFeedServer.fixtureEpoch)
        let failure = try await store.writer.read { db in
            try StoreFence.check(db, sender.conditions(itemId: inFlight.id), at: env.clock.now())
        }
        #expect(failure == .layerGen)
    }

    @Test func swapDropsTopicsTheNewEpochDoesNotHave() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.rotateEpoch(to: Self.e2)
        env.server.deleteTopic(FakeFeedServer.oldHabit)
        #expect(await coordinator.sync(reason: .activation) == .synced)
        #expect(try await store.count("topic", "id = '\(FakeFeedServer.oldHabit)'") == 0)
        #expect(
            env.recorder.events.contains(
                .topicsDeleted(
                    serverId: FakeFeedServer.defaultServerId, topicIds: [UUID(uuidString: FakeFeedServer.oldHabit)!])))
    }

    @Test func forcedRebuildRestagesTheSameEpoch() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        await coordinator.requestRebuild(force: true)
        try await eventually("the forced rebuild swapped") { try await store.state().layerGen == 2 }
        let state = try await store.state()
        #expect(state.epoch == FakeFeedServer.fixtureEpoch && state.cursor == 16 && state.rebuilding == nil)
    }

    // MARK: - S3, S4: takeover

    /// S3 (simulation): coordinator A fetched page P and is suspended past its 60 s lease; B
    /// pulls and rebuilds. When A resumes, its fence fails (token and layer_gen) and **nothing
    /// is written**.
    @Test func s3SuspendedCoordinatorWritesNothingAfterTakeover() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let a = env.coordinator(owner: "app:A")
        let store = try await env.connect(a)
        env.server.addEntry()
        env.gate.arm { $0 == 16 }
        let suspended = Task { await a.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        env.clock.advance(by: .seconds(61))
        env.server.rotateEpoch(to: Self.e2)
        let b = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await b.sync(reason: .activation) == .synced)
        #expect(try await store.state().layerGen == 2)
        let afterB = try await store.fingerprint()
        env.gate.release()
        #expect(await suspended.value == .superseded)
        #expect(try await store.fingerprint() == afterB)
    }

    /// The generation fence alone (mutation target): `layer_gen` moves while A still validly holds
    /// `sync`, so only the `layerGen` condition can reject A's page.
    @Test func livePageIsDiscardedWhenLayerGenMovedUnderAHeldLease() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let added = env.server.addEntry()
        env.gate.arm { $0 == 16 }
        let sync = Task { await coordinator.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        try await store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET layer_gen = layer_gen + 1") }
        let before = try await store.fingerprint()
        env.gate.release()
        #expect(await sync.value == .superseded)
        #expect(try await store.fingerprint() == before)
        #expect(try await store.count("entry", "id = '\(added)'") == 0)
    }

    @Test func stagedPageIsDiscardedWhenLayerGenMovedUnderAHeldLease() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        env.server.rotateEpoch(to: Self.e2)
        env.gate.arm { $0 == 0 }
        let sync = Task { await coordinator.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        #expect(try await store.state().rebuilding == Self.e2)
        try await store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET layer_gen = layer_gen + 1") }
        let before = try await store.fingerprint()
        env.gate.release()
        #expect(await sync.value == .superseded)
        #expect(try await store.fingerprint() == before)
        #expect(try await store.count("stage_entry") == 0)
    }

    /// S4 (simulation): staging for E2 reached `stage_state.cursor = c`, then the coordinator
    /// died holding `sync`. The relaunched coordinator reads `rebuilding` **before any request**,
    /// fetches `after=c` with the staging context, never pulls live or restarts staging, swaps
    /// exactly once, re-reads `sync_state` and pulls live from the new cursor.
    @Test func s4TakeoverResumesStagingBeforeAnyLivePull() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let first = env.coordinator(owner: "app:A", pageLimit: 5)
        let store = try await env.connect(first)
        #expect(try await store.state().cursor == 16)
        env.server.rotateEpoch(to: Self.e2)
        for minute in 0..<30 { env.server.addEntry(minutes: minute) }
        let head = env.server.head
        env.server.intercept { after in after > 20 && after != 16 ? HTTPResponse(status: 503) : nil }
        guard case .failed = await first.sync(reason: .timer) else {
            Issue.record("expected staging to stop")
            return
        }
        let stageCursor = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state")
        }
        let c = try #require(stageCursor)
        #expect(c > 20 && c < head)
        let staged = try await store.count("stage_entry")
        #expect(try await store.state().rebuilding == Self.e2)
        // The process dies holding `sync`: the lease is left behind.
        try await store.writer.write { db in
            _ = try LeaseTable.acquire(db, .sync, owner: "app:dead", at: env.clock.now())
        }
        env.server.intercept(nil)
        let requests = env.transport.requests.count
        let relaunched = env.coordinator(owner: "app:B", partitions: try env.otherProcess(), pageLimit: 5)
        #expect(await relaunched.sync(reason: .launch) == .busy)
        env.clock.advance(by: .seconds(61))
        #expect(await relaunched.sync(reason: .launch) == .synced)
        let afters = env.afters(from: requests)
        #expect(afters.first == c)
        #expect(!afters.contains(16) && !afters.contains(0))
        #expect(afters.last == head && afters.filter { $0 == head }.count == 1)
        #expect(afters.dropLast().allSatisfy { $0 >= c && $0 < head })
        #expect(staged > 0)
        let state = try await store.state()
        #expect(state.layerGen == 2 && state.epoch == Self.e2 && state.cursor == head)
        #expect(env.recorder.events.filter { if case .layerSwapped = $0 { true } else { false } }.count == 1)
        #expect(try await store.ids("entry") == Set(env.server.liveEntries().keys))
    }

    // MARK: - S15

    /// S15: while staging for E2, `startRebuild(E2)` (a staged E2 page, or a flusher's E2 report)
    /// is a no-op; only a page with a different epoch (E3) clears staging and restarts it.
    @Test func s15StartRebuildIsIdempotentForTheSameTarget() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator(pageLimit: 5)
        let store = try await env.connect(coordinator)
        env.server.rotateEpoch(to: Self.e2)
        env.server.intercept { after in after > 10 && after != 16 ? HTTPResponse(status: 503) : nil }
        _ = await coordinator.sync(reason: .timer)
        #expect(try await store.state().rebuilding == Self.e2)
        let staging = try await store.fingerprint()

        // A flusher's E2 report and a repeated start for E2 change nothing.
        let context = try await store.requestContext()
        let claim = try #require(try await store.leases.tryAcquire(.sync, owner: "app:A"))
        let again = try await store.writer.write { db in
            try SyncTransactions.startRebuild(db, target: Self.e2, layerGen: 1, claim: claim, now: env.clock.now())
        }
        #expect(again == .alreadyStaging)
        _ = try await store.leases.release(claim)
        #expect(try await store.fingerprint() == staging)
        try await store.writer.write { db in
            _ = try SyncTransactions.setEpochSuspect(db, conditions: context.conditions, now: env.clock.now())
        }
        #expect(try await store.count("stage_entry") > 0)

        // A staged page for E3 restarts staging from 0.
        env.server.intercept(nil)
        env.server.rotateEpoch(to: Self.e3)
        let requests = env.transport.requests.count
        #expect(await coordinator.sync(reason: .timer) == .synced)
        let afters = env.afters(from: requests)
        #expect(afters.first != 0 && afters.dropFirst().first == 0)
        let state = try await store.state()
        #expect(state.epoch == Self.e3 && state.layerGen == 2 && !state.epochSuspect)
    }

    // MARK: - S16, S20: mismatch signalling

    /// S16 (simulation): a flusher holding `flush` sees 409 `epoch_mismatch`. Its outcome
    /// transaction sets `epoch_suspect`; it releases `flush`, then asks for a run. The coordinator
    /// takes `sync` → `flush` without deadlock, and `epoch_suspect` stays set until the swap.
    @Test func s16FlusherMismatchSignalsTheCoordinatorAfterReleasingFlush() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let flusher = try #require(try await store.leases.tryAcquire(.flush, owner: "widget:F"))
        let context = try await store.requestContext()
        env.server.rotateEpoch(to: Self.e2)
        let failure = try await store.writer.write { db in
            try SyncTransactions.setEpochSuspect(
                db, conditions: context.conditions + [.lease(flusher)], now: env.clock.now())
        }
        #expect(failure == nil)
        #expect(try await store.state().epochSuspect)
        env.gate.arm { $0 == 0 }
        _ = try await store.leases.release(flusher)
        await coordinator.requestRebuild()
        try await env.gate.waitUntilParked()
        #expect(try await store.state().epochSuspect)  // claims stay refused while staging
        env.gate.release()
        try await eventually("the rebuild swapped") { try await store.state().layerGen == 2 }
        #expect(try await !store.state().epochSuspect)
    }

    /// The swap waits for a sender's `flush` (lock order `sync` → `flush`), then proceeds.
    @Test func swapWaitsForALiveSenderToReleaseFlush() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let sender = try #require(try await store.leases.tryAcquire(.flush, owner: "widget:F"))
        env.server.rotateEpoch(to: Self.e2)
        let sync = Task { await coordinator.sync(reason: .activation) }
        try await eventually("staging finished") { try await store.count("stage_entry") > 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await store.state().layerGen == 1)
        _ = try await store.leases.release(sender)
        #expect(await sync.value == .synced)
        #expect(try await store.state().layerGen == 2)
        #expect(try await store.leases.record(.flush).owner == nil)
    }

    @Test func aSwapThatCannotTakeFlushKeepsStagingForTheNextRun() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator { $0.swapFlushWait = .milliseconds(50) }
        let store = try await env.connect(coordinator)
        let sender = try #require(try await store.leases.tryAcquire(.flush, owner: "widget:F"))
        env.server.rotateEpoch(to: Self.e2)
        #expect(await coordinator.sync(reason: .activation) == .failed(.leaseBusy))
        #expect(try await store.state().rebuilding == Self.e2)
        #expect(try await store.count("stage_entry") > 0)
        #expect(try await store.leases.record(.sync).owner == nil)
        _ = try await store.leases.release(sender)
        #expect(await coordinator.sync(reason: .retry) == .synced)
        #expect(try await store.state().layerGen == 2)
    }

    /// S20: an online-only GET under E1 answers with `X-QuickR-Epoch: E2`. The caller discards it
    /// and reports it: `epoch_suspect` is set at once, and the coordinator runs and rebuilds.
    @Test func s20ForeignEpochOnAGetSetsSuspectAndRunsTheCoordinator() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let context = try await store.requestContext()
        env.server.rotateEpoch(to: Self.e2)
        env.gate.arm { _ in true }
        await coordinator.requestRebuild(context: context)
        #expect(try await store.state().epochSuspect)
        try await env.gate.waitUntilParked()
        env.gate.release()
        try await eventually("the rebuild swapped") { try await store.state().epoch == Self.e2 }
        #expect(try await !store.state().epochSuspect)
        // A report from a stale context (before the swap) writes nothing.
        await coordinator.requestRebuild(context: context)
        #expect(try await !store.state().epochSuspect)
    }

    // MARK: - S5, S6: online-only outcomes after a swap

    /// S5: an online-only publish in flight while a swap happens: its response is not applied;
    /// the next pull brings the new version.
    @Test func s5OnlineOnlyResponseAfterASwapIsNotApplied() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let context = try await store.requestContext()  // the publish is sent
        env.server.rotateEpoch(to: Self.e2)
        #expect(await coordinator.sync(reason: .activation) == .synced)  // the swap wins
        env.server.addVersion(topicId: FakeFeedServer.water, number: 2)
        let water = try #require(try await store.topics.topic(id: UUID(uuidString: FakeFeedServer.water)!)).topic
        var published = water
        published.currentVersion = 2
        published.revision = 9
        let response = published
        let outcome = try await store.applyFenced(context) { db in try ServerLayer.upsert(db, topic: response) }
        #expect(outcome == .failure(.layerGen))
        #expect(try await store.topics.topic(id: water.id)?.topic.revision == water.revision)
        #expect(await coordinator.sync(reason: .afterOnlineOnly) == .synced)
        #expect(try await store.versions.version(topicId: water.id, number: 2) != nil)
    }

    /// S6: an online-only topic delete returns 204 after a swap: no tombstone from a stale context.
    @Test func s6StaleTopicDeleteWritesNoTombstone() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let context = try await store.requestContext()
        env.server.rotateEpoch(to: Self.e2)
        #expect(await coordinator.sync(reason: .activation) == .synced)
        let topic = UUID(uuidString: FakeFeedServer.water)!
        let outcome = try await store.applyFenced(context) { db in
            try ServerLayer.applyDeletion(db, kind: .topic, id: topic, topicId: topic, seq: nil)
            return true
        }
        #expect(outcome == .failure(.layerGen))
        #expect(try await store.count("tombstone") == 0)
        #expect(try await store.count("topic", "id = '\(FakeFeedServer.water)'") == 1)
        // A current context applies.
        let current = try await store.requestContext()
        #expect(
            try await store.applyFenced(current) { db in
                try ServerLayer.applyDeletion(db, kind: .topic, id: topic, topicId: topic, seq: nil)
                return true
            } == .success(true))
    }
}
