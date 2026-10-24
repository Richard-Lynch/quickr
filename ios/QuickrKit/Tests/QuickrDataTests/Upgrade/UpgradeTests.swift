// PerfSeed is compiled only in debug builds (and QUICKR_PERF ones); `make ios-release-test-build`
// checks the Release build compiles without it.
#if DEBUG || QUICKR_PERF
import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// UPG: a phone that ran the oldest schema keeps everything when today's app opens it.
///
/// `schema-v1.json` freezes the first shipped migrations (the store's v1 and the registry's v1, as
/// at M1, 48fa566): a location built with only those, filled the way a user's would be (the PERF
/// seed's topics, versions, entries and an outbox in every state; drafts, cached stats and widget
/// state; servers, the active one, categories, an owed unregistration, the APNs state), is opened
/// with today's code. Every row survives unchanged, the registry gains v2's columns at their
/// defaults, and every view the app reads gives the same answer.
@Suite(.timeLimit(.minutes(2))) struct UpgradeTests {
    struct Frozen: Decodable {
        var storeV1: [String]
        /// The store's v2 (timers T-DB: `timer_json`), as shipped before I-SYNC's v3.
        var storeV2: [String]
        var registryV1: [String]
        /// The registry's v2 (the APNs registration retry), as shipped before CATCAP's v3.
        var registryV2: [String]

        enum CodingKeys: String, CodingKey {
            case storeV1 = "store_v1"
            case storeV2 = "store_v2"
            case registryV1 = "registry_v1"
            case registryV2 = "registry_v2"
        }
    }

    static let frozen: Frozen = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "schema-v1.json")
        do {
            return try JSONDecoder().decode(Frozen.self, from: Data(contentsOf: url))
        } catch {
            fatalError("schema-v1.json: \(error)")
        }
    }()

    static let serverId = PerfSeed.Spec.standard.serverId
    static let otherServer = "5eed0000-0000-4000-8000-0000000000b2"
    static let spec = PerfSeed.Spec(topics: 10, entries: 2_000)
    /// notification_category's v3 columns (the capped registration).
    static let v3Columns = ["current", "due_at", "used_at", "pushed_at", "push_seq"]

    // MARK: - Shipped migrations stay shipped

    /// A shipped migration never changes: a phone that ran it never runs it again. New schema goes
    /// in a new migration (append-only, StoreSchema's rule).
    @Test func theShippedV1MigrationsAreUnchanged() {
        #expect(StoreSchema.migrations.first?.identifier == "v1")
        #expect(StoreSchema.migrations.first?.statements == Self.frozen.storeV1)
        #expect(StoreSchema.migrations.count >= 2)
        #expect(StoreSchema.migrations[1].identifier == "v2")
        #expect(StoreSchema.migrations[1].statements == Self.frozen.storeV2)
        #expect(RegistrySchema.migrations.first?.identifier == "v1")
        #expect(RegistrySchema.migrations.first?.statements == Self.frozen.registryV1)
        #expect(RegistrySchema.migrations.count >= 2)
        #expect(RegistrySchema.migrations[1].identifier == "v2")
        #expect(RegistrySchema.migrations[1].statements == Self.frozen.registryV2)
        for migrations in [StoreSchema.migrations, RegistrySchema.migrations] {
            #expect(
                migrations.map(\.identifier) == migrations.indices.map { "v\($0 + 1)" }, "migrations are v1, v2, …")
        }
    }

    // MARK: - An M1-era location

    /// Every table's rows, in a stable order: what "nothing lost" compares.
    static func dump(_ db: Database, tables: [String], columns: [String: [String]] = [:]) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for table in tables {
            let list = columns[table].map { $0.joined(separator: ", ") } ?? "*"
            out[table] = try Row.fetchAll(db, sql: "SELECT \(list) FROM \(table)").map(\.description).sorted()
        }
        return out
    }

    static func tables(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations' ORDER BY name
                """)
    }

    /// The store's columns that "nothing lost" compares: v2's `timer_json` and v3's `timing_json`
    /// are new, and v2 and v3 set `sync_state.rebuilding` (checked on their own).
    static func storeV1Columns(_ db: Database, tables: [String]) throws -> [String: [String]] {
        let added: [String: String] = [
            "topic_version": "timer_json", "stage_topic_version": "timer_json", "entry": "timing_json",
            "stage_entry": "timing_json", "sync_state": "rebuilding",
        ]
        var columns: [String: [String]] = [:]
        for table in tables {
            let rows: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            let names: [String] = rows.map { (row: Row) -> String in row["name"] }
            columns[table] = names.filter { (name: String) -> Bool in name != added[table] }
        }
        return columns
    }

    static func migrations(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }

    /// What the app reads: the home list with its derived fields, due topics, each topic's entries
    /// and versions, the outbox and its summary. Compared as values (a description's dictionary
    /// order isn't stable).
    struct Views: Equatable {
        var topics: [ViewTopic]
        var due: [UUID]
        var last: [String: Date]
        var entries: [String: [ViewEntry]]
        var versions: [String: [TopicVersion]]
        var outbox: [OutboxItem]
        var count: Int
        var maxSeq: Int64
    }

    static func views(_ db: Database) throws -> Views {
        let topics = try StoreView.topics(db)
        var entries: [String: [ViewEntry]] = [:]
        var versions: [String: [TopicVersion]] = [:]
        for topic in topics {
            entries[topic.id.wireString] = try StoreView.entries(db, topicId: topic.id.wireString)
            versions[topic.id.wireString] = try StoreView.versions(db, topicId: topic.id.wireString)
        }
        let summary = try OutboxStorage.summary(db)
        return Views(
            topics: topics, due: try StoreView.dueTopics(db).map(\.id), last: try StoreView.lastCapturedAt(db),
            entries: entries, versions: versions, outbox: try OutboxStorage.items(db), count: summary.count,
            maxSeq: summary.maxSeq)
    }

    /// Builds the location with only the frozen v1 migrations, the way M1's code would have.
    static func buildM1Location(_ location: StoreLocation) async throws {
        let registry = try SharedDatabase.openPool(
            at: location.registryURL, migrations: [("v1", frozen.registryV1)], notifier: nil,
            commitSignal: .registryChanged)
        let t0 = spec.now.timeIntervalSince1970
        try await registry.write { db in
            for (server, url, gen) in [(serverId, "https://quickr.test", 1), (otherServer, "https://other.example", 2)]
            {
                try db.execute(
                    sql: """
                        INSERT INTO server (server_id, base_url, display_name, store_gen, created_at, last_sync_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [server, url, "Name \(gen)", gen, t0 - 86_400 * 30, t0 - 120])
            }
            try db.execute(sql: "INSERT INTO active (id, server_id) VALUES (1, ?)", arguments: [serverId])
            try db.execute(
                sql: "INSERT INTO retired_file VALUES ('stores/\(otherServer).g1.sqlite', ?, 'boot-1', 42)",
                arguments: [t0 - 3_600])
            for n in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO notification_category VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        "quickr.t.\(PerfSeed.topicId(n).wireString).\(n)", serverId, PerfSeed.topicId(n).wireString,
                        #"[{"id":"q|a","title":"Mild","kind":"log"}]"#, t0 - Double(n),
                    ])
            }
            try db.execute(
                sql: """
                    INSERT INTO pending_unregister
                      (server_id, token, expect_epoch, first_attempt_at, attempts, due_boot_id, due_ct)
                    VALUES (?, 'old-token', 'E0', ?, 2, 'boot-1', 99)
                    """,
                arguments: [otherServer, t0 - 600])
            try db.execute(
                sql: """
                    INSERT INTO apns_state (id, token, environment, registered_server_id, last_registered_at)
                    VALUES (1, 'token-abc', 'sandbox', ?, ?)
                    """,
                arguments: [serverId, t0 - 60])
        }
        let store = try SharedDatabase.openPool(
            at: location.url("stores/\(serverId).g1.sqlite"), migrations: [("v1", frozen.storeV1)], notifier: nil,
            commitSignal: .dbChanged)
        try await store.write { db in
            try LocalStore.createSyncState(db, serverId: serverId, baseURL: "https://quickr.test")
            _ = try PerfSeed.fill(db, spec: spec)
            let topic = PerfSeed.topicId(0).wireString
            try db.execute(
                sql: "INSERT INTO ui_draft VALUES ('record:\(topic)', ?, '{\"answers\":{}}', ?)",
                arguments: [topic, t0])
            try db.execute(
                sql: "INSERT INTO stats_cache VALUES ('s|stats|\(topic)|range=30d', ?, ?, '{}', ?)",
                arguments: [topic, spec.epoch, t0])
            try db.execute(
                sql: "INSERT INTO widget_state VALUES ('tile:\(topic)', ?, '{}', ?)", arguments: [topic, t0])
        }
    }

    @Test func anM1LocationOpensWithNothingLost() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let location = StoreLocation(root: directory.url)
        try await Self.buildM1Location(location)
        let storeURL = location.url("stores/\(Self.serverId).g1.sqlite")

        // Before: read with today's views over the v1 files (the store schema is the same).
        let before = try DatabaseQueue(path: storeURL.path)
        let storeTables = try await before.read { db in try Self.tables(db) }
        let storeRows = try await before.read { db in
            try Self.dump(db, tables: storeTables, columns: try Self.storeV1Columns(db, tables: storeTables))
        }
        // Today's topic reads join v2's `topic_version.timer_json` (a v1 file has none, so every
        // timer is null): add the column, read, and roll back, leaving the file v1.
        var viewsBefore: Views?
        try before.inTransaction { db in
            try db.execute(sql: "ALTER TABLE topic_version ADD COLUMN timer_json TEXT")
            viewsBefore = try Self.views(db)
            return .rollback
        }
        let storeViews = try #require(viewsBefore)
        let registryBefore = try DatabaseQueue(path: location.registryURL.path)
        let registryTables = try await registryBefore.read { db in try Self.tables(db) }
        let registryRows = try await registryBefore.read { db in try Self.dump(db, tables: registryTables) }
        try before.close()
        try registryBefore.close()
        #expect(storeRows["entry"]?.count == 2_000 && storeRows["outbox_item"]?.count ?? 0 > 50)
        #expect(
            Set(
                try await DatabaseQueue(path: storeURL.path).read { db in
                    try String.fetchAll(db, sql: "SELECT DISTINCT state FROM outbox_item")
                }) == Set(OutboxState.allCases.map(\.rawValue)))

        // Today's app opens it: the registry migrates to the latest, the store opens as it is.
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let opened = try #require(try await partitions.openActiveStore(role: .app))
        let store = opened.store
        let registry = partitions.registry.writer

        #expect(
            try await registry.read { db in try Self.migrations(db) } == RegistrySchema.migrations.map(\.identifier))
        #expect(
            try await store.writer.read { db in try Self.migrations(db) } == StoreSchema.migrations.map(\.identifier))

        // Nothing lost: every v1 row, column for column.
        let storeV1Columns = try await store.writer.read { db in try Self.storeV1Columns(db, tables: storeTables) }
        #expect(
            try await store.writer.read { db in try Self.dump(db, tables: storeTables, columns: storeV1Columns) }
                == storeRows)
        // The store's v2 column: no version was timed before timers.
        let timed = try await store.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT (SELECT COUNT(*) FROM topic_version WHERE timer_json IS NOT NULL)
                      + (SELECT COUNT(*) FROM stage_topic_version WHERE timer_json IS NOT NULL)
                    """)
        }
        #expect(timed == 0)
        // …and a rebuild of the epoch it has, so the server's timers arrive (store v2).
        let state = try await store.state()
        #expect(state.epoch != nil && state.rebuilding == state.epoch)
        #expect(
            try await store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM topic_version") } ?? 0
                > 0)
        let v1Columns = try await registry.read { db in
            try Dictionary(
                uniqueKeysWithValues: registryTables.map { table in
                    (
                        table,
                        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
                            .filter { table != "apns_state" || !$0.hasPrefix("register_") }
                            .filter { table != "notification_category" || !Self.v3Columns.contains($0) }
                    )
                })
        }
        #expect(
            try await registry.read { db in try Self.dump(db, tables: registryTables, columns: v1Columns) }
                == registryRows)
        // v2's columns, at their defaults.
        let (attempts, dueBoot, dueCt) = try await registry.read { db -> (Int?, String?, Int?) in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM apns_state")
            return (row?["register_attempts"], row?["register_due_boot_id"], row?["register_due_ct"])
        }
        #expect(attempts == 0 && dueBoot == nil && dueCt == nil)
        // v3's: not current, no due time, last wanted when inserted.
        let categories = try await registry.read { db in
            try Row.fetchAll(db, sql: "SELECT current, due_at, used_at, created_at FROM notification_category").map {
                ($0["current"] as Int) == 0 && ($0["due_at"] as Double?) == nil
                    && ($0["used_at"] as Double) == ($0["created_at"] as Double)
            }
        }
        #expect(categories == [true, true, true])

        // The same views.
        #expect(try await store.writer.read { db in try Self.views(db) } == storeViews)
        #expect(storeViews.topics.count == Self.spec.topics && !storeViews.outbox.isEmpty)
        let active = try await partitions.registry.repository.activeServerId()
        #expect(active == Self.serverId)
    }

    // MARK: - CATCAP: a v2 registry with a large category union

    /// A registry from before CATCAP (v1 + v2, append-only) holding a year's union, 650 rows,
    /// next to the M1 store (an outbox in every state). Today's code migrates it to v3 with every
    /// row not current, no due time, last used when inserted and never pushed; nothing is deleted
    /// by the migration. The app's first refresh then registers at most the cap and deletes what
    /// can't be needed: rows outside the selection that aren't current or on screen. The store
    /// and its outbox are untouched.
    @Test func aV2RegistryWithALargeUnionUpgradesAndPrunes() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let location = StoreLocation(root: directory.url)
        try await Self.buildM1Location(location)
        let t0 = Self.spec.now.timeIntervalSince1970
        // M2/M3: the registry at v2, with a year of number-topic categories (newest last).
        let old = try SharedDatabase.openPool(
            at: location.registryURL, migrations: [("v1", Self.frozen.registryV1), ("v2", Self.frozen.registryV2)],
            notifier: nil, commitSignal: .registryChanged)
        let union = (0..<650).map { "quickr.t.\(PerfSeed.topicId($0 % 10).wireString).old\($0)" }
        try await old.write { db in
            for (n, id) in union.enumerated() {
                try db.execute(
                    sql: "INSERT INTO notification_category VALUES (?, ?, ?, '[]', ?)",
                    arguments: [id, Self.serverId, PerfSeed.topicId(n % 10).wireString, t0 - 86_400 * 365 + Double(n)])
            }
        }
        try old.close()
        let storeURL = location.url("stores/\(Self.serverId).g1.sqlite")
        let outboxBefore = try await DatabaseQueue(path: storeURL.path).read { db in try OutboxStorage.items(db) }

        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let registry = partitions.registry.writer
        #expect(
            try await registry.read { db in try Self.migrations(db) } == RegistrySchema.migrations.map(\.identifier))
        let migrated = try await registry.read { db in
            try Row.fetchAll(
                db, sql: "SELECT current, due_at, used_at, created_at, pushed_at, push_seq FROM notification_category"
            )
            .filter {
                ($0["current"] as Int) == 0 && ($0["due_at"] as Double?) == nil && ($0["pushed_at"] as Double?) == nil
                    && ($0["push_seq"] as Int64?) == nil
                    && ($0["used_at"] as Double) == ($0["created_at"] as Double)
            }.count
        }
        #expect(migrated == 653, "the 650 and M1's 3, all at v3's starting values")
        #expect(try await registry.read(NotificationCategories.generation) == 0)

        // The app's first refresh, with two old notifications still on screen.
        let opened = try #require(try await partitions.openActiveStore(role: .app))
        let center = FakeNotificationCenter()
        center.withState { $0.categoryCapacity = 100 }
        let onScreen: Set<String> = [union[0], union[1]]
        center.withState { $0.delivered = onScreen.map { NotificationSnapshot(id: $0, categoryIdentifier: $0) } }
        let categories = NotificationCategories(
            registry: partitions.registry, center: center, wallClock: FakeClock(Self.spec.now))
        let current = Set(try await categories.refresh(from: opened.store))
        let registered = center.withState { Set($0.categories.map(\.id)) }
        let table = Set(
            try await registry.read { db in try String.fetchAll(db, sql: "SELECT id FROM notification_category") })
        #expect(registered.count == NotificationCategories.registrationCap)
        #expect(current.isSubset(of: registered) && onScreen.isSubset(of: registered))
        #expect(table == registered.union(current).union(onScreen), "everything else was deleted")
        #expect(table.count < 653)
        // The store and its outbox are as they were.
        #expect(try await opened.store.writer.read { db in try OutboxStorage.items(db) } == outboxBefore)
    }

    /// End to end: today's session binds the upgraded store and Home lists its topics.
    @MainActor @Test func theAppStartsOnAnUpgradedLocation() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanup() }
        let location = StoreLocation(root: directory.url)
        try await Self.buildM1Location(location)
        let offline = FakeTransport()
        offline.stub(where: { _ in true }, { _ in throw TransportError.unreachable("offline") })
        let session = try AppSession(
            configuration: .init(
                location: location, transport: offline, notifier: nil, notificationCenter: NotificationCenter()))
        await session.start()
        #expect(session.phase == .ready)
        let home = HomeModel(session: session, debounce: .zero)
        let observing = Task { await home.observe() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while home.topics.count < Self.spec.topics, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        observing.cancel()
        #expect(home.topics.count == Self.spec.topics)
        // What the store's own view says (entry counts include the outbox's creates and deletes).
        let store = try #require(session.store)
        let expected = try await store.writer.read { db in try StoreView.topics(db) }
        let shown: Int = home.topics.map(\.topic.entryCount).reduce(0, +)
        let stored: Int = expected.map(\.topic.entryCount).reduce(0, +)
        #expect(Set(home.topics.map(\.id)) == Set(expected.map(\.id)))
        #expect(shown == stored)
        #expect(shown > Self.spec.entries - 100)
        await session.shutdown()
    }

    // MARK: - Store v2: timers

    /// A timers server synced by a build before store v2: its timed version is stored without a
    /// timer. The update's v2 migration starts a rebuild, the next sync re-pulls the server layer,
    /// and a question edit then publishes the timer the server has, not null.
    @Test func aStoreSyncedBeforeV2RebuildsAndPublishesTheTimer() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let synced = try await env.connect(env.coordinator())
        let everything = SyncTimerTests.everything
        // As the old build left it: v1 only, so no timer column.
        try await synced.writer.write { db in
            for prefix in ["", "stage_"] {
                try db.execute(sql: "ALTER TABLE \(prefix)topic_version DROP COLUMN timer_json")
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
        }

        // The updated app (a new process) opens it: v2 runs and asks for a rebuild of its epoch.
        let partitions = try env.otherProcess()
        let store = try #require(try await partitions.openActiveStore(role: .app)).store
        let state = try await store.state()
        #expect(state.rebuilding == state.epoch && state.epoch != nil)
        #expect(try await store.versions.version(topicId: everything, number: 2)?.timer == nil)

        let relaunched = env.coordinator(owner: "app:B", partitions: partitions)
        #expect(await relaunched.sync(reason: .activation) == .synced)
        let after = try await store.state()
        #expect(after.rebuilding == nil && after.epoch == state.epoch && after.layerGen == state.layerGen + 1)
        #expect(try await store.versions.version(topicId: everything, number: 2)?.timer == SyncTimerTests.fixtureTimer)

        // A publish from this device keeps it.
        let binding = AppSession.Binding(serverId: store.serverId, storeGen: store.storeGen, baseURL: SyncEnv.baseURL)
        let scope = try #require(await TopicWrites.scope(binding: binding, store: store))
        let recorder = SyncTimerTests.Recorder()
        let writes = TopicWrites(
            scope: scope, store: store, transport: recorder, credentials: StaticAccessCredentials(nil),
            requestSync: { _ in })
        let questions = try #require(try await store.versions.version(topicId: everything, number: 2)).questions
        _ = await writes.publishVersion(
            topicId: everything, TopicDraft.Version(questions: questions), baseVersion: 2, changeNote: "")
        let body = try #require(recorder.requests.last?.body)
        #expect(
            try WireCoding.decoder().decode(SyncTimerTests.SentTimer.self, from: body).timer
                == SyncTimerTests.fixtureTimer)
    }

    // MARK: - Store v3: runs

    /// v3 on a real v1 + v2 file, mid-rebuild: tombstones are copied into the rebuilt table, which
    /// now takes kind `run`; staging starts over (every stage table empty, its cursor 0); and the
    /// rebuild already under way keeps its target.
    @Test func v3OnAV2StoreKeepsTombstonesAndRestartsStaging() throws {
        let queue = try DatabaseQueue()
        try SharedDatabase.migrate(queue, [("v1", Self.frozen.storeV1), ("v2", Self.frozen.storeV2)])
        let topic = Make.topic()
        try queue.write { db in
            try LocalStore.createSyncState(db, serverId: "s", baseURL: "https://q.example")
            try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', rebuilding = 'E2', cursor = 30 WHERE id = 1")
            try db.execute(sql: "UPDATE stage_state SET cursor = 12 WHERE id = 1")
            for prefix in ["", "stage_"] {
                try db.execute(
                    sql: """
                        INSERT INTO \(prefix)tombstone (kind, id, topic_id, seq)
                        VALUES ('entry', 'e1', 't1', 3), ('topic', 't2', 't2', 4), ('version', 'v1', 't1', NULL)
                        """)
            }
            _ = try ServerLayer.upsert(db, topic: topic, into: .stage)
            _ = try ServerLayer.upsert(db, entry: Make.entry(topicId: topic.id), into: .stage)
            _ = try ServerLayer.insert(db, version: Make.version(), id: UUID(), topicId: topic.id, into: .stage)
        }
        let tombstones = { (db: Database, table: String) throws -> [String] in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY kind, id").map(\.description)
        }
        let before: [String] = try queue.read { db in try tombstones(db, "tombstone") }
        #expect(before.count == 3)

        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        try queue.write { db in
            #expect(try tombstones(db, "tombstone") == before)
            for table in StoreSchema.stageTables {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
            }
            #expect(try Int.fetchOne(db, sql: "SELECT cursor FROM stage_state") == 0)
            let state = try #require(try Row.fetchOne(db, sql: "SELECT rebuilding, epoch, cursor FROM sync_state"))
            let rebuilding: String? = state["rebuilding"]
            let epoch: String? = state["epoch"]
            let cursor: Int = state["cursor"]
            #expect(rebuilding == "E2")
            #expect(epoch == "E1")
            #expect(cursor == 30)
            for prefix in ["", "stage_"] {
                try db.execute(
                    sql: "INSERT INTO \(prefix)tombstone (kind, id, topic_id, seq) VALUES ('run', 'r1', 't1', 6)")
            }
        }
    }

    /// The store `synced` holds, as a build before v3 (T-FEED's) left it, at `env`'s location: a
    /// real v1 + v2 file with the same server layer and sync state, less what that build never
    /// kept (run rows, run tombstones, entry timing), registered and active. `env`'s server takes
    /// the same state. `edit` runs on the copy before it is closed.
    static func preV3Location(
        copying synced: LocalStore, server: FakeFeedServer, into env: SyncEnv,
        edit: @escaping @Sendable (Database) throws -> Void = { _ in }
    ) async throws {
        let source = try #require(synced.url).path
        let url = StoreLocation(root: env.dir.url).url("stores/\(synced.serverId).g1.sqlite")
        let pool = try SharedDatabase.openPool(
            at: url, migrations: [("v1", frozen.storeV1), ("v2", frozen.storeV2)], notifier: nil,
            commitSignal: .dbChanged)
        try await pool.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS old", arguments: [source])
            try db.inTransaction {
                for table in StoreSchema.v1ServerLayerTables + ["sync_state", "stage_state"] {
                    let names: [String] = try Row.fetchAll(db, sql: "PRAGMA main.table_info(\(table))").map {
                        (row: Row) -> String in row["name"]
                    }
                    let columns = names.joined(separator: ", ")
                    let filter = table == "tombstone" ? "WHERE kind <> 'run'" : ""
                    try db.execute(sql: "DELETE FROM main.\(table)")
                    try db.execute(
                        sql: "INSERT INTO main.\(table) (\(columns)) SELECT \(columns) FROM old.\(table) \(filter)")
                }
                try edit(db)
                return .commit
            }
            try db.execute(sql: "DETACH DATABASE old")
        }
        try pool.close()
        try await env.partitions.registry.writer.write { db in
            try db.execute(
                sql: "INSERT INTO server (server_id, base_url, store_gen, created_at) VALUES (?, ?, 1, 0)",
                arguments: [synced.serverId, SyncEnv.baseURL.absoluteString])
            try db.execute(sql: "INSERT INTO active (id, server_id) VALUES (1, ?)", arguments: [synced.serverId])
        }
        env.server.restore(server.snapshot())
    }

    /// A timers server synced by a build before store v3 (T-FEED's): it decoded run items and
    /// deletions, dropped them and moved its cursor past them, and stored entries without their
    /// timing. Opening that v2 file runs v3, which starts a rebuild; the next sync re-pulls the
    /// server layer, and the open run and the stopped run's timing arrive.
    @Test func aStoreSyncedBeforeV3RebuildsAndGetsItsRuns() async throws {
        let old = try SyncEnv()
        defer { old.cleanup() }
        let stopped = try SyncRunTests.stoppedEntry()
        old.server.putRun(try SyncRunTests.openRun())
        old.server.closeRun(SyncRunTests.runA, entry: stopped)
        old.server.putRun(try SyncRunTests.otherRun())
        let synced = try await old.connect(old.coordinator())
        let head = old.server.head
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await Self.preV3Location(copying: synced, server: old.server, into: env)
        let entryId = try SyncRunTests.domainEntry(stopped).id

        // The updated app (a new process) opens it: v3 runs and asks for a rebuild of its epoch.
        let partitions = try env.otherProcess()
        let store = try #require(try await partitions.openActiveStore(role: .app)).store
        let state = try await store.state()
        #expect(state.rebuilding == state.epoch && state.epoch != nil && state.cursor == head)
        #expect(state.bootstrapComplete)
        #expect(try await store.runs.runs().isEmpty)
        let timingBefore: Timing? = try await store.entries.entry(id: entryId)?.entry.timing
        #expect(timingBefore == nil)

        let relaunched = env.coordinator(owner: "app:B", partitions: partitions)
        #expect(await relaunched.sync(reason: .activation) == .synced)
        let after = try await store.state()
        #expect(after.rebuilding == nil && after.epoch == state.epoch && after.layerGen == state.layerGen + 1)
        let expectedRuns: [Run] = [try SyncRunTests.domain(try SyncRunTests.otherRun())]
        #expect(try await store.runs.runs() == expectedRuns)
        let expectedTiming: Timing? = try SyncRunTests.domainEntry(stopped).timing
        let storedTiming: Timing? = try await store.entries.entry(id: entryId)?.entry.timing
        #expect(storedTiming == expectedTiming && expectedTiming != nil)
        let runTombstones: [String] = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM tombstone WHERE kind = 'run'")
        }
        #expect(runTombstones == [SyncRunTests.runA])
    }

    /// The same, stopped mid-bootstrap (an epoch, `bootstrap_complete = 0`): v3's rebuild of that
    /// epoch ends the bootstrap at the swap.
    @Test func aV2StoreMidBootstrapCompletesThroughTheRebuild() async throws {
        let old = try SyncEnv()
        defer { old.cleanup() }
        old.server.putRun(try SyncRunTests.openRun())
        let synced = try await old.connect(old.coordinator())
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await Self.preV3Location(copying: synced, server: old.server, into: env) { db in
            try db.execute(sql: "UPDATE main.sync_state SET bootstrap_complete = 0 WHERE id = 1")
        }

        let partitions = try env.otherProcess()
        let store = try #require(try await partitions.openActiveStore(role: .app)).store
        let state = try await store.state()
        #expect(!state.bootstrapComplete && state.epoch != nil && state.rebuilding == state.epoch)

        let relaunched = env.coordinator(owner: "app:B", partitions: partitions)
        #expect(await relaunched.sync(reason: .activation) == .synced)
        let after = try await store.state()
        #expect(after.bootstrapComplete && after.rebuilding == nil && after.layerGen == state.layerGen + 1)
        let expectedRuns: [Run] = [try SyncRunTests.domain(try SyncRunTests.openRun())]
        #expect(try await store.runs.runs() == expectedRuns)
    }

    /// A store that never synced has nothing to re-pull: v2 and v3 leave `rebuilding` alone.
    @Test func v2DoesNotRebuildAStoreWithNoEpoch() throws {
        let queue = try DatabaseQueue()
        try SharedDatabase.migrate(queue, [("v1", Self.frozen.storeV1)])
        try queue.write { db in try LocalStore.createSyncState(db, serverId: "s", baseURL: "https://q.example") }
        try SharedDatabase.migrate(queue, StoreSchema.migrations)
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT rebuilding FROM sync_state") } == nil)
    }
}
#endif
