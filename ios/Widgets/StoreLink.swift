import Foundation
import QuickrData

/// M1 proof that the widget extension links QuickrData and GRDB under Swift 6: a `DatabasePool` and a
/// `Sendable` repository (ios/README.md, "Data layer: Swift 6 and GRDB"). Replaced by the real
/// store bootstrap in M1/M2.
enum StoreLink {
    /// Opens and migrates a store in `directory`, then reads it through a repository protocol.
    /// Returns true when the new store has no `sync_state` yet.
    static func probe(directory: URL) async throws -> Bool {
        let pool = try StoreDatabase.openPool(at: directory.appendingPathComponent("probe.sqlite"))
        let repository: any SyncStateRepository = GRDBSyncStateRepository(reader: pool)
        return try await repository.syncState() == nil
    }
}
