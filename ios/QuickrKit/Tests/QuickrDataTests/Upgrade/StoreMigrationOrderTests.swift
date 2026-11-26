import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@_spi(Testing) @testable import QuickrData

/// Review E4 (t2-plan.md "iOS store migrations"): M1's and M3a's store migrations together. They
/// are registered M1 first, because `t2m3_topic_appearance` restarts staging in every server-layer
/// table, M1's `stage_run_closed` included, so it needs `t2m1_run_closed` to have created it. A
/// fresh store ends with both milestones' schema; a store synced by a build before both re-pulls
/// through one rebuild and keeps M1's closed runs.
@Suite(.timeLimit(.minutes(2))) struct StoreMigrationOrderTests {
    static let t2m1 = "t2m1_run_closed"
    static let t2m3 = "t2m3_topic_appearance"
    static let everything = SyncRunTests.everything
    static let runA = SyncRunTests.runA

    static func tables(_ db: Database) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table'
                      AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
                    """))
    }

    static func columns(_ db: Database, _ table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
    }

    /// The registration: the `v` series, then every `t2m1_*`, then every `t2m3_*`.
    @Test func m1IsRegisteredBeforeM3() {
        let ids = StoreSchema.migrations.map(\.identifier)
        let t2 = Array(ids.drop(while: { $0.hasPrefix("v") }))
        #expect(t2 == StoreSchema.t2m1Migrations.map(\.identifier) + StoreSchema.t2m3Migrations.map(\.identifier))
        #expect(t2.firstIndex(of: Self.t2m1)! < t2.firstIndex(of: Self.t2m3)!)
        #expect(
            StoreSchema.serverLayerTables.suffix(StoreSchema.t2m1ServerLayerTables.count)
                == ArraySlice(StoreSchema.t2m1ServerLayerTables))
    }

    /// A fresh store migrates through `t2m1` then `t2m3`: M1's tables in both layers, the
    /// appearance columns on `topic` and `stage_topic`, and every server-layer table's two copies
    /// with the same columns (a swap copies them 1:1).
    @Test func aFreshStoreHasBothMilestonesSchema() throws {
        let queue = try DatabaseQueue()
        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        try queue.read { db in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(applied == StoreSchema.migrations.map(\.identifier))
            #expect(try Self.tables(db) == Set(StoreSchema.tables))
            for table in StoreSchema.t2m1ServerLayerTables {
                #expect(try Self.tables(db).isSuperset(of: [table, "stage_\(table)"]), "\(table)")
            }
            #expect(try Self.columns(db, "run_closed") == ["id", "revision", "closed_at"])
            for table in ["topic", "stage_topic"] {
                #expect(Set(try Self.columns(db, table)).isSuperset(of: ["color", "icon", "tags_json"]), "\(table)")
            }
            for table in StoreSchema.serverLayerTables {
                #expect(try Self.columns(db, table) == Self.columns(db, "stage_\(table)"), "\(table)")
            }
        }
    }

    /// A store synced by a build before both: run tombstones (no markers yet), topics without their
    /// appearance, staging under way in every table. The update migrates `t2m1` (markers, the
    /// fence) then `t2m3` (staging starts over everywhere, M1's `stage_run_closed` too, and the
    /// epoch it has is rebuilt). One sync re-pulls it: the themes show and M1's data is intact.
    @Test func aStoreSyncedBeforeBothRePullsOnceAndKeepsM1sData() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let synced = try await env.connect(coordinator)
        // M1's data on the server: a run, stopped (its entry, then the run's delete row).
        env.server.putRun(try SyncRunTests.openRun())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        env.server.closeRun(Self.runA, entry: try SyncRunTests.stoppedEntry())
        #expect(await coordinator.sync(reason: .requested) == .synced)
        let markers = try await SyncRunTests.markers(synced)
        #expect(markers == [Self.runA: 4, SyncRunTests.aliasA: StoreSchema.closedForever])
        let entries = try await Self.entryRevisions(synced)
        let versions = try await synced.count("topic_version")
        let before = try await synced.state()
        let head = env.server.head

        // As the old build left it: run tombstones instead of markers, no appearance columns, and
        // staging under way (a staged topic, entry and run tombstone, the stage cursor moved).
        try await synced.writer.write { db in
            for (id, _) in markers {
                try db.execute(
                    sql: "INSERT INTO tombstone (kind, id, topic_id, seq) VALUES ('run', ?, ?, ?)",
                    arguments: [id, Self.everything.wireString, head])
            }
            for prefix in ["", "stage_"] {
                try db.execute(sql: "DROP TABLE \(prefix)run_closed")
                for column in ["color", "icon", "tags_json"] {
                    try db.execute(sql: "ALTER TABLE \(prefix)topic DROP COLUMN \(column)")
                }
            }
            try db.execute(sql: "INSERT INTO stage_topic SELECT * FROM topic")
            try db.execute(sql: "INSERT INTO stage_entry SELECT * FROM entry")
            try db.execute(
                sql: "INSERT INTO stage_tombstone (kind, id, topic_id, seq) VALUES ('run', ?, ?, ?)",
                arguments: [Self.runA, Self.everything.wireString, head])
            try db.execute(sql: "UPDATE stage_state SET cursor = ? WHERE id = 1", arguments: [head])
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?)", arguments: [Self.t2m1, Self.t2m3])
        }

        // The updated app (a new process) opens it: both migrations run, in order.
        let partitions = try env.otherProcess()
        let store = try #require(try await partitions.openActiveStore(role: .app)).store
        let state = try await store.state()
        #expect(state.epoch == before.epoch && state.rebuilding == state.epoch && state.cursor == before.cursor)
        #expect(state.layerGen == before.layerGen + 1, "t2m1 moves the fence")
        #expect(try await store.writer.read { db in try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state") } == 0)
        for table in StoreSchema.stageTables {
            #expect(try await store.count(table) == 0, "\(table) starts over")
        }
        #expect(try await SyncRunTests.markers(store) == markers.mapValues { _ in 0 }, "t2m1's markers, live topic")
        #expect(try await store.count("tombstone", "kind = 'run'") == 0)
        for id in AppearanceUpgradeTests.themes.keys {
            #expect(try await store.topics.topic(id: id)?.appearance == .empty, "unthemed before the re-pull")
        }

        // One sync rebuilds the epoch it has: the themes show, and M1's closed run and data stay.
        let relaunched = env.coordinator(owner: "app:B", partitions: partitions)
        #expect(await relaunched.sync(reason: .activation) == .synced)
        #expect(env.server.head == head, "nothing changed on the server")
        let after = try await store.state()
        #expect(after.rebuilding == nil && after.epoch == before.epoch && after.layerGen == state.layerGen + 1)
        #expect(after.cursor == head)
        for (id, theme) in AppearanceUpgradeTests.themes {
            #expect(try await store.topics.topic(id: id)?.appearance == theme, "\(id)")
        }
        // The closed run's marker comes back from the feed at its revision. Its alias's ∞ marker
        // does not: a feed deletion names no aliases and the rebuilt layer never saw the run's
        // alias rows, as in any rebuild from cursor 0 (issue #274).
        #expect(try await SyncRunTests.markers(store) == [Self.runA: try #require(markers[Self.runA])])
        #expect(try await store.count("run") == 0)
        #expect(try await Self.entryRevisions(store) == entries)
        #expect(try await store.count("topic_version") == versions)
    }

    static func entryRevisions(_ store: LocalStore) async throws -> [String: Int] {
        try await store.writer.read { db in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, revision FROM entry").map {
                    ($0["id"] as String, $0["revision"] as Int)
                })
        }
    }
}
