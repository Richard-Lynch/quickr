import Foundation
import GRDB
import Synchronization

/// The active store, for a process that only reads (the widget extension): the registry and the
/// store file are opened **read-only** (GRDB `readonly`), so nothing is migrated, initialized,
/// recovered or repaired, no file is created and no lease is taken. Whatever needs the app (no
/// registry yet, no active server, a store file not created yet, a reset in progress) reads as
/// "no store". One pool per file, kept for the process.
public final class ReadOnlyStores: Sendable {
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

    /// A read-only pool on an existing file, or nil when the file isn't there.
    private func pool(at url: URL) throws -> DatabasePool? {
        try pools.withLock { pools in
            if let pool = pools[url.path] { return pool }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5)
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            pools[url.path] = pool
            return pool
        }
    }
}
