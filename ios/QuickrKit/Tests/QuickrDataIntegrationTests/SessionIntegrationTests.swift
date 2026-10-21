import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The app's composition root (`AppSession`) against the real backend: it connects, binds the
/// outbox, sends a log through the write façade's flush, and pulls back an edit made on the web.
extension IntegrationTests {
    @Suite("Session") @MainActor struct SessionCases {
        @Test("AppSession: start connects and binds; a log is flushed to the server; a web edit is pulled back")
        func logFlushAndPull() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTopic()
            let root = FileManager.default.temporaryDirectory.appending(path: "quickr-it-session-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            let transport = RecordingTransport()
            let session = try AppSession(
                configuration: .init(
                    location: StoreLocation(root: root), transport: transport, notifier: nil,
                    coordinator: coordinator))

            await session.start(serverURL: it.config.proxyURL)
            #expect(session.phase == .ready)
            #expect(session.binding?.serverId == it.config.serverId)
            #expect(session.binding?.baseURL == it.config.proxyURL)
            let store = try #require(session.store)

            let id = try await session.log(topic: topic, answers: ["n": .int(4)], version: 1)
            #expect(try await store.view(id) != nil, "visible at once")
            try await eventually("the log is flushed") { try await store.items.isEmpty }
            let server = try #require(try await it.a.entry(id))
            #expect(server["revision"] as? Int == 1 && WebServer.answer(server) == 4)
            let posts = try await it.proxy.log().filter { $0.method == "POST" }
            #expect(posts.count == 1 && posts.first?.upstreamStatus == 201)

            try await it.a.updateEntry(id, n: 5)
            #expect(await session.coordinator.sync(reason: .requested) == .synced)
            #expect(try await store.serverRevision(id) == 2)
            await session.shutdown()
        }
    }
}
