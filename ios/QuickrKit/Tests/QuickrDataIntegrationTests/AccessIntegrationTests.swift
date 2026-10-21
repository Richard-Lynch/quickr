import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// A Cloudflare Access service token end to end (PLAN B9, docs/hosting/cloudflare-access.md),
/// with the fault proxy's `access` rule standing in for Access: it forwards only requests that
/// carry the rule's `CF-Access-Client-Id` and `-Secret`, and refuses the others the way Access
/// does (a 302 to its login page, or 401/403 in strict mode). The real tunnel is the H8 checklist.
extension IntegrationTests {
    @Suite("Access") @MainActor struct AccessCases {
        static let token = AccessCredentials(clientId: "it.access", clientSecret: "it-secret")

        @discardableResult
        static func gate(_ it: IT, secret: String = token.clientSecret, strict: Bool) async throws -> Int {
            try await it.proxy.add([
                "action": "access", "sticky": true, "strict": strict, "client_id": token.clientId,
                "client_secret": secret,
            ])
        }

        @Test("Without the token the probe points at the token; with it, onboarding connects through the gate")
        func probeThenConnect() async throws {
            let it = try await IT.start()
            let transport = URLSessionTransport()  // the real one: a redirect must not be followed
            let none = StaticAccessCredentials(nil)
            let wrong = StaticAccessCredentials(AccessCredentials(clientId: "it.access", clientSecret: "nope"))

            try await Self.gate(it, strict: false)
            let redirected = await ServerProbe.serverId(at: it.config.proxyURL, transport: transport, credentials: none)
            #expect(redirected == .failure(.notQuickr))
            #expect((try? redirected.get()) == nil && Self.suggestsToken(redirected))

            try await it.proxy.reset()
            try await Self.gate(it, strict: true)
            #expect(
                await ServerProbe.serverId(at: it.config.proxyURL, transport: transport, credentials: none)
                    == .failure(.accessDenied(status: 401)))
            #expect(
                await ServerProbe.serverId(at: it.config.proxyURL, transport: transport, credentials: wrong)
                    == .failure(.accessDenied(status: 403)))
            #expect(try await it.proxy.log().allSatisfy { $0.upstream == nil }, "nothing reached quickR")

            let right = StaticAccessCredentials(Self.token)
            #expect(
                await ServerProbe.serverId(at: it.config.proxyURL, transport: transport, credentials: right)
                    == .success(it.config.serverId))
        }

        @Test("A log goes through the gate; with the token revoked it waits unfailed; a new token sends it once")
        func logThroughTheGate() async throws {
            let it = try await IT.start()
            let topic = try await it.a.createTopic()
            try await Self.gate(it, strict: true)
            let root = FileManager.default.temporaryDirectory.appending(path: "quickr-it-access-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let credentials = KeychainAccessCredentials(keychain: InMemoryKeychain())
            try await credentials.save(Self.token, for: it.config.proxyURL)
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            let session = try AppSession(
                configuration: .init(
                    location: StoreLocation(root: root), transport: RecordingTransport(), credentials: credentials,
                    notifier: nil, coordinator: coordinator))
            credentials.directory.attach(session.partitions.registry.repository)

            await session.start(serverURL: it.config.proxyURL)
            #expect(session.phase == .ready)
            let serverId = try #require(session.binding?.serverId)
            try credentials.adopt(baseURL: it.config.proxyURL, serverId: serverId)
            let store = try #require(session.store)
            let scheduler = try #require(session.scheduler)

            let first = try await session.log(topic: topic, answers: ["n": .int(1)], version: 1)
            try await eventually("the first log is delivered") { try await store.items.isEmpty }
            #expect(try await it.a.entry(first) != nil)

            // The token is revoked at Access (rotated there, not yet here): the next log is refused
            // at the gate. It stays queued for a retry, never failed, and never reaches quickR.
            try await it.proxy.reset()
            try await Self.gate(it, secret: "rotated-secret", strict: true)
            let second = try await session.log(topic: topic, answers: ["n": .int(2)], version: 1)
            _ = await scheduler.waitUntilIdle()
            let waiting = try #require(try await store.item(second))
            #expect(waiting.state != .failed, "\(waiting)")
            #expect(waiting.lastError?.status == 403, "\(waiting)")
            #expect(try await it.a.entry(second) == nil)

            // The user pastes the rotated secret in Settings and taps Retry: sent exactly once.
            try credentials.save(
                AccessCredentials(clientId: Self.token.clientId, clientSecret: "rotated-secret"), serverId: serverId)
            _ = await scheduler.flushNow(reason: .retry)
            try await eventually("the second log is delivered") { try await store.items.isEmpty }
            #expect(try await it.a.entry(second) != nil)
            let posts = try await it.proxy.log().filter { $0.method == "POST" && $0.upstreamStatus == 201 }
            #expect(posts.count == 1, "\(posts)")
            await session.shutdown()
        }

        static func suggestsToken(_ result: Result<String, ConnectProblem>) -> Bool {
            if case .failure(let problem) = result { problem.suggestsAccessToken } else { false }
        }
    }
}
