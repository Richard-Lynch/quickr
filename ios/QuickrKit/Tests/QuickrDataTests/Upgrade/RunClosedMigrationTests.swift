import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// R27 (timers2.md §5.2, §12.3): the `t2m1_run_closed` store migration, applied directly on a
/// store at the shipped `v` series (its registration in `StoreSchema.migrations` is the merger's,
/// t2-plan.md "iOS store migrations"). Run tombstones become closed markers (0 under a live topic,
/// ∞ under a tombstoned one) and are deleted, on the live and stage tables; `layer_gen` moves, so
/// an outcome claimed before the migration fails the §5.5 fence; the item re-sent after it acks
/// under the marker rules.
@Suite(.timeLimit(.minutes(5))) struct RunClosedMigrationTests {
    static let liveTopic = "00000000-0000-4000-8000-0000000000a1"
    static let deadTopic = "00000000-0000-4000-8000-0000000000a2"
    static let runLive = "0a000000-0000-4000-8000-000000000003"
    static let aliasLive = "0a000000-0000-4000-8000-0000000000a3"
    static let runDead = "0a000000-0000-4000-8000-0000000000a4"
    static let stagedLive = "0a000000-0000-4000-8000-0000000000a5"
    static let stagedDead = "0a000000-0000-4000-8000-0000000000a6"

    /// The shipped series, whatever else is registered after it.
    static var shipped: [(identifier: String, statements: [String])] {
        StoreSchema.migrations.filter { $0.identifier.hasPrefix("v") }
    }

    /// A store at the `v` series with run tombstones in both layers, synced (`E1`, layer 1), and a
    /// `run.event` item of `runLive` claimed in flight by `app:1` with `flush` held.
    struct Fixture {
        let store: LocalStore
        let item: OutboxItem
        let sender: SenderContext
        let wall: FakeClock

        init() async throws {
            let queue = try DatabaseQueue(configuration: StoreDatabase.configuration(label: "t2m1-migration"))
            try SharedDatabase.migrate(queue, RunClosedMigrationTests.shipped)
            try await queue.write { db in
                try LocalStore.createSyncState(db, serverId: "server-1", baseURL: "https://q.example")
                try db.execute(sql: "UPDATE sync_state SET epoch = 'E1'")
                for prefix in ["", "stage_"] {
                    try db.execute(
                        sql: """
                            INSERT INTO \(prefix)tombstone (kind, id, topic_id, seq)
                            VALUES ('topic', ?, ?, 1), ('entry', 'e1', ?, 2)
                            """,
                        arguments: [deadTopic, deadTopic, liveTopic])
                }
                try db.execute(
                    sql: """
                        INSERT INTO tombstone (kind, id, topic_id, seq)
                        VALUES ('run', ?, ?, 3), ('run', ?, ?, 3), ('run', ?, ?, 4)
                        """,
                    arguments: [runLive, liveTopic, aliasLive, liveTopic, runDead, deadTopic])
                try db.execute(
                    sql: "INSERT INTO stage_tombstone (kind, id, topic_id, seq) VALUES ('run', ?, ?, 5), ('run', ?, ?, 6)",
                    arguments: [stagedLive, liveTopic, stagedDead, deadTopic])
            }
            wall = FakeClock(Make.t0)
            store = LocalStore(
                serverId: "server-1", storeGen: 1, url: nil, writer: queue, leaseClock: FakeLeaseClock(), wallClock: wall)
            let flush = try #require(try await store.leases.tryAcquire(.flush, owner: "app:1"))
            let topic = TopicRef(id: UUID(uuidString: liveTopic)!, slug: "walk", name: "Walk")
            let event = RunEventInDTO(id: UUID().wireString, type: "lap", at: "2026-03-04T12:00:00.000000Z", seg: 0)
            item = try await store.writer.write { db in
                try OutboxStorage.append(
                    db,
                    NewOutboxItem(
                        payload: .runEvent(RunEventPayload(topic: topic, runId: runLive, event: event)), origin: .app),
                    now: Make.t0)
            }
            let token = "claim-1"
            try await store.writer.write { [item] db in
                try db.execute(
                    sql: """
                        UPDATE outbox_item SET state = 'in_flight', claim_token = ?, claim_owner = 'app:1',
                          claim_layer_gen = 1, claim_epoch = 'E1', attempts = 1 WHERE id = ?
                        """,
                    arguments: [token, item.id])
            }
            sender = SenderContext(flush: flush, claimToken: token, layerGen: 1, epoch: "E1")
        }

        /// Runs `t2m1_run_closed` alone, in one transaction, as the migrator would.
        func migrate() throws {
            try store.writer.write { db in
                for statement in StoreSchema.t2m1RunClosed { try db.execute(sql: statement) }
            }
        }

        func markers(_ prefix: String = "") throws -> [String: Int] {
            try store.writer.read { db in
                Dictionary(
                    uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, revision FROM \(prefix)run_closed").map {
                        ($0["id"] as String, $0["revision"] as Int)
                    })
            }
        }

        func tombstones(_ prefix: String = "") throws -> Set<String> {
            try store.writer.read { db in
                Set(try String.fetchAll(db, sql: "SELECT kind || ':' || id FROM \(prefix)tombstone"))
            }
        }
    }

    @Test func itIsRegisteredAsT2M1sOwn() {
        #expect(StoreSchema.t2m1Migrations.map(\.identifier) == ["t2m1_run_closed"])
        #expect(StoreSchema.t2m1ServerLayerTables == ["run_closed"])
    }

    /// Run tombstones become markers, 0 under a live topic and ∞ under a tombstoned one, and are
    /// deleted, in both layers; other tombstones stay.
    @Test func runTombstonesBecomeMarkers() async throws {
        let f = try await Fixture()
        try f.migrate()
        let forever = StoreSchema.closedForever
        #expect(try f.markers() == [Self.runLive: 0, Self.aliasLive: 0, Self.runDead: forever])
        #expect(try f.markers("stage_") == [Self.stagedLive: 0, Self.stagedDead: forever])
        for prefix in ["", "stage_"] {
            #expect(try f.tombstones(prefix) == ["topic:\(Self.deadTopic)", "entry:e1"], "\(prefix)")
        }
        // `closed_at` is the migration's wall clock, in the text the prune reads: kept for 30 days.
        let closedAt = try await f.store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT closed_at FROM run_closed")
        }
        let stamp = try #require(closedAt.flatMap(WireDate.parse))
        #expect(abs(stamp.timeIntervalSinceNow) < 600)
        try await f.store.writer.write { db in
            try ServerLayer.pruneClosedMarkers(db, wall: Date().addingTimeInterval(29 * 86_400))
        }
        #expect(try f.markers().count == 3)
        try await f.store.writer.write { db in
            try ServerLayer.pruneClosedMarkers(db, wall: Date().addingTimeInterval(31 * 86_400))
        }
        #expect(try f.markers().isEmpty)
    }

    /// The migration moves `layer_gen`: an outcome of a request claimed before it fails the fence
    /// and is discarded entirely. Expiry recovery makes the item uncertain; re-sent after the
    /// migration, its ack obeys the marker rules: a lap's ack (an open run) never reopens the run
    /// the migration closed at 0, while an applied reopen's does.
    @Test func aRequestFromBeforeTheMigrationIsFencedAndItsResendObeysTheMarkers() async throws {
        let f = try await Fixture()
        try f.migrate()
        #expect(try await f.store.state().layerGen == 2)
        let reopen = try RunSyncTests.result("recordRunEvent.reopen")
        let before = try await f.store.ack(
            itemId: f.item.id, sender: f.sender, effect: .runEvent(reopen, runId: reopen.run.id))
        #expect(before == .fenced(.layerGen))
        #expect(try await f.store.outbox.item(id: f.item.id)?.state == .inFlight)

        // Expiry recovery (outbox.md §6.3), then the re-send's claim under the new generation.
        try await f.store.writer.write { db in try OutboxSyncEffects.recoverExpiredFlush(db, now: Make.t0) }
        let recovered = try #require(try await f.store.outbox.item(id: f.item.id))
        #expect(recovered.state == .uncertain && recovered.maybeDelivered)
        try await f.store.writer.write { [item = f.item] db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = 'claim-2', claim_owner = 'app:1',
                      claim_layer_gen = 2, claim_epoch = 'E1' WHERE id = ?
                    """,
                arguments: [item.id])
        }
        let resent = SenderContext(flush: f.sender.flush, claimToken: "claim-2", layerGen: 2, epoch: "E1")
        let lapAck = try await f.store.ack(
            itemId: f.item.id, sender: resent, effect: .runEvent(reopen, runId: reopen.run.id))
        #expect(lapAck == .acked(.closed))
        #expect(try await f.store.outbox.item(id: f.item.id) == nil)
        #expect(try f.markers()[Self.runLive] == 0)

        // A reopen of the same run, queued and acked applied, reopens it and clears the marker.
        let event = RunEventInDTO(id: UUID().wireString, type: "reopen", at: "2026-03-04T12:01:00.000000Z")
        let topic = TopicRef(id: UUID(uuidString: Self.liveTopic)!, slug: "walk", name: "Walk")
        let reopenItem = try await f.store.writer.write { db in
            try OutboxStorage.append(
                db,
                NewOutboxItem(
                    payload: .runEvent(RunEventPayload(topic: topic, runId: Self.runLive, event: event)), origin: .app),
                now: Make.t0)
        }
        try await f.store.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'in_flight', claim_token = 'claim-3', claim_owner = 'app:1',
                      claim_layer_gen = 2, claim_epoch = 'E1', attempts = 1 WHERE id = ?
                    """,
                arguments: [reopenItem.id])
        }
        let reopening = SenderContext(flush: f.sender.flush, claimToken: "claim-3", layerGen: 2, epoch: "E1")
        let reopenAck = try await f.store.ack(
            itemId: reopenItem.id, sender: reopening, effect: .runEvent(reopen, runId: reopen.run.id))
        #expect(reopenAck == .acked(.applied))
        #expect(try f.markers()[Self.runLive] == nil)
        #expect(try await f.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT revision FROM run") } == 3)
    }

    /// The full migrator, registered after the shipped series, gives the same schema and rows as
    /// applying the statements by hand; a second run is a no-op.
    @Test func theMigratorRunsItOnceAfterTheShippedSeries() throws {
        let queue = try DatabaseQueue(configuration: StoreDatabase.configuration(label: "t2m1-migrator"))
        try SharedDatabase.migrate(queue, Self.shipped)
        try queue.write { db in
            try LocalStore.createSyncState(db, serverId: "server-1", baseURL: "https://q.example")
            try db.execute(
                sql: "INSERT INTO tombstone (kind, id, topic_id, seq) VALUES ('run', ?, ?, 3)",
                arguments: [Self.runLive, Self.liveTopic])
        }
        try SharedDatabase.migrate(queue, Self.shipped + StoreSchema.t2m1Migrations)
        try SharedDatabase.migrate(queue, Self.shipped + StoreSchema.t2m1Migrations)
        try queue.read { (db: Database) throws in
            #expect(try db.tableExists("run_closed") && db.tableExists("stage_run_closed"))
            #expect(try Int.fetchOne(db, sql: "SELECT revision FROM run_closed WHERE id = ?", arguments: [Self.runLive]) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT layer_gen FROM sync_state") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tombstone") == 0)
        }
    }
}
