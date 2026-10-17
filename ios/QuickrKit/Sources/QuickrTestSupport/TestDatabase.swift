import GRDB
import QuickrData

/// In-memory databases migrated with the real migrators. For multi-process tests use a file and
/// `StoreDatabase.openPool(at:)` instead: an in-memory queue is private to one connection.
public enum TestDatabase {
    public static func store() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: StoreDatabase.configuration(label: "test-store"))
        try StoreSchema.migrator().migrate(queue)
        return queue
    }

    public static func registry() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: StoreDatabase.configuration(label: "test-registry"))
        try RegistrySchema.migrator().migrate(queue)
        return queue
    }
}
