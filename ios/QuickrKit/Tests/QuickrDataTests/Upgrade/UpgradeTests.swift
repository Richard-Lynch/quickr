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
        var registryV1: [String]

        enum CodingKeys: String, CodingKey {
            case storeV1 = "store_v1"
            case registryV1 = "registry_v1"
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

    // MARK: - Shipped migrations stay shipped

    /// A shipped migration never changes: a phone that ran it never runs it again. New schema goes
    /// in a new migration (append-only, StoreSchema's rule).
    @Test func theShippedV1MigrationsAreUnchanged() {
        #expect(StoreSchema.migrations.first?.identifier == "v1")
        #expect(StoreSchema.migrations.first?.statements == Self.frozen.storeV1)
        #expect(RegistrySchema.migrations.first?.identifier == "v1")
        #expect(RegistrySchema.migrations.first?.statements == Self.frozen.registryV1)
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
        let storeRows = try await before.read { db in try Self.dump(db, tables: storeTables) }
        let storeViews = try await before.read { db in try Self.views(db) }
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
        #expect(try await store.writer.read { db in try Self.dump(db, tables: storeTables) } == storeRows)
        let v1Columns = try await registry.read { db in
            try Dictionary(
                uniqueKeysWithValues: registryTables.map { table in
                    (
                        table,
                        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
                            .filter { table != "apns_state" || !$0.hasPrefix("register_") }
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

        // The same views.
        #expect(try await store.writer.read { db in try Self.views(db) } == storeViews)
        #expect(storeViews.topics.count == Self.spec.topics && !storeViews.outbox.isEmpty)
        let active = try await partitions.registry.repository.activeServerId()
        #expect(active == Self.serverId)
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
}
