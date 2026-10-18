import Foundation
import GRDB
import Synchronization
import os

/// The active store, for a process that only reads (the widget extension): the registry and the
/// store file are opened **read-only** (GRDB `readonly`), so nothing is migrated, initialized,
/// recovered or repaired, no file is created and no lease is taken. Whatever needs the app (no
/// registry yet, no active server, a store file not created yet, a reset in progress) reads as
/// "no store", and so does a file this process can't or mustn't open read-only (no `-shm` beside
/// it yet, which SQLite would create; an unreadable container): the widget shows no topics instead
/// of an error until the app has opened the store. One pool per file, kept for the process.
public final class ReadOnlyStores: Sendable {
    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "store")

    public let location: StoreLocation
    private let pools = Mutex<[String: DatabasePool]>([:])

    public init(location: StoreLocation) { self.location = location }

    /// The active server's current store, or nil when the app has to act first.
    public func activeStore() throws -> LocalStore? {
        guard let registry = try pool(at: location.registryURL) else { return nil }
        let server: RegisteredServer? = try registry.read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT server_id FROM active WHERE id = 1") else {
                return nil
            }
            return try GRDBRegistryRepository.server(db, id: id)
        }
        // A reset in progress is the app's to finish (sync-protocol.md §12.2).
        guard let server, server.pendingGen == nil else { return nil }
        let url = location.storeURL(for: server)
        guard let store = try pool(at: url) else { return nil }
        return LocalStore(
            serverId: server.id, storeGen: server.storeGen, url: url, writer: store,
            leaseClock: SystemLeaseClock(), wallClock: SystemWallClock())
    }

    /// SQLite can't open the file read-only right now (`SQLITE_CANTOPEN`, or `SQLITE_READONLY` such
    /// as `READONLY_CANTINIT`: a WAL file without its `-shm`, which only a writer can create).
    static func isUnavailable(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CANTOPEN || error.resultCode == .SQLITE_READONLY
    }

    /// A read-only pool on an existing file that this process can read, or nil.
    private func pool(at url: URL) throws -> DatabasePool? {
        try pools.withLock { pools in
            if let pool = pools[url.path] { return pool }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            // Every shared file is a persistent-WAL file, so once a writer has opened it its
            // `-shm` is there. Without it, SQLite would create one even for a read-only
            // connection; that is the app's to do.
            guard FileManager.default.fileExists(atPath: url.path + "-shm") else {
                Self.log.notice("read-only open of \(url.lastPathComponent, privacy: .public) skipped: no -shm yet")
                return nil
            }
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5)
            do {
                let pool = try DatabasePool(path: url.path, configuration: configuration)
                // The open is lazy: read once so a file that can't be read now fails here.
                try pool.read { db in _ = try Int.fetchOne(db, sql: "SELECT 1") }
                pools[url.path] = pool
                return pool
            } catch let error as DatabaseError where Self.isUnavailable(error) {
                Self.log.notice(
                    "read-only open of \(url.lastPathComponent, privacy: .public) unavailable: \(error.description, privacy: .public)"
                )
                return nil
            }
        }
    }
}
