import Foundation
import GRDB

/// Opening a store file. This is the reference pattern for Swift 6 + GRDB in every process
/// (app, widget, NSE): see ios/README.md, "Data layer: Swift 6 and GRDB".
///
/// STORE extends this with the App Group location, file protection
/// (`completeUntilFirstUserAuthentication`), the multi-process configuration
/// (`observesSuspensionNotifications`, persistent WAL) and the `IMMEDIATE` migrator.
public enum StoreDatabase {
    public static func configuration(label: String) -> Configuration {
        var configuration = Configuration()
        configuration.label = label
        // Another process may hold the write lock briefly; wait instead of failing with SQLITE_BUSY.
        configuration.busyMode = .timeout(5)
        return configuration
    }

    /// Opens (creating if needed) a WAL `DatabasePool` at `url` and migrates it.
    public static func openPool(at url: URL, migrator: DatabaseMigrator = StoreSchema.migrator()) throws
        -> DatabasePool
    {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration(label: url.lastPathComponent))
        try migrator.migrate(pool)
        return pool
    }
}

/// Reads `sync_state`. The smallest real repository, and the template for the others: a
/// `Sendable` struct over `any DatabaseReader`, async methods, records built inside the read
/// closure and returned as `Sendable` values.
public struct GRDBSyncStateRepository: SyncStateRepository {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    public func syncState() async throws -> SyncState? {
        try await reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
        }
    }
}

extension SyncState {
    init(row: Row) {
        self.init(
            serverId: row["server_id"], baseURL: row["base_url"], epoch: row["epoch"], cursor: row["cursor"],
            headSeen: row["head_seen"], layerGen: row["layer_gen"], rebuilding: row["rebuilding"],
            epochSuspect: row["epoch_suspect"], retired: row["retired"], identityMismatch: row["identity_mismatch"],
            lastPullAt: (row["last_pull_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            skewMilliseconds: row["skew_ms"],
            skewMeasuredAt: (row["skew_measured_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            bootstrapComplete: row["bootstrap_complete"], serverOffsetMs: row["server_offset_ms"],
            clientOutdatedMin: row["client_outdated_min"], serverApiLevel: row["server_api_level"])
    }
}
