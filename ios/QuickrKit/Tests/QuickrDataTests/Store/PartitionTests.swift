import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Per-server store files, the registry, local reset and its crash recovery (sync-protocol.md
/// §8, §12), file-backed.
@Suite struct PartitionTests {
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

        /// Steps 2–5 of a reset up to the retire, as SYNC will drive them. Returns the old store.
        func retire(_ serverId: String) async throws -> LocalStore {
            let old = try await partitions.openStore(serverId: serverId, role: .app).store
            let (count, maxSeq) = try await old.outbox.summary()
            _ = try await partitions.persistResetIntent(
                serverId: serverId, confirmedCount: count, confirmedMaxSeq: maxSeq)
            let pair = try #require(try await old.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(1)))
            #expect(
                try await old.retire(confirmedCount: count, confirmedMaxSeq: maxSeq, sync: pair.sync, flush: pair.flush)
                    == .retired)
            _ = try await old.leases.release(pair.flush)
            _ = try await old.leases.release(pair.sync)
            return old
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

        _ = try await a.outbox.enqueue(NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .app))
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
        let old = try await env.retire("s")
        let new = try await env.partitions.completeReset(serverId: "s")
        #expect(new.storeGen == 2 && new.url?.lastPathComponent == "s.g2.sqlite")
        #expect(try await new.syncState.syncState() == SyncState(serverId: "s", baseURL: "https://s.example"))
        #expect(try await new.topics.topics().isEmpty)
        let server = try #require(try await env.partitions.registry.repository.server(id: "s"))
        #expect(server.storeGen == 2 && server.pendingGen == nil && server.pendingConfirmedCount == nil)
        #expect(try await env.partitions.registry.retiredFiles().map(\.path) == ["stores/s.g1.sqlite"])
        // The old pool sees it is retired, and so would any process's enqueue.
        #expect(try await old.isRetired())
        await #expect(throws: StoreError.retired) {
            try await old.outbox.enqueue(
                NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))
        }
    }

    @Test func writesAfterTheWarningAbortTheReset() async throws {
        // S19 in one process: N = 2 confirmed, a widget enqueues a third before step 4.
        let env = try Env()
        defer { env.dir.cleanup() }
        let store = try await env.partitions.createStore(serverId: "s", baseURL: "u")
        for _ in 0..<2 {
            _ = try await store.outbox.enqueue(
                NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .app))
        }
        let (count, maxSeq) = try await store.outbox.summary()
        _ = try await env.partitions.persistResetIntent(serverId: "s", confirmedCount: count, confirmedMaxSeq: maxSeq)
        let widget = try await env.otherProcess().openStore(serverId: "s", role: .extension).store
        _ = try await widget.outbox.enqueue(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))

        let pair = try #require(try await store.leases.acquireSyncThenFlush(owner: "app:1", waitingUpTo: .seconds(1)))
        let outcome = try await store.retire(
            confirmedCount: count, confirmedMaxSeq: maxSeq, sync: pair.sync, flush: pair.flush)
        #expect(outcome == .writesArrived(count: 3, maxSeq: 3))
        #expect(try await !store.isRetired())
        try await env.partitions.abortReset(serverId: "s")
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
        _ = try await env.partitions.persistResetIntent(serverId: "s", confirmedCount: 0, confirmedMaxSeq: 0)

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
        _ = try await env.retire("s")

        let widget = try env.otherProcess()
        let opened = try await widget.openStore(serverId: "s", role: .extension)
        guard case .opened(let store) = opened else {
            Issue.record("expected the new file")
            return
        }
        #expect(store.storeGen == 2 && env.exists("stores/s.g2.sqlite"))
        _ = try await store.outbox.enqueue(
            NewOutboxItem(payload: Make.createPayload(topic: Make.topic()), origin: .widget))
        #expect(try await store.syncState.syncState()?.bootstrapComplete == false)

        // The app's later launch doesn't repeat step 6 and lands on the same file and item.
        let app = try await env.partitions.openStore(serverId: "s", role: .app).store
        #expect(app.storeGen == 2)
        #expect(try await app.outbox.summary().count == 1)
        #expect(try await env.partitions.registry.retiredFiles().count == 1)
        #expect(
            try await !env.partitions.registry.completeReset(
                serverId: "s", retiredAtWall: Date(), retiredAt: env.clock.now()))
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
        _ = try await env.retire("s")
        _ = try await env.partitions.completeReset(serverId: "s")
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
        _ = try await env.retire("s")
        _ = try await env.partitions.completeReset(serverId: "s")
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
}
