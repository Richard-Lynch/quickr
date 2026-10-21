import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `SyncCoordinator.connect(baseURL:)` for a server that is already known (sync-protocol.md §2.1).
@Suite(.timeLimit(.minutes(5))) struct SyncConnectTests {
    @Test("connecting to a known server through a new URL records it; later pulls go there")
    func aKnownServerAtANewURL() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let url1 = SyncEnv.baseURL
        let url2 = try #require(URL(string: "https://quickr.example.net"))
        let store = try await env.connect(coordinator)  // through url1
        let serverId = store.serverId
        #expect(try await store.state().baseURL == url1.absoluteString)

        // The same server (the simulated feed answers on any host) through url2.
        let result = await coordinator.connect(baseURL: url2)
        guard case .connected(serverId, isNew: false, .synced) = result else {
            Issue.record("connect: \(result)")
            return
        }
        #expect(try await env.partitions.registry.repository.server(id: serverId)?.baseURL == url2.absoluteString)
        #expect(try await env.activeStore().state().baseURL == url2.absoluteString)

        // A later pull, by this coordinator and by a fresh one (another launch), goes to url2.
        _ = env.server.addEntry()
        let index = env.transport.requests.count
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(await env.coordinator(owner: "app:B").sync(reason: .requested) == .synced)
        let hosts = Set(env.transport.requests.dropFirst(index).compactMap(\.url.host))
        #expect(hosts == [url2.host], "\(hosts)")
    }
}

@Suite struct SyncConnectStatusTests {
    @Test("after connecting, the status says when the store last pulled")
    func connectPublishesTheLastPull() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        _ = await coordinator.connect(baseURL: SyncEnv.baseURL)
        // Published before the run returns, not later.
        #expect(coordinator.status.lastSyncAt == env.wall.now())
        // Even when the cached store was dropped (connecting posts registryChanged).
        env.wall.advance(by: 60)
        await coordinator.invalidateStore()
        _ = env.server.addEntry()
        #expect(await coordinator.sync(reason: .requested) == .synced)
        #expect(coordinator.status.lastSyncAt == env.wall.now())
    }
}
