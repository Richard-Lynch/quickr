#if DEBUG
import Foundation
import QuickrData
import Testing

@testable import QuickR

/// The debug demo store's seeding (`-QuickrDemoStore`, `-QuickrDemoShared [fresh]`): what becomes
/// active, and when a shared demo is kept or replaced.
@Suite(.timeLimit(.minutes(5))) struct DemoStoreTests {
    let location = StoreLocation(root: URL.temporaryDirectory.appending(path: "demo-store-tests-\(UUID().uuidString)"))

    func partitions() throws -> StorePartitions { try StorePartitions.open(at: location, notifier: nil) }

    func active() async throws -> String? { try await partitions().registry.repository.activeServerId() }

    func topicCount(_ serverId: String) async throws -> Int {
        let store = try await partitions().openStore(serverId: serverId, role: .app).store
        return try await store.writer.read { try StoreView.topics($0).count }
    }

    static func isServerId(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }

    @Test func theTemporaryDemoIsActiveUnderAUUIDServerId() async throws {
        defer { try? FileManager.default.removeItem(at: location.root) }
        try await DemoStore.seed(location)
        #expect(try await active() == DemoStore.serverId)
        // A reminder action's identifier needs a canonical server id, or every demo action is invalid.
        #expect(Self.isServerId(DemoStore.serverId))
        #expect(try await topicCount(DemoStore.serverId) == DemoStore.topics(now: Date()).count)
    }

    @Test func aSharedDemoIsKeptUntilFreshReplacesIt() async throws {
        defer { try? FileManager.default.removeItem(at: location.root) }
        let first = try await DemoStore.prepareShared(location, mode: .keep, notifier: nil)
        #expect(Self.isServerId(first))
        #expect(try await active() == first)
        #expect(try await topicCount(first) > 0)

        #expect(try await DemoStore.prepareShared(location, mode: .keep, notifier: nil) == first, "kept")

        let second = try await DemoStore.prepareShared(location, mode: .fresh, notifier: nil)
        #expect(second != first)
        #expect(try await active() == second)
        // Nothing is deleted: the earlier demo stays registered (an extension may hold it open).
        #expect(try await partitions().registry.repository.server(id: first) != nil)
    }

    @Test func aRealServerIsNeverTakenForTheDemo() async throws {
        defer { try? FileManager.default.removeItem(at: location.root) }
        let real = UUID().uuidString.lowercased()
        let partitions = try partitions()
        _ = try await partitions.createStore(serverId: real, baseURL: "https://quickr.home.example")
        try await partitions.registry.setActive(real)

        let demo = try await DemoStore.prepareShared(location, mode: .keep, notifier: nil)
        #expect(demo != real)
        #expect(try await active() == demo)
        #expect(try await partitions.registry.repository.server(id: real) != nil, "left as it was")
    }
}
#endif
