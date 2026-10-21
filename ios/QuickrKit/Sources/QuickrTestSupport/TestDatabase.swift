import GRDB
import QuickrData

/// In-memory databases migrated with the real migrators. For multi-process tests use a file and
/// `StoreDatabase.openPool(at:)` instead: an in-memory queue is private to one connection.
public enum TestDatabase {
    /// In memory, or at `path` when a second connection must share the file (lock contention).
    public static func store(path: String? = nil) throws -> DatabaseQueue {
        var configuration = StoreDatabase.configuration(label: "test-store")
        // An upper bound on waiting for another connection's write lock, never the timing under
        // test: a starved CI pool can take longer than the app's 5 s to run the holder's commit.
        configuration.busyMode = .timeout(60)
        let queue =
            try path.map { try DatabaseQueue(path: $0, configuration: configuration) }
            ?? DatabaseQueue(configuration: configuration)
        try StoreSchema.migrator().migrate(queue)
        return queue
    }

    public static func registry() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: StoreDatabase.configuration(label: "test-registry"))
        try RegistrySchema.migrator().migrate(queue)
        return queue
    }
}
