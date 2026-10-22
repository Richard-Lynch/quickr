import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import QuickrTestSupport
import Testing

/// Per-server store files, the registry, local reset and its crash recovery (sync-protocol.md
/// §8, §12), file-backed.
@Suite(.timeLimit(.minutes(5))) struct PartitionTests {
    struct Env {
        let dir: TempDirectory
        let clock = FakeLeaseClock()
        let wall = FakeClock()
        let notifier = RecordingNotifier()
        let partitions: StorePartitions

        init() throws {
            dir = try TempDirectory()
            partitions = try StorePartitions.open(
                at: StoreLocation(root: dir.url), leaseClock: clock, wallClock: wall, notifier: notifier)
        }

        /// Another process: its own registry pool over the same files.
        func otherProcess() throws -> StorePartitions {
            try StorePartitions.open(
                at: StoreLocation(root: dir.url), leaseClock: clock, wallClock: wall, notifier: notifier)
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.url.appending(path: relativePath).path)
        }

        /// Steps 2–5 of a reset up to the retire, as SYNC will drive them. Returns the old store
        /// and the persisted intent.
        @discardableResult
        func retire(_ serverId: String) async throws -> (old: LocalStore, intent: RegisteredServer) {
            let old = try await partitions.openStore(serverId: serverId, role: .app).store
            let (count, maxSeq) = try await old.outbox.summary()
            let intent = try await partitions.persistResetIntent(
                store: old, confirmedCount: count, confirmedMaxSeq: maxSeq)
            let pair = try #require(
                try await old.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(60)))
            #expect(
                try await old.retire(confirmedCount: count, confirmedMaxSeq: maxSeq, sync: pair.sync, flush: pair.flush)
                    == .retired)
            _ = try await old.leases.release(pair.flush)
            _ = try await old.leases.release(pair.sync)
            return (old, intent)
        }
    }

    @Test func storesArePartitionedPerServerAndGeneration() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        let a = try await env.partitions.createStore(serverId: "aaa", baseURL: "https://a.example")
        let b = try await env.partitions.createStore(serverId: "bbb", baseURL: "https://b.example")
        #expect(a.url?.lastPathComponent == "aaa.g1.sqlite" && b.url?.lastPathComponent == "bbb.g1.sqlite")
        #expect(env.exists("registry.sqlite") && env.exists("stores/aaa.g1.sqlite"))
        #expect(try await a.syncState.syncState()?.serverId == "aaa")
        #expect(try await b.syncState.syncState()?.baseURL == "https://b.example")

        _ = try await a.outbox.appendRawForTesting(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .app))
        #expect(try await a.outbox.summary().count == 1)
        #expect(try await b.outbox.summary().count == 0)

        // Switching the active server switches the store; items never move.
        #expect(try await env.partitions.openActiveStore(role: .app) == nil)
        try await env.partitions.registry.setActive("bbb")
        #expect(try await env.partitions.openActiveStore(role: .extension)?.store.serverId == "bbb")
        try await env.partitions.registry.setActive("aaa")
        let active = try #require(try await env.partitions.openActiveStore(role: .app)).store
        #expect(active.serverId == "aaa")
        #expect(try await active.outbox.summary().count == 1)
        #expect(try await env.partitions.registry.repository.servers().map(\.id) == ["aaa", "bbb"])

        // Registering again keeps the generation.
        let again = try await env.partitions.createStore(serverId: "aaa", baseURL: "https://a.example")
        #expect(again.storeGen == 1)
        #expect(env.notifier.posts.contains(.registryChanged))
        await #expect(throws: StoreError.unknownServer("zzz")) {
            try await env.partitions.openStore(serverId: "zzz", role: .app)
        }
    }

    @Test func aFullResetMovesToAFreshFile() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        let first = try await env.partitions.createStore(serverId: "s", baseURL: "https://s.example")
        try await first.writer.write { db in
            _ = try ServerLayer.upsert(db, topic: Make.topic())
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', cursor = 9")
        }
        let (old, intent) = try await env.retire("s")
        let new = try await env.partitions.completeReset(intent)
        #expect(new.storeGen == 2 && new.url?.lastPathComponent == "s.g2.sqlite")
        #expect(try await new.syncState.syncState() == SyncState(serverId: "s", baseURL: "https://s.example"))
        #expect(try await new.topics.topics().isEmpty)
        let server = try #require(try await env.partitions.registry.repository.server(id: "s"))
        #expect(server.storeGen == 2 && server.pendingGen == nil && server.pendingConfirmedCount == nil)
        #expect(try await env.partitions.registry.retiredFiles().map(\.path) == ["stores/s.g1.sqlite"])
        // The old pool sees it is retired, and so would any process's enqueue.
        #expect(try await old.isRetired())
        await #expect(throws: StoreError.retired) {
            try await old.outbox.appendRawForTesting(
                NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))
        }
    }

    @Test func writesAfterTheWarningAbortTheReset() async throws {
        // S19 in one process: N = 2 confirmed, a widget enqueues a third before step 4.
        let env = try Env()
        defer { env.dir.cleanup() }
        let store = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        for _ in 0..<2 {
            _ = try await store.outbox.appendRawForTesting(
                NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .app))
        }
        let (count, maxSeq) = try await store.outbox.summary()
        let intent = try await env.partitions.persistResetIntent(
            store: store, confirmedCount: count, confirmedMaxSeq: maxSeq)
        let widget = try await env.otherProcess().openStore(serverId: "s", role: .extension).store
        _ = try await widget.outbox.appendRawForTesting(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))

        let pair = try #require(try await store.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(60)))
        let outcome = try await store.retire(
            confirmedCount: count, confirmedMaxSeq: maxSeq, sync: pair.sync, flush: pair.flush)
        #expect(outcome == .writesArrived(count: 3, maxSeq: 3))
        #expect(try await !store.isRetired())
        #expect(try await env.partitions.abortReset(intent))
        #expect(try await env.partitions.registry.repository.server(id: "s")?.pendingGen == nil)

        // Fewer items (some synced meanwhile) is fine.
        try await store.writer.write { db in _ = try db.execute(sql: "DELETE FROM outbox_item WHERE seq = 1") }
        #expect(
            try await store.retire(confirmedCount: 3, confirmedMaxSeq: 3, sync: pair.sync, flush: pair.flush)
                == .retired)
    }

    @Test func retireIsFencedOnBothLeases() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        let store = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        let sync = try #require(try await store.leases.tryAcquire(.sync, owner: "app:1"))
        #expect(
            try await store.retire(confirmedCount: 0, confirmedMaxSeq: 0, sync: sync, flush: .fake(.flush))
                == .fenced(.lease(.flush)))
        #expect(try await !store.isRetired())
    }

    @Test func recoveryWithAnIntentAndALiveOldFile() async throws {
        // S17: crashed between steps 2 and 4.
        let env = try Env()
        defer { env.dir.cleanup() }
        let store = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        _ = try await env.partitions.persistResetIntent(store: store, confirmedCount: 0, confirmedMaxSeq: 0)

        let other = try env.otherProcess()
        guard case .opened(let extensionStore) = try await other.openStore(serverId: "s", role: .extension) else {
            Issue.record("an extension keeps using the old file")
            return
        }
        #expect(extensionStore.storeGen == 1)
        guard case .resetPending(let appStore, let server) = try await other.openStore(serverId: "s", role: .app) else {
            Issue.record("the app resumes the reset")
            return
        }
        #expect(appStore.storeGen == 1 && server.pendingGen == 2 && server.pendingConfirmedCount == 0)
        #expect(!env.exists("stores/s.g2.sqlite"))
        _ = store
    }

    @Test func recoveryWithAnIntentAndARetiredOldFile() async throws {
        // S18: crashed between steps 4 and 6; any process finishes step 6, idempotently.
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        let token = try #require(try await env.retire("s").intent.pendingToken)

        let widget = try env.otherProcess()
        let opened = try await widget.openStore(serverId: "s", role: .extension)
        guard case .opened(let store) = opened else {
            Issue.record("expected the new file")
            return
        }
        #expect(store.storeGen == 2 && env.exists("stores/s.g2.sqlite"))
        _ = try await store.outbox.appendRawForTesting(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))
        #expect(try await store.syncState.syncState()?.bootstrapComplete == false)

        // The app's later launch doesn't repeat step 6 and lands on the same file and item.
        let app = try await env.partitions.openStore(serverId: "s", role: .app).store
        #expect(app.storeGen == 2)
        #expect(try await app.outbox.summary().count == 1)
        #expect(try await env.partitions.registry.retiredFiles().count == 1)
        #expect(
            try await env.partitions.registry.completeReset(
                serverId: "s", fromGen: 1, toGen: 2, token: token, retiredAtWall: Date(),
                retiredAt: env.clock.now()) == .alreadyAdvanced)
    }

    @Test func recoveryRepairsARegistryPointingAtARetiredFile() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        let store = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        try await store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET retired = 1") }
        let repaired = try await env.partitions.openStore(serverId: "s", role: .extension).store
        #expect(repaired.storeGen == 2)
        #expect(try await !repaired.isRetired())
        #expect(try await env.partitions.registry.retiredFiles().map(\.path) == ["stores/s.g1.sqlite"])
    }

    @Test func recoveryCreatesAMissingFile() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.registry.register(serverId: "s", baseURL: "https://s.example", now: Date())
        #expect(!env.exists("stores/s.g1.sqlite"))
        let store = try await env.partitions.openStore(serverId: "s", role: .extension).store
        #expect(env.exists("stores/s.g1.sqlite"))
        #expect(try await store.syncState.syncState()?.baseURL == "https://s.example")
    }

    @Test func retiredFilesAreDeletedLazily() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        _ = try await env.partitions.completeReset(try await env.retire("s").intent)
        #expect(env.exists("stores/s.g1.sqlite"))

        env.clock.advance(by: .seconds(599))
        #expect(try await env.partitions.deleteRetiredFiles().isEmpty)
        // The wall clock is irrelevant.
        env.wall.advance(by: 86_400)
        #expect(try await env.partitions.deleteRetiredFiles().isEmpty)
        env.clock.advance(by: .seconds(1))
        #expect(try await env.partitions.deleteRetiredFiles() == ["stores/s.g1.sqlite"])
        #expect(!env.exists("stores/s.g1.sqlite") && !env.exists("stores/s.g1.sqlite-wal"))
        #expect(try await env.partitions.registry.retiredFiles().isEmpty)
        #expect(env.exists("stores/s.g2.sqlite"))
    }

    @Test func aRebootMakesRetiredFilesDeletable() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        _ = try await env.partitions.completeReset(try await env.retire("s").intent)
        env.clock.reboot()
        #expect(try await env.partitions.deleteRetiredFiles() == ["stores/s.g1.sqlite"])
    }

    @Test func theLiveFileIsNeverDeleted() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        try await env.partitions.registry.writer.write { db in
            try db.execute(sql: "INSERT INTO retired_file VALUES ('stores/s.g1.sqlite', 0, 'old-boot', 0)")
        }
        #expect(try await env.partitions.deleteRetiredFiles().isEmpty)
        #expect(env.exists("stores/s.g1.sqlite"))
    }

    @Test func aStaleRecoveryNeverCompletesANewerReset() async throws {
        // A inspects g1 (retired, intent g1→g2) and pauses; B completes g1→g2; the app persists a
        // new g2→g3 intent; A resumes with its g1→g2 view and must change nothing.
        let env = try Env()
        defer { env.dir.cleanup() }
        _ = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        let (_, firstIntent) = try await env.retire("s")
        let inspectedByA = try #require(try await env.partitions.registry.repository.server(id: "s"))
        #expect(inspectedByA.storeGen == 1 && inspectedByA.pendingGen == 2)

        let processB = try env.otherProcess()
        let g2 = try await processB.openStore(serverId: "s", role: .extension).store
        #expect(g2.storeGen == 2)
        _ = try await g2.outbox.appendRawForTesting(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))
        let secondIntent = try await env.partitions.persistResetIntent(store: g2, confirmedCount: 1, confirmedMaxSeq: 1)
        #expect(secondIntent.storeGen == 2 && secondIntent.pendingGen == 3)

        // A resumes: step 6 for the generations it inspected.
        let completion = try await env.partitions.registry.completeReset(
            serverId: "s", fromGen: inspectedByA.storeGen, toGen: try #require(inspectedByA.pendingGen),
            token: try #require(inspectedByA.pendingToken), retiredAtWall: Date(), retiredAt: env.clock.now())
        #expect(completion == .superseded)
        await #expect(throws: StoreError.registryChanged("s")) { try await env.partitions.completeReset(firstIntent) }
        // Nor can it abort the newer intent.
        #expect(try await !env.partitions.abortReset(firstIntent))

        let server = try #require(try await env.partitions.registry.repository.server(id: "s"))
        #expect(server.storeGen == 2 && server.pendingGen == 3 && server.pendingConfirmedCount == 1)
        #expect(try await env.partitions.registry.retiredFiles().map(\.path) == ["stores/s.g1.sqlite"])
        // g2 is live and keeps its write; a fresh recovery hands the app the pending reset of g2.
        #expect(try await !g2.isRetired())
        guard case .resetPending(let store, let intent) = try await env.partitions.openStore(serverId: "s", role: .app)
        else {
            Issue.record("expected the g2→g3 reset to be pending")
            return
        }
        #expect(store.storeGen == 2 && intent.pendingGen == 3)
        #expect(try await store.outbox.summary().count == 1)
    }

    @Test func anIntentNeedsTheCurrentGenerationAndNoResetInProgress() async throws {
        let env = try Env()
        defer { env.dir.cleanup() }
        let g1 = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        _ = try await env.partitions.persistResetIntent(store: g1, confirmedCount: 0, confirmedMaxSeq: 0)
        await #expect(throws: StoreError.registryChanged("s")) {
            try await env.partitions.persistResetIntent(store: g1, confirmedCount: 5, confirmedMaxSeq: 5)
        }
        #expect(try await env.partitions.registry.repository.server(id: "s")?.pendingConfirmedCount == 0)
    }

    @Test func aStaleAbortOrCompletionNeverTouchesAReplacementAttempt() async throws {
        // A aborts g1→g2 late: B already aborted it and persisted a fresh g1→g2 attempt.
        let env = try Env()
        defer { env.dir.cleanup() }
        let g1 = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        let first = try await env.partitions.persistResetIntent(store: g1, confirmedCount: 0, confirmedMaxSeq: 0)
        #expect(try await env.partitions.abortReset(first))
        _ = try await g1.outbox.appendRawForTesting(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .app))
        let replacement = try await env.partitions.persistResetIntent(store: g1, confirmedCount: 1, confirmedMaxSeq: 1)
        #expect(replacement.pendingGen == first.pendingGen)
        #expect(replacement.pendingToken != nil && replacement.pendingToken != first.pendingToken)

        // The stale abort is a no-op, and so is a stale completion.
        #expect(try await !env.partitions.abortReset(first))
        await #expect(throws: StoreError.registryChanged("s")) { try await env.partitions.completeReset(first) }
        let server = try #require(try await env.partitions.registry.repository.server(id: "s"))
        #expect(server == replacement)

        // The replacement still runs to completion with its own token.
        let pair = try #require(try await g1.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(60)))
        #expect(
            try await g1.retire(confirmedCount: 1, confirmedMaxSeq: 1, sync: pair.sync, flush: pair.flush) == .retired)
        _ = try await g1.leases.release(pair.flush)
        _ = try await g1.leases.release(pair.sync)
        #expect(try await env.partitions.completeReset(replacement).storeGen == 2)
        #expect(try await env.partitions.registry.repository.server(id: "s")?.pendingToken == nil)
    }
}
