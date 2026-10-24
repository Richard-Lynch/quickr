import Foundation
import GRDB

/// Where the shared files live (sync-protocol.md §8.1):
///
/// ```
/// <AppGroup>/Library/quickr/
///   registry.sqlite
///   stores/<server_id>.g<store_gen>.sqlite
/// ```
public struct StoreLocation: Sendable, Hashable {
    /// `<AppGroup>/Library/quickr`.
    public var root: URL

    public init(root: URL) { self.root = root }

    /// The App Group container's location. Throws if the process lacks the entitlement.
    public static func appGroup(_ identifier: String) throws -> StoreLocation {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw StoreError.coordinationFailed("no App Group container for \(identifier)")
        }
        return StoreLocation(root: container.appending(path: "Library/quickr", directoryHint: .isDirectory))
    }

    /// The App Group's location, or Application Support when the process has no App Group (an
    /// unsigned build), so the app and its extensions still open a store.
    public static func shared(appGroup identifier: String) -> StoreLocation {
        (try? appGroup(identifier))
            ?? StoreLocation(
                root: URL.applicationSupportDirectory.appending(path: "quickr", directoryHint: .isDirectory))
    }

    public var registryURL: URL { root.appending(path: "registry.sqlite") }

    /// A path relative to `root`, such as `RegisteredServer.storeFileName`.
    public func url(_ relativePath: String) -> URL { root.appending(path: relativePath) }

    public func storeURL(for server: RegisteredServer) -> URL { url(server.storeFileName) }
}

/// One `retired_file` row: a store file a reset has replaced, waiting for lazy deletion (§12.1
/// step 9). The deadline is lease time; the wall time is for display.
public struct RetiredFile: Sendable, Hashable {
    /// Relative to `StoreLocation.root`.
    public var path: String
    public var retiredAtWall: Date
    public var retiredAt: LeaseInstant

    public init(path: String, retiredAtWall: Date, retiredAt: LeaseInstant) {
        self.path = path
        self.retiredAtWall = retiredAtWall
        self.retiredAt = retiredAt
    }
}

/// `registry.sqlite`: servers, their store generations and reset intents, the active server and
/// retired files (sync-protocol.md §8, §12). Every method is one short registry transaction; none
/// is ever open together with a store transaction (§5.2 rule 4).
public struct Registry: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// Opens (creating and migrating) the shared registry. Every commit posts `registry-changed`.
    public static func open(at location: StoreLocation, notifier: (any ChangeNotifier)?) throws -> Registry {
        Registry(
            writer: try SharedDatabase.openPool(
                at: location.registryURL, migrations: RegistrySchema.migrations, notifier: notifier,
                commitSignal: .registryChanged))
    }

    public var repository: GRDBRegistryRepository { GRDBRegistryRepository(reader: writer) }

    /// Inserts `server(server_id, base_url, store_gen = 1)` if it isn't registered (§2.1 step 3),
    /// and returns the row.
    public func register(serverId: String, baseURL: String, displayName: String? = nil, now: Date) async throws
        -> RegisteredServer
    {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO server (server_id, base_url, display_name, store_gen, created_at)
                    VALUES (?, ?, ?, 1, ?)
                    """,
                arguments: [serverId, baseURL, displayName, now.unixSeconds])
            return try Self.server(db, serverId)
        }
    }

    public func setActive(_ serverId: String?) async throws {
        try await writer.write { db in
            if let serverId {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO active (id, server_id) VALUES (1, ?)", arguments: [serverId])
            } else {
                try db.execute(sql: "DELETE FROM active")
            }
        }
    }

    /// A known server now answers at `baseURL` (the user entered another address for it during
    /// onboarding or in Settings, §2.1): every later request uses it.
    public func updateBaseURL(serverId: String, baseURL: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE server SET base_url = ? WHERE server_id = ?", arguments: [baseURL, serverId])
        }
    }

    public func setLastSync(serverId: String, at date: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE server SET last_sync_at = ? WHERE server_id = ?", arguments: [date.unixSeconds, serverId])
        }
    }

    // MARK: - Reset (§12)

    /// Step 2: persist the intent, `pending_gen = store_gen + 1` with the confirmed count, max
    /// seq and a fresh `pending_token` that identifies this attempt. Nothing is retired yet. Only when `store_gen` is still `storeGen` (the file the user
    /// was warned about) and no reset is in progress; otherwise throws `registryChanged`.
    public func persistResetIntent(serverId: String, storeGen: Int, confirmedCount: Int, confirmedMaxSeq: Int64)
        async throws -> RegisteredServer
    {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE server
                    SET pending_gen = store_gen + 1, pending_confirmed_count = ?, pending_confirmed_max_seq = ?,
                        pending_token = ?
                    WHERE server_id = ? AND store_gen = ? AND pending_gen IS NULL
                    """,
                arguments: [confirmedCount, confirmedMaxSeq, UUID().wireString, serverId, storeGen])
            guard db.changesCount > 0 else { throw StoreError.registryChanged(serverId) }
            return try Self.server(db, serverId)
        }
    }

    /// Aborts a reset (lease timeout, or writes arrived): clears the intent, only if it is still
    /// the attempt identified by `token`. Returns whether it cleared it.
    @discardableResult
    public func clearResetIntent(serverId: String, token: String) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE server
                    SET pending_gen = NULL, pending_confirmed_count = NULL, pending_confirmed_max_seq = NULL,
                        pending_token = NULL
                    WHERE server_id = ? AND pending_token = ?
                    """,
                arguments: [serverId, token])
            return db.changesCount > 0
        }
    }

    public enum ResetCompletion: Sendable, Hashable {
        /// This call moved `store_gen` from `fromGen` to `toGen`.
        case advanced
        /// Someone already completed exactly this reset.
        case alreadyAdvanced
        /// The registry no longer holds this intent (a different reset is in progress, or it was
        /// aborted). Nothing was written; re-read the registry and restart recovery.
        case superseded
    }

    /// Step 6: `store_gen = pending_gen`, clear the intent, record the old file in `retired_file`.
    /// Fenced on the attempt the caller inspected (`store_gen = fromGen`, `pending_gen = toGen`
    /// and `pending_token = token`), compared inside the transaction, so a stale caller can never
    /// complete a different attempt whose file it never saw retired. Any process may run it;
    /// repeats report `alreadyAdvanced`.
    @discardableResult
    public func completeReset(
        serverId: String, fromGen: Int, toGen: Int, token: String, retiredAtWall: Date, retiredAt: LeaseInstant
    ) async throws -> ResetCompletion {
        try await writer.write { db in
            let server = try Self.server(db, serverId)
            guard server.storeGen == fromGen, server.pendingGen == toGen, server.pendingToken == token else {
                return server.storeGen == toGen && server.pendingGen == nil ? .alreadyAdvanced : .superseded
            }
            try db.execute(
                sql: """
                    UPDATE server
                    SET store_gen = pending_gen, pending_gen = NULL, pending_confirmed_count = NULL,
                        pending_confirmed_max_seq = NULL, pending_token = NULL
                    WHERE server_id = ? AND store_gen = ? AND pending_gen = ? AND pending_token = ?
                    """,
                arguments: [serverId, fromGen, toGen, token])
            try Self.insertRetired(db, path: server.storeFileName, wall: retiredAtWall, at: retiredAt)
            return .advanced
        }
    }

    /// §12.2 row 3 (unreachable in theory): no intent, but `store_gen` names a retired file. Moves
    /// to `store_gen + 1` and records the old file, only if `store_gen` is still `retiredGen`.
    @discardableResult
    public func repairRetiredPointer(serverId: String, retiredGen: Int, retiredAtWall: Date, retiredAt: LeaseInstant)
        async throws -> Bool
    {
        try await writer.write { db in
            let server = try Self.server(db, serverId)
            guard server.pendingGen == nil, server.storeGen == retiredGen else { return false }
            try db.execute(
                sql: "UPDATE server SET store_gen = store_gen + 1 WHERE server_id = ? AND store_gen = ?",
                arguments: [serverId, retiredGen])
            try Self.insertRetired(db, path: server.storeFileName, wall: retiredAtWall, at: retiredAt)
            return true
        }
    }

    public func retiredFiles() async throws -> [RetiredFile] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM retired_file ORDER BY path").map { row in
                RetiredFile(
                    path: row["path"], retiredAtWall: Date(unixSeconds: row["retired_at_wall"]),
                    retiredAt: LeaseInstant(bootId: row["retired_boot_id"], ct: row["retired_ct"] as Int64))
            }
        }
    }

    public func forgetRetiredFile(path: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM retired_file WHERE path = ?", arguments: [path])
        }
    }

    private static func server(_ db: Database, _ serverId: String) throws -> RegisteredServer {
        guard let server = try GRDBRegistryRepository.server(db, id: serverId) else {
            throw StoreError.unknownServer(serverId)
        }
        return server
    }

    private static func insertRetired(_ db: Database, path: String, wall: Date, at instant: LeaseInstant) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO retired_file (path, retired_at_wall, retired_boot_id, retired_ct)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [path, wall.unixSeconds, instant.bootId, instant.ct])
    }
}

/// Reads of the registry.
public struct GRDBRegistryRepository: RegistryRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) { self.reader = reader }

    public func servers() async throws -> [RegisteredServer] {
        try await reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM server ORDER BY created_at, server_id").map(
                RegisteredServer.init(row:))
        }
    }

    public func server(id: String) async throws -> RegisteredServer? {
        try await reader.read { db in try Self.server(db, id: id) }
    }

    public func activeServerId() async throws -> String? {
        try await reader.read { db in try String.fetchOne(db, sql: "SELECT server_id FROM active WHERE id = 1") }
    }

    /// This device's APNs token (hex), once the system gave one (notifications.md §9): the
    /// `device.apns_token` of every run event (timers.md §3.2).
    public func apnsToken() async throws -> String? {
        try await reader.read { db in try String.fetchOne(db, sql: "SELECT token FROM apns_state WHERE id = 1") }
    }

    public func notificationCategories() async throws -> [NotificationCategoryRecord] {
        try await reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notification_category ORDER BY created_at, id").map { row in
                NotificationCategoryRecord(
                    id: row["id"], serverId: row["server_id"], topicId: row["topic_id"],
                    actionsJSON: row["actions_json"], createdAt: Date(unixSeconds: row["created_at"]))
            }
        }
    }

    static func server(_ db: Database, id: String) throws -> RegisteredServer? {
        try Row.fetchOne(db, sql: "SELECT * FROM server WHERE server_id = ?", arguments: [id])
            .map(RegisteredServer.init(row:))
    }
}

extension RegisteredServer {
    init(row: Row) {
        self.init(
            id: row["server_id"], baseURL: row["base_url"], displayName: row["display_name"],
            storeGen: row["store_gen"],
            createdAt: Date(unixSeconds: row["created_at"]),
            lastSyncAt: (row["last_sync_at"] as Double?).map(Date.init(unixSeconds:)), pendingGen: row["pending_gen"],
            pendingConfirmedCount: row["pending_confirmed_count"],
            pendingConfirmedMaxSeq: row["pending_confirmed_max_seq"], pendingToken: row["pending_token"])
    }
}
