import Foundation
import GRDB
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(2))) struct SharedDatabaseTests {
    private func open(_ url: URL, notifier: (any ChangeNotifier)? = nil) throws -> DatabasePool {
        try SharedDatabase.openPool(
            at: url, migrations: StoreSchema.migrations, notifier: notifier, commitSignal: .dbChanged)
    }

    @Test func migrationsAreIdempotentAcrossTwoPools() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let url = dir.url.appending(path: "stores/s.g1.sqlite")
        let first = try open(url)
        let second = try open(url)
        try SharedDatabase.migrate(first, StoreSchema.migrations)
        for pool in [first, second] {
            try pool.read { (db: Database) throws in
                #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1"])
                #expect(try StoreSchema.migrator().hasCompletedMigrations(db))
                #expect(try db.tableExists("outbox_item"))
                #expect(try String.fetchAll(db, sql: "SELECT name FROM lease ORDER BY name") == ["flush", "sync"])
            }
        }
        // GRDB's own migrator agrees there is nothing left to do.
        try StoreSchema.migrator().migrate(second)
    }

    @Test func racingMigratorsBothSucceed() async throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let url = dir.url.appending(path: "race.sqlite")
        // Two pools on a file nobody has migrated yet, migrating at once.
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let pools = try (0..<4).map { _ in
            try DatabasePool(path: url.path, configuration: StoreDatabase.configuration(label: "race"))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for pool in pools {
                group.addTask { try SharedDatabase.migrate(pool, StoreSchema.migrations) }
            }
            try await group.waitForAll()
        }
        try await pools[0].read { (db: Database) throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lease") == 2)
        }
    }

    @Test func aNewerSchemaIsRefused() throws {
        let queue = try TestDatabase.store()
        try queue.write { db in try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99')") }
        #expect(throws: StoreError.schemaTooNew(["v99"])) { try SharedDatabase.migrate(queue, StoreSchema.migrations) }
    }

    @Test func registryMigratesTheSameWay() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let url = dir.url.appending(path: "registry.sqlite")
        for _ in 0..<2 {
            let pool = try SharedDatabase.openPool(
                at: url, migrations: RegistrySchema.migrations, notifier: nil, commitSignal: .registryChanged)
            try pool.read { (db: Database) throws in #expect(try RegistrySchema.migrator().hasCompletedMigrations(db)) }
        }
    }

    @Test func walIsPersistentAfterTheLastConnectionCloses() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let url = dir.url.appending(path: "wal.sqlite")
        do {
            let pool = try open(url)
            try pool.write { db in try LocalStore.createSyncState(db, serverId: "s", baseURL: "u") }
            try pool.close()
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: url.path + "-shm"))
        try DatabaseQueue(path: url.path).read { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
        }
    }

    @Test func everyCommittedWritePostsDbChanged() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let notifier = RecordingNotifier()
        let pool = try open(dir.url.appending(path: "n.sqlite"), notifier: notifier)
        let before = notifier.posts.count
        try pool.write { db in try LocalStore.createSyncState(db, serverId: "s", baseURL: "u") }
        #expect(notifier.posts.count == before + 1)
        #expect(notifier.posts.last == .dbChanged)
        // A read, a write that changes nothing and a rollback post nothing.
        _ = try pool.read { (db: Database) throws in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state") }
        try pool.write { db in try db.execute(sql: "UPDATE sync_state SET cursor = 1 WHERE id = 2") }
        try? pool.write { db in
            try db.execute(sql: "UPDATE sync_state SET cursor = 5")
            throw StoreError.retired
        }
        #expect(notifier.posts.count == before + 1)
    }

    @Test func configurationFollowsTheMultiProcessRecipe() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let pool = try open(dir.url.appending(path: "c.sqlite"))
        #expect(pool.configuration.observesSuspensionNotifications)
        if case .timeout = pool.configuration.busyMode {} else { Issue.record("busyMode is not a timeout") }
    }
}

@Suite(.timeLimit(.minutes(2))) struct ChangeSignalTests {
    @Test func darwinNotificationsRoundTrip() async throws {
        let notifier = DarwinNotifier()
        let name = ChangeSignalName(rawValue: "com.bahumia.quickr.test.\(UUID().uuidString)")
        let signals = notifier.signals(name)
        let received = Task {
            for await _ in signals { return true }
            return false
        }
        // Registration is synchronous, so the first post is seen; post a few in case of coalescing.
        for _ in 0..<3 {
            notifier.post(name)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await received.value)
    }

    @Test func refreshSignalForwardsPokesAndNotifications() async throws {
        let notifier = RecordingNotifier()
        let signal = RefreshSignal(notifier: notifier)
        var iterator = signal.stream().makeAsyncIterator()
        signal.poke()
        #expect(await iterator.next() != nil)
        try await Task.sleep(for: .milliseconds(20))  // let the forwarder subscribe
        notifier.post(.dbChanged)
        #expect(await iterator.next() != nil)
    }
}
