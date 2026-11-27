import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// UPG for `t2m3_topic_appearance` (appearance.md §8), the `UpgradeTests` way: a store synced by a
/// build before it has its topics without their appearance, though the server has themed them
/// (on another device). Nothing re-sends a topic whose own fields don't change, so the migration
/// resets the feed cursor through a rebuild, as v2 did, and the next sync brings the themes.
@Suite(.timeLimit(.minutes(2))) struct AppearanceUpgradeTests {
    static let everything = UUID(uuidString: FakeFeedServer.everything)!
    static let oldHabit = UUID(uuidString: FakeFeedServer.oldHabit)!
    static let water = UUID(uuidString: FakeFeedServer.water)!
    static let identifier = "t2m3_topic_appearance"

    /// The topics the server holds, themed before this device's update (the bootstrap fixture).
    static let themes: [UUID: TopicAppearance] = [
        everything: TopicAppearance(color: .teal, icon: .emoji("🧪"), tags: ["Health"]),
        oldHabit: TopicAppearance(color: .amber, tags: ["Habit", "health"]),
        water: .empty,
    ]

    @Test func registeredAfterTheVSeries() {
        #expect(StoreSchema.migrations.contains { $0.identifier == Self.identifier })
        #expect(StoreSchema.migrations.last?.identifier.hasPrefix("t2m") == true)
    }

    /// The topics are unchanged on the server since this device synced them; the update's
    /// migration starts a rebuild of the epoch it has and the next sync shows their themes.
    @Test func aStoreSyncedBeforeT2M3RebuildsAndShowsTheThemes() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let synced = try await env.connect(env.coordinator())
        let head = env.server.head
        // As the old build left it: no appearance columns, the migration not run.
        try await synced.writer.write { db in
            for prefix in ["", "stage_"] {
                for column in ["color", "icon", "tags_json"] {
                    try db.execute(sql: "ALTER TABLE \(prefix)topic DROP COLUMN \(column)")
                }
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [Self.identifier])
        }

        // The updated app (a new process) opens it: the migration runs and asks for a rebuild.
        let partitions = try env.otherProcess()
        let store = try #require(try await partitions.openActiveStore(role: .app)).store
        let state = try await store.state()
        #expect(state.epoch != nil && state.rebuilding == state.epoch && state.cursor == head)
        for id in Self.themes.keys {
            #expect(try await store.topics.topic(id: id)?.appearance == .empty, "unthemed before the re-pull")
        }
        #expect(env.server.head == head, "nothing changed on the server")

        let relaunched = env.coordinator(owner: "app:B", partitions: partitions)
        #expect(await relaunched.sync(reason: .activation) == .synced)
        let after = try await store.state()
        #expect(after.rebuilding == nil && after.epoch == state.epoch && after.layerGen == state.layerGen + 1)
        for (id, theme) in Self.themes {
            #expect(try await store.topics.topic(id: id)?.appearance == theme, "\(id)")
        }
        #expect(Set(try await store.topics.topics().map(\.appearance)) == Set(Self.themes.values))
    }

    /// On a real v1…v6 file mid-rebuild: the columns default to unthemed, staging starts over, and
    /// the rebuild already under way keeps its target.
    @Test func onAStoreMidRebuildStagingRestartsAndTheTargetStays() throws {
        let queue = try DatabaseQueue()
        let vSeries = StoreSchema.migrations.filter { $0.identifier.hasPrefix("v") }
        try SharedDatabase.migrate(queue, vSeries)
        let topic = Make.topic()
        try queue.write { db in
            try LocalStore.createSyncState(db, serverId: "s", baseURL: "https://q.example")
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', rebuilding = 'E2', cursor = 30 WHERE id = 1")
            try db.execute(sql: "UPDATE stage_state SET cursor = 12 WHERE id = 1")
            for prefix in ["", "stage_"] {
                try db.execute(
                    sql: """
                        INSERT INTO \(prefix)topic (id, slug, name, status, current_version, revision,
                          question_count, created_at, updated_at, questions_json)
                        VALUES (?, 'mood', 'Mood', 'active', 1, 1, 0, 0, 0, '[]')
                        """,
                    arguments: [topic.id.wireString])
            }
        }

        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        try queue.read { db in
            for table in StoreSchema.stageTables {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
            }
            #expect(try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state") == 0)
            let state = try #require(try Row.fetchOne(db, sql: "SELECT rebuilding, epoch, cursor FROM sync_state"))
            #expect(state["rebuilding"] as String? == "E2")
            #expect(state["epoch"] as String? == "E1")
            #expect(state["cursor"] as Int == 30)
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM topic"))
            #expect(try TopicAppearance(serverRow: row) == .empty)
            #expect(row["tags_json"] as String == "[]")
        }
    }

    /// A store that never synced has nothing to re-pull.
    @Test func aStoreWithNoEpochDoesNotRebuild() throws {
        let queue = try DatabaseQueue()
        try SharedDatabase.migrate(queue, StoreSchema.migrations.filter { $0.identifier.hasPrefix("v") })
        try queue.write { db in try LocalStore.createSyncState(db, serverId: "s", baseURL: "https://q.example") }
        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT rebuilding FROM sync_state") } == nil)
    }

    /// Both layers end with the same columns, so a swap's `INSERT … SELECT *` still copies 1:1.
    @Test func bothLayersKeepTheSameColumns() throws {
        let queue = try DatabaseQueue()
        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        try queue.read { db in
            let columns = { (table: String) throws -> [String] in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
            }
            let live = try columns("topic")
            let staged = try columns("stage_topic")
            #expect(live == staged)
            #expect(Set(live).isSuperset(of: ["color", "icon", "tags_json"]))
        }
    }
}
