import Foundation
import QuickrData

/// Stores for the app's tests: a fresh location, optionally with an active server whose server
/// layer holds the fixture topics (`PlaceholderTopicRepository`'s Coffee, Mood and archived Old
/// habit), as a real bootstrap would leave it.
enum TestStores {
    static func emptyLocation() -> StoreLocation {
        StoreLocation(root: URL.temporaryDirectory.appending(path: "quickr-app-tests-\(UUID().uuidString)"))
    }

    static func seededLocation() async throws -> StoreLocation {
        let location = emptyLocation()
        let partitions = try StorePartitions.open(at: location, notifier: nil)
        let store = try await partitions.createStore(serverId: "test-server", baseURL: "https://quickr.example")
        try await partitions.registry.setActive("test-server")
        let topics = try await PlaceholderTopicRepository().topics().map(\.topic)
        try await store.writer.write { db in
            for topic in topics { _ = try ServerLayer.upsert(db, topic: topic) }
        }
        return location
    }

    static func remove(_ location: StoreLocation) {
        try? FileManager.default.removeItem(at: location.root)
    }
}
