import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Local reset and its crash recovery, driven by the coordinator over STORE's registry primitives
/// (sync-protocol.md §12; §13 S7, S11–S13, S17–S19), file-backed. "Another process" is a second
/// registry pool over the same files.
@Suite(.timeLimit(.minutes(1))) struct SyncResetTests {
    static let serverId = FakeFeedServer.defaultServerId

    @Test func resetReplacesTheStoreWithAFreshBootstrappedFile() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let old = try await env.connect(coordinator)
        try await old.enqueue(Payloads.create())
        try await old.enqueue(Payloads.create())
        let failed = try await old.enqueue(Payloads.create())
        try await old.setItemState(failed.id, .failed)
        let warning = try #require(try await coordinator.resetWarning())
        #expect(warning.count == 3 && warning.failedCount == 1 && warning.needsDestructiveConfirmation)
        #expect(try await coordinator.performReset(confirmed: warning) == .completed(storeGen: 2, bootstrap: .synced))

        #expect(try await old.isRetired())
        let server = try #require(try await env.partitions.registry.repository.server(id: Self.serverId))
        #expect(server.storeGen == 2 && server.pendingGen == nil)
        let fresh = try await env.activeStore()
        #expect(fresh.storeGen == 2 && fresh.url?.lastPathComponent == "\(Self.serverId).g2.sqlite")
        let state = try await fresh.state()
        #expect(state.cursor == 16 && state.bootstrapComplete && !state.retired)
        #expect(try await fresh.outbox.summary().count == 0)
        #expect(try await fresh.ids("entry") == Set(env.server.liveEntries().keys))
        #expect(env.recorder.events.contains(.storeReset(serverId: Self.serverId, storeGen: 2)))
        #expect(try await env.partitions.registry.retiredFiles().map(\.path) == ["stores/\(Self.serverId).g1.sqlite"])
        // Step 9: the old file goes once it has been retired for 10 minutes of lease time.
        env.clock.advance(by: .seconds(601))
        #expect(await coordinator.sync(reason: .timer) == .synced)
        #expect(!FileManager.default.fileExists(atPath: try #require(old.url).path))
        #expect(coordinator.status.activity == .idle)
    }

    @Test func anEmptyOutboxNeedsOneConfirmation() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        let warning = try #require(try await coordinator.resetWarning())
        #expect(warning.count == 0 && warning.maxSeq == 0 && !warning.needsDestructiveConfirmation)
    }

    /// S19: the user confirmed N=2; a widget enqueues a third before step 4. The re-check sees
    /// 3 > 2: the reset aborts, nothing is retired, the intent is cleared, and the warning comes
    /// back with N=3.
    @Test func s19WritesAfterTheWarningAbortTheReset() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        try await store.enqueue(Payloads.create())
        try await store.enqueue(Payloads.create())
        let warning = try #require(try await coordinator.resetWarning())
        #expect(warning.count == 2)
        let widget = try await env.otherProcess().openStore(serverId: Self.serverId, role: .extension).store
        try await widget.enqueue(Payloads.create())
        let outcome = try await coordinator.performReset(confirmed: warning)
        guard case .writesArrived(let again) = outcome else {
            Issue.record("expected the reset to abort, got \(outcome)")
            return
        }
        #expect(again.count == 3)
        #expect(try await !store.isRetired())
        let server = try #require(try await env.partitions.registry.repository.server(id: Self.serverId))
        #expect(server.storeGen == 1 && server.pendingGen == nil)
        // Fewer items (some synced meanwhile) is fine.
        let items = try await store.outbox.items()
        try await store.writer.write { db in _ = try OutboxStorage.delete(db, id: items[0].id) }
        #expect(try await coordinator.performReset(confirmed: again) == .completed(storeGen: 2, bootstrap: .synced))
    }

    @Test func aStaleWarningIsSuperseded() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        var warning = try #require(try await coordinator.resetWarning())
        warning.storeGen = 7
        #expect(try await coordinator.performReset(confirmed: warning) == .superseded)
    }

    @Test func aResetThatCannotTakeTheLeasesTimesOutAndClearsTheIntent() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator { $0.resetLeaseWait = .milliseconds(50) }
        let store = try await env.connect(coordinator)
        let sender = try #require(try await store.leases.tryAcquire(.flush, owner: "widget:F"))
        let warning = try #require(try await coordinator.resetWarning())
        #expect(try await coordinator.performReset(confirmed: warning) == .timedOut)
        #expect(try await env.partitions.registry.repository.server(id: Self.serverId)?.pendingGen == nil)
        #expect(try await !store.isRetired())
        #expect(try await store.leases.record(.sync).owner == nil)
        _ = try await store.leases.release(sender)
    }

    /// S17 (simulation): the intent is persisted (step 2) and the app dies before step 4. On
    /// relaunch, recovery resumes at step 3, re-checks against the persisted count, retires and
    /// advances; the registry never points at a retired file.
    @Test func s17RelaunchResumesAResetInterruptedBeforeTheRetire() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.connect(env.coordinator())
        try await old.enqueue(Payloads.create())
        let (count, maxSeq) = try await old.outbox.summary()
        _ = try await env.partitions.persistResetIntent(store: old, confirmedCount: count, confirmedMaxSeq: maxSeq)

        // An extension meanwhile keeps using the old file.
        let widget = try await env.otherProcess().openStore(serverId: Self.serverId, role: .extension).store
        #expect(widget.storeGen == 1)

        let relaunched = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await relaunched.bootstrapIfNeeded() == .synced)
        #expect(await relaunched.resumedReset == .completed(storeGen: 2, bootstrap: .synced))
        #expect(try await old.isRetired())
        let fresh = try await env.activeStore()
        #expect(fresh.storeGen == 2)
        #expect(try await !fresh.isRetired())
        #expect(try await fresh.state().bootstrapComplete)
        #expect(try await env.partitions.registry.repository.server(id: Self.serverId)?.pendingGen == nil)
    }

    /// S17's re-check uses the persisted count: an item enqueued after the intent aborts it.
    @Test func s17ResumeAbortsWhenWritesArrivedAfterTheIntent() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.connect(env.coordinator())
        _ = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        try await old.enqueue(Payloads.create())
        let relaunched = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await relaunched.bootstrapIfNeeded() == .synced)
        guard case .writesArrived(let warning) = await relaunched.resumedReset else {
            Issue.record("expected the resumed reset to abort")
            return
        }
        #expect(warning.count == 1)
        #expect(try await !old.isRetired())
        #expect(try await env.activeStore().storeGen == 1)
    }

    /// S18 (simulation): the old file is retired (step 4) and the app dies before step 6. A
    /// widget opening the store completes step 6 itself, opens the new empty file, and its
    /// enqueue lands there. A later app launch bootstraps the file and doesn't repeat step 6.
    @Test func s18WidgetCompletesTheAdvanceAndTheAppBootstrapsTheNewFile() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.connect(env.coordinator())
        let intent = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        let pair = try #require(try await old.leases.acquireSyncThenFlush(owner: "app:A", waitingUpTo: .seconds(1)))
        #expect(
            try await old.retire(
                confirmedCount: intent.pendingConfirmedCount ?? 0,
                confirmedMaxSeq: intent.pendingConfirmedMaxSeq ?? 0, sync: pair.sync, flush: pair.flush) == .retired)
        // The app dies here, holding both leases on the retired file.

        let widget = try await env.otherProcess().openStore(serverId: Self.serverId, role: .extension).store
        #expect(widget.storeGen == 2)
        let item = try await widget.enqueue(Payloads.create())
        #expect(try await !widget.state().bootstrapComplete)

        let app = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        #expect(await app.bootstrapIfNeeded() == .synced)
        let store = try await env.activeStore()
        #expect(store.storeGen == 2)
        let state = try await store.state()
        #expect(state.bootstrapComplete && state.cursor == 16)
        #expect(try await store.item(item.id)?.state == .pending)
        #expect(try await env.partitions.registry.repository.server(id: Self.serverId)?.storeGen == 2)
    }

    /// S7 (simulation): extension pools are open on g1 during a reset. Their next transaction
    /// sees the retired flag, they reopen g2, and a widget write lands in g2. g1 is deleted
    /// after 10 minutes.
    @Test func s7OpenExtensionPoolsReopenAfterAReset() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        let widgetProcess = try env.otherProcess()
        let widgetPool = try await widgetProcess.openStore(serverId: Self.serverId, role: .extension).store
        let nsePool = try await env.otherProcess().openStore(serverId: Self.serverId, role: .extension).store
        let warning = try #require(try await coordinator.resetWarning())
        #expect(try await coordinator.performReset(confirmed: warning) == .completed(storeGen: 2, bootstrap: .synced))
        #expect(try await widgetPool.isRetired())
        #expect(try await nsePool.isRetired())
        let reopened = try await widgetProcess.openStore(serverId: Self.serverId, role: .extension).store
        #expect(reopened.storeGen == 2)
        let item = try await reopened.enqueue(Payloads.create())
        #expect(try await env.activeStore().item(item.id) != nil)
        #expect(try await widgetPool.item(item.id) == nil)
        env.clock.advance(by: .seconds(601))
        #expect(try await env.partitions.deleteRetiredFiles() == ["stores/\(Self.serverId).g1.sqlite"])
    }

    /// S13 (simulation): a rebuild and a reset requested together both take `sync` then `flush`;
    /// they run one after the other without deadlock.
    @Test func s13RebuildAndResetRunOneAfterTheOther() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let a = env.coordinator(owner: "app:A")
        let store = try await env.connect(a)
        env.server.rotateEpoch(to: SyncRebuildTests.e2)
        env.gate.arm { $0 == 0 }
        let rebuild = Task { await a.sync(reason: .activation) }
        try await env.gate.waitUntilParked()
        let b = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        let warning = try #require(try await b.resetWarning())
        let reset = Task { try await b.performReset(confirmed: warning) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await !store.isRetired())  // the reset waits for `sync`
        env.gate.release()
        #expect(await rebuild.value == .synced)
        #expect(try await reset.value == .completed(storeGen: 2, bootstrap: .synced))
        #expect(try await store.state().layerGen == 2)
        #expect(try await store.isRetired())
        #expect(try await env.activeStore().state().epoch == SyncRebuildTests.e2)
    }

    /// The same coordinator: a reset stops its own running loop at the next step.
    @Test func aResetStopsTheCoordinatorsOwnRun() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        env.server.addEntry()
        env.gate.arm { $0 == 16 }
        let sync = Task { await coordinator.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        let warning = try #require(try await coordinator.resetWarning())
        let reset = Task { try await coordinator.performReset(confirmed: warning) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await coordinator.sync(reason: .pullToRefresh) == .resetInProgress)
        env.gate.release()
        _ = await sync.value
        #expect(try await reset.value == .completed(storeGen: 2, bootstrap: .synced))
        #expect(try await env.activeStore().state().cursor == 17)
    }

    // MARK: - Leases (S11, S12)

    /// S12: a `sync` lease left from a previous boot has expired; the coordinator takes it at once.
    @Test func s12ALeaseFromAPreviousBootIsTakenImmediately() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        try await store.writer.write { db in
            _ = try LeaseTable.acquire(db, .sync, owner: "app:old", at: env.clock.now())
        }
        #expect(await coordinator.sync(reason: .launch) == .busy)
        env.clock.reboot(bootId: "boot-2", ct: 5)
        #expect(await coordinator.sync(reason: .launch) == .synced)
    }

    /// S11 (simulation): moving the wall clock 3 h back, then forward, while A holds `sync`
    /// neither frees the lease early nor strands it.
    @Test func s11WallClockChangesDoNotAffectTheSyncLease() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let a = env.coordinator(owner: "app:A")
        try await env.connect(a)
        env.gate.arm { _ in true }
        let held = Task { await a.sync(reason: .timer) }
        try await env.gate.waitUntilParked()
        let b = env.coordinator(owner: "app:B", partitions: try env.otherProcess())
        env.wall.advance(by: -3 * 3600)
        #expect(await b.sync(reason: .timer) == .busy)
        env.wall.advance(by: 6 * 3600)
        #expect(await b.sync(reason: .timer) == .busy)
        env.gate.release()
        #expect(await held.value == .synced)
        #expect(await b.sync(reason: .timer) == .synced)
    }
}
