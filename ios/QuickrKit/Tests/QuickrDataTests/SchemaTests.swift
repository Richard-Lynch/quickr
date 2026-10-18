import Foundation
import GRDB
import QuickrData
import QuickrTestSupport
import Testing

@Suite(.timeLimit(.minutes(2))) struct SchemaTests {
    private func tables(_ db: Database) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql:
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'"
            ))
    }

    private func columns(_ db: Database, _ table: String) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }

    @Test func storeMigratorCreatesTheSpecTables() throws {
        let queue = try TestDatabase.store()
        try queue.read { (db: Database) throws in
            #expect(try tables(db) == Set(StoreSchema.tables))
            #expect(
                try columns(db, "outbox_item") == [
                    "seq", "id", "kind", "entity_kind", "entity_id", "topic_id", "payload_json", "base_revision",
                    "state", "maybe_delivered", "attempts", "due_boot_id", "due_ct", "hold_boot_id", "hold_ct",
                    "claim_token", "claim_owner", "claim_layer_gen", "claim_epoch", "pre_claim_json",
                    "failure_reason", "last_error_json", "rebase_count", "cancels_create", "origin", "created_at",
                    "updated_at", "row_version",
                ])
            #expect(try columns(db, "lease") == ["name", "owner", "token", "boot_id", "expires_ct"])
            #expect(try columns(db, "tombstone") == ["kind", "id", "topic_id", "seq"])
            #expect(
                try columns(db, "sync_state") == [
                    "id", "server_id", "base_url", "epoch", "cursor", "head_seen", "layer_gen", "rebuilding",
                    "epoch_suspect", "retired", "identity_mismatch", "last_pull_at", "skew_ms", "skew_measured_at",
                    "bootstrap_complete",
                ])
            for table in StoreSchema.serverLayerTables {
                #expect(try columns(db, "stage_" + table) == columns(db, table), "\(table)")
            }
            #expect(try String.fetchAll(db, sql: "SELECT name FROM lease ORDER BY name") == ["flush", "sync"])
            #expect(try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state WHERE id = 1") == 0)
            #expect(try db.indexes(on: "outbox_item").map(\.name).contains("ix_outbox_entity"))
            #expect(try db.foreignKeys(on: "entry").isEmpty)
        }
    }

    @Test func outboxStateIsChecked() throws {
        let queue = try TestDatabase.store()
        let insert = """
            INSERT INTO outbox_item (id, kind, entity_kind, entity_id, topic_id, payload_json, state, origin,
                                     created_at, updated_at)
            VALUES (?, 'entry.delete', 'entry', 'e', 't', '{}', ?, 'app', 0, 0)
            """
        try queue.write { (db: Database) throws in
            for state in ["held", "pending", "in_flight", "uncertain", "failed"] {
                try db.execute(sql: insert, arguments: [UUID().uuidString, state])
            }
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: ["x", "sent"]) }
            #expect(try Int.fetchAll(db, sql: "SELECT seq FROM outbox_item ORDER BY seq") == [1, 2, 3, 4, 5])
        }
    }

    @Test func registryMigratorCreatesTheSpecTables() throws {
        let queue = try TestDatabase.registry()
        try queue.read { (db: Database) throws in
            #expect(try tables(db) == Set(RegistrySchema.tables))
            #expect(
                try columns(db, "notification_category") == [
                    "id", "server_id", "topic_id", "actions_json", "created_at",
                ])
            #expect(
                try columns(db, "server") == [
                    "server_id", "base_url", "display_name", "store_gen", "created_at", "last_sync_at", "pending_gen",
                    "pending_confirmed_count", "pending_confirmed_max_seq", "pending_token",
                ])
            #expect(
                try columns(db, "retired_file") == ["path", "retired_at_wall", "retired_boot_id", "retired_ct"])
        }
    }

    @Test func migratorsAreIdempotent() throws {
        let queue = try TestDatabase.store()
        try StoreSchema.migrator().migrate(queue)
        #expect(try queue.read { try StoreSchema.migrator().hasCompletedMigrations($0) })
    }

    /// The Swift 6 + GRDB pattern end to end: a file-backed `DatabasePool`, a `Sendable`
    /// repository used from another task.
    @Test func poolAndSendableRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = try StoreDatabase.openPool(at: directory.appendingPathComponent("stores/s.g1.sqlite"))
        let repository: any SyncStateRepository = GRDBSyncStateRepository(reader: pool)
        #expect(try await repository.syncState() == nil)

        try await pool.write { db in
            try db.execute(
                sql:
                    "INSERT INTO sync_state (id, server_id, base_url, epoch, cursor, last_pull_at) VALUES (1, ?, ?, ?, ?, ?)",
                arguments: ["srv", "http://localhost:8000", "E1", 16, 1_780_315_200.5])
        }
        let state = try await Task.detached { try await repository.syncState() }.value
        #expect(state?.serverId == "srv" && state?.epoch == "E1" && state?.cursor == 16 && state?.layerGen == 1)
        #expect(state?.lastPullAt == Date(timeIntervalSince1970: 1_780_315_200.5))
        #expect(state?.retired == false && state?.bootstrapComplete == false)
    }
}
