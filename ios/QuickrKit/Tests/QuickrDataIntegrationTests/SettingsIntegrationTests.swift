import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// SETTINGS against the real backends: the probe names each server, connecting sends the
/// Keychain's Cloudflare Access token, and connecting to another address switches stores (and back).
extension IntegrationTests {
    @Suite("Settings") @MainActor struct SettingsCases {
        @Test("Probe, connect, switch to server b and back to a: each request carries its server's token")
        func probeConnectAndSwitch() async throws {
            let it = try await IT.start()
            let root = FileManager.default.temporaryDirectory.appending(path: "quickr-it-settings-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = RecordingTransport()
            let credentials = KeychainAccessCredentials(keychain: InMemoryKeychain())
            let tokenA = AccessCredentials(clientId: "a.access", clientSecret: "a-secret")
            let tokenB = AccessCredentials(clientId: "b.access", clientSecret: "b-secret")
            try await credentials.save(tokenA, for: it.config.proxyURL)
            try await credentials.save(tokenB, for: it.config.serverBURL)
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            let session = try AppSession(
                configuration: .init(
                    location: StoreLocation(root: root), transport: transport, credentials: credentials, notifier: nil,
                    coordinator: coordinator))
            credentials.directory.attach(session.partitions.registry.repository)
            await session.start()
            #expect(session.phase == .noServer)

            #expect(await session.probeServer(at: it.config.proxyURL) == .success(it.config.serverId))
            #expect(await session.probeServer(at: it.config.serverBURL) == .success(it.config.serverIdB))

            guard case .connected(let a, true, nil) = await session.connect(baseURL: it.config.proxyURL).outcome else {
                Issue.record("connecting to a should create its store")
                return
            }
            #expect(a == it.config.serverId && session.phase == .ready)
            try credentials.adopt(baseURL: it.config.proxyURL, serverId: a)

            guard case .connected(let b, true, nil) = await session.connect(baseURL: it.config.serverBURL).outcome
            else {
                Issue.record("switching to b should create its store")
                return
            }
            #expect(b == it.config.serverIdB && session.binding?.serverId == b)
            try credentials.adopt(baseURL: it.config.serverBURL, serverId: b)

            // Back to a: its store is known, so it is reactivated, not recreated.
            guard case .connected(_, false, nil) = await session.connect(baseURL: it.config.proxyURL).outcome else {
                Issue.record("switching back to a should reuse its store")
                return
            }
            #expect(session.binding?.serverId == it.config.serverId)
            // Every request carried the token of the server it went to, never the other's.
            for request in transport.requests {
                let expected = request.url.port == it.config.serverBURL.port ? tokenB : tokenA
                #expect(request.headers[QuickrHeader.cfAccessClientId] == expected.clientId, "\(request)")
                #expect(request.headers[QuickrHeader.cfAccessClientSecret] == expected.clientSecret)
            }
            #expect(transport.requests.contains { $0.url.port == it.config.serverBURL.port })
            await session.shutdown()
        }

        @Test("Something that isn't quickR is never taken for a server")
        func notQuickr() async throws {
            let it = try await IT.start()
            // The proxy's control API answers JSON without quickR's identity headers.
            let result = await ServerProbe.serverId(
                at: it.config.controlURL, transport: URLSessionTransport(), credentials: StaticAccessCredentials(nil))
            guard case .failure(let problem) = result else {
                Issue.record("the control API is not a quickR server, yet the probe named one")
                return
            }
            // No quickR identity headers: never a busy or storage problem, and never a server id.
            #expect(problem != .busy, "\(problem)")
        }
    }
}
